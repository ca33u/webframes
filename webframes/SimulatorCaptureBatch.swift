import AppKit

/// Capture first, then commit in one synchronous undo group. Cancellation before
/// commit discards every staged image; a failed screen never blocks later screens.
@MainActor enum SimulatorCaptureBatch {
    static let limit = 20
    struct Result: Codable, Equatable {
        let frameID: String
        let label: String
        var updated: Bool = false
        var error: String? = nil
    }
    typealias Capture = (SimulatorCaptureRecipe, (String) -> Void) async throws -> SimulatorCapturedImage

    static func run(document: WebFramesDocument, frames: [FrameModel], service: SimulatorCapture = .shared,
                    validateCommit: () throws -> Void = {}, progress: @escaping (String) -> Void = { _ in }) async throws -> [Result] {
        try await service.withCaptureSession { capture in
            try await run(document: document, frames: frames, capture: capture, validateCommit: validateCommit, progress: progress)
        }
    }

    static func run(document: WebFramesDocument, frames: [FrameModel], capture: Capture,
                    validateCommit: () throws -> Void = {}, progress: @escaping (String) -> Void = { _ in }) async throws -> [Result] {
        guard !frames.isEmpty, frames.count <= limit, Set(frames.map(\.id)).count == frames.count else {
            throw SimulatorCapture.failure("Choose 1–\(limit) unique frames per batch.")
        }
        var results = frames.map { Result(frameID: $0.id, label: $0.label) }
        // The bounded batch holds at most 20 validated images (8 MiB each).
        var staged: [(Int, SimulatorCapturedImage)] = []
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            do {
                guard frame.isImage, let recipe = frame.simulatorCapture else {
                    throw SimulatorCapture.failure("No saved Simulator Capture recipe. Open this frame’s capture settings first.")
                }
                try document.validateSimulatorCapture(frameID: frame.id, expected: frame)
                let prefix = "\(index + 1)/\(frames.count) · \(frame.label.prefix(120)) · \(recipe.platform.rawValue)"
                progress(prefix)
                let image = try await capture(recipe) { progress(prefix + "\n" + $0) }
                try Task.checkCancellation()
                staged.append((index, image))
            } catch is CancellationError { throw CancellationError() }
            catch { results[index].error = error.localizedDescription }
        }
        try Task.checkCancellation()
        try validateCommit()
        // Recheck all snapshots immediately before the synchronous commit. Keep
        // unrelated edits (geometry, comments, links) made during the capture.
        staged = staged.filter { index, _ in
            do { try document.validateSimulatorCapture(frameID: frames[index].id, expected: frames[index]); return true }
            catch { results[index].error = error.localizedDescription; return false }
        }
        if !staged.isEmpty {
            document.undoManager?.beginUndoGrouping()
            defer { document.undoManager?.endUndoGrouping() }
            for (index, image) in staged {
                try document.applySimulatorCapture(image, frameID: frames[index].id, expected: frames[index])
                results[index].updated = true
            }
            document.undoManager?.setActionName("Update Screenshots")
        }
        return results
    }
}

extension SimulatorCaptureUI {
    static func runBatch(window: NSWindow, document: WebFramesDocument, frames: [FrameModel]) {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Updating \(frames.count) screenshots…"
        alert.informativeText = "Preparing capture… Cancel keeps all original screenshots."
        alert.addButton(withTitle: "Cancel")
        let spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.startAnimation(nil)
        spinner.frame = NSRect(x: 0, y: 0, width: 24, height: 24); alert.accessoryView = spinner
        var task: Task<Void, Never>?
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { task?.cancel() }
        }
        task = Task {
            do {
                await SimulatorLivePreview.shared.stopCurrentAndWait()
                let results = try await SimulatorCaptureBatch.run(document: document, frames: frames, validateCommit: {
                    guard window.isVisible else { throw CancellationError() }
                }, progress: { alert.informativeText = $0 })
                if results.contains(where: \.updated), let url = document.fileURL {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        document.save(to: url, ofType: WebFramesDocument.fileTypeIdentifier, for: .saveOperation) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                    }
                }
                window.endSheet(alert.window, returnCode: .stop)
                let summary = NSAlert()
                summary.messageText = "\(results.filter(\.updated).count) of \(results.count) screenshots updated"
                summary.informativeText = "Successful updates can be undone together. Failed screens kept their previous screenshots."
                let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 240))
                scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
                let text = NSTextView(frame: scroll.bounds)
                text.isEditable = false; text.isSelectable = true
                text.font = .systemFont(ofSize: 12)
                text.textContainerInset = NSSize(width: 8, height: 8)
                text.isVerticallyResizable = true; text.isHorizontallyResizable = false
                text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
                text.string = results.map { "\($0.label): " + ($0.updated ? "Updated" : ($0.error ?? "Skipped")) }.joined(separator: "\n\n")
                text.setAccessibilityLabel("Screenshot update results")
                scroll.documentView = text; summary.accessoryView = scroll
                summary.addButton(withTitle: "Done")
                summary.beginSheetModal(for: window, completionHandler: nil)
            } catch is CancellationError {
                if alert.window.sheetParent != nil { window.endSheet(alert.window, returnCode: .stop) }
            } catch {
                if alert.window.sheetParent != nil { window.endSheet(alert.window, returnCode: .stop) }
                presentError(error, window: window)
            }
        }
    }
}
