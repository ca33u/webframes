import AppKit
import Testing
@testable import Web_Frames

@Suite("Batch simulator capture") @MainActor struct SimulatorCaptureBatchTests {
    private let ios = SimulatorCaptureRecipe(deviceID: "1781B954-FC16-45CB-AD60-58F4224410F3", deviceName: "iPhone 18 Pro Max",
        appBundleID: "app.essazanov.Comin", restartApp: true, steps: [.init(action: .wait, value: "Забыли пароль?"), .init(action: .tap, value: "Забыли пароль?"), .init(action: .wait, value: "Сброс пароля")])
    private let android = SimulatorCaptureRecipe(deviceID: "android-avd:WF_Comin_Capture", deviceName: "WF_Comin_Capture",
        appBundleID: "com.essazanov.comin", restartApp: true, steps: [.init(action: .wait, value: "Забыли пароль?"), .init(action: .tap, value: "Забыли пароль?"), .init(action: .wait, value: "Сброс пароля")], platform: .android)

    private func image(_ value: UInt8) throws -> SimulatorCapturedImage {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(rep.bitmapData)
        for y in 0..<2 { for x in 0..<2 { let i = y * rep.bytesPerRow + x * 4
            bytes[i] = value; bytes[i + 1] = 0; bytes[i + 2] = 0; bytes[i + 3] = 255
        } }
        return try SimulatorCapturedImage(data: #require(rep.representation(using: .png, properties: [:])))
    }
    private func fixture() throws -> WebFramesDocument {
        let doc = makeTestDocument(), old = try image(10)
        doc.undoManager?.groupsByEvent = false; doc.undoManager?.disableUndoRegistration()
        for (i, recipe) in [ios, android, ios].enumerated() {
            let id = "f\(i)"
            doc.workspace.createFrame(.init(id: id, url: "image://\(id)", label: id, x: Double(i * 400), y: 20, w: 390, h: 844,
                num: i + 1, isImage: true, extras: ["imgUrl": .string(old.dataURL)]))
            doc.workspace.setSimulatorCapture(id: id, recipe: recipe)
        }
        doc.undoManager?.enableUndoRegistration(); return doc
    }
    private func close(_ doc: WebFramesDocument) { doc.updateChangeCount(.changeCleared); doc.close() }
    private func save(_ doc: WebFramesDocument) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            doc.save(to: doc.fileURL!, ofType: WebFramesDocument.fileTypeIdentifier, for: .saveOperation) {
                if let error = $0 { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    @Test func mixedPlatformsPartialFailureAndSingleUndo() async throws {
        let doc = try fixture(); defer { close(doc) }
        let before = doc.workspace.frames, new = try image(200)
        var calls: [SimulatorCaptureRecipe.Platform] = []
        let results = try await SimulatorCaptureBatch.run(document: doc, frames: before, capture: { recipe, _ in
            calls.append(recipe.platform)
            if calls.count == 2 { throw SimulatorCapture.failure("Missing element") }
            #expect(doc.workspace.frames == before) // nothing is applied while capturing
            await Task.yield(); return new
        })
        #expect(calls == [.iOS, .android, .iOS])
        #expect(results.map(\.updated) == [true, false, true])
        #expect(results[1].error == "Missing element")
        #expect(doc.workspace.frames[1] == before[1])
        let after = doc.workspace.frames
        #expect(doc.undoManager?.undoActionName == "Update Screenshots")
        doc.undoManager?.undo(); #expect(doc.workspace.frames == before)
        doc.undoManager?.redo(); #expect(doc.workspace.frames == after)
        try await save(doc)
        let reopened = try WebFramesDocument(contentsOf: #require(doc.fileURL), ofType: WebFramesDocument.fileTypeIdentifier)
        defer { close(reopened) }; #expect(reopened.workspace.frames == after)
    }

    @Test func cancellationDiscardsEarlierSuccessfulCaptures() async throws {
        let doc = try fixture(); defer { close(doc) }
        let before = doc.workspace.frames, new = try image(200)
        var calls = 0, waiting = false
        let task = Task {
            try await SimulatorCaptureBatch.run(document: doc, frames: before, capture: { _, _ in
                calls += 1
                if calls == 2 { waiting = true; try await Task.sleep(for: .seconds(60)) }
                return new
            })
        }
        for _ in 0..<100 { if waiting { break }; try await Task.sleep(for: .milliseconds(10)) }
        #expect(waiting); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(doc.workspace.frames == before && doc.undoManager?.canUndo == false)
    }

    @Test func changedImageRejectedWhileGeometryAndRecipeSurvive() async throws {
        let doc = try fixture(); defer { close(doc) }
        let before = doc.workspace.frames, new = try image(200), user = try image(100)
        var calls = 0
        let results = try await SimulatorCaptureBatch.run(document: doc, frames: before, capture: { _, _ in
            calls += 1
            if calls == 3 {
                doc.undoManager?.disableUndoRegistration()
                doc.workspace.moveFrame(id: "f0", to: .init(x: 123, y: 456))
                doc.workspace.updateFrameImage(id: "f1", dataURL: user.dataURL, pixelSize: .init(width: 2, height: 2), date: Date(), actor: "User")
                doc.workspace.setSimulatorCapture(id: "f2", recipe: nil)
                doc.undoManager?.enableUndoRegistration()
            }
            return new
        })
        #expect(results.map(\.updated) == [true, false, false])
        #expect(doc.workspace.frames[0].x == 123 && doc.workspace.frames[0].y == 456)
        #expect(doc.workspace.frames[1].extras["imgUrl"] == .string(user.dataURL))
        #expect(doc.workspace.frames[2].simulatorCapture == nil)
        doc.undoManager?.undo()
        #expect(doc.workspace.frames[0].x == 123 && doc.workspace.frames[0].extras["imgUrl"] == before[0].extras["imgUrl"])
    }

    @Test func permissionExpiryBoundsAndMissingRecipesLeaveNoUndo() async throws {
        let doc = try fixture(); defer { close(doc) }
        let before = doc.workspace.frames, new = try image(200)
        await #expect(throws: (any Error).self) {
            try await SimulatorCaptureBatch.run(document: doc, frames: before, capture: { _, _ in new }, validateCommit: { throw SimulatorCapture.failure("Permission revoked") })
        }
        await #expect(throws: (any Error).self) { try await SimulatorCaptureBatch.run(document: doc, frames: [], capture: { _, _ in new }) }
        await #expect(throws: (any Error).self) { try await SimulatorCaptureBatch.run(document: doc, frames: [before[0], before[0]], capture: { _, _ in new }) }
        await #expect(throws: (any Error).self) { try await SimulatorCaptureBatch.run(document: doc, frames: Array(repeating: before[0], count: 21), capture: { _, _ in new }) }
        doc.undoManager?.disableUndoRegistration()
        for f in before { doc.workspace.setSimulatorCapture(id: f.id, recipe: nil) }
        doc.undoManager?.enableUndoRegistration()
        let results = try await SimulatorCaptureBatch.run(document: doc, frames: doc.workspace.frames, capture: { _, _ in Issue.record("Must not capture without recipes"); return new })
        #expect(results.allSatisfy { !$0.updated && $0.error != nil })
        #expect(doc.undoManager?.canUndo == false)
        let captures = try before.map { frame -> CommentsMCPInbox.SimulatorRequest in
            guard case .string(let url)? = frame.extras["imgUrl"] else { throw SimulatorCapture.failure("Missing image") }
            return .init(frameID: frame.id, beforeHash: CommentsMCPInbox.imageHash(try #require(CommentsMCPInbox.imageBytes(url))), recipe: frame.simulatorCapture!)
        }
        let request = CommentsMCPInbox.Request(id: UUID().uuidString, deadline: Date().timeIntervalSince1970 + 30, resolved: false, comments: [], simulatorCaptures: captures)
        #expect(throws: (any Error).self) { try CommentsMCPInbox.validateSimulatorBatchRequest(request, document: doc, allowed: false) }
        #expect(throws: (any Error).self) { try CommentsMCPInbox.validateSimulatorBatchRequest(request, document: doc, allowed: true) }
        #expect(throws: (any Error).self) { try CommentsMCPInbox.apply(request, to: doc, allowed: true) }
    }

    @Test func sessionReservationRejectsInterleavingAndReleasesOnFailure() async throws {
        let service = SimulatorCapture()
        var interleavingRejected = false
        await #expect(throws: (any Error).self) {
            try await service.withCaptureSession { _ in
                do { _ = try await service.capture(ios) } catch { interleavingRejected = true }
                throw SimulatorCapture.failure("Release session")
            }
        }
        #expect(interleavingRejected)
        let released = try await service.withCaptureSession { _ in true }
        #expect(released)
    }

    @Test func agentBatchValidationChecksEverySnapshotAndRejectsMixedRequests() throws {
        let doc = try fixture(); defer { close(doc) }
        let captures = try doc.workspace.frames.map { frame -> CommentsMCPInbox.SimulatorRequest in
            guard case .string(let url)? = frame.extras["imgUrl"] else { throw SimulatorCapture.failure("Missing image") }
            return .init(frameID: frame.id, beforeHash: CommentsMCPInbox.imageHash(try #require(CommentsMCPInbox.imageBytes(url))), recipe: frame.simulatorCapture!)
        }
        let now = Date()
        var request = CommentsMCPInbox.Request(id: UUID().uuidString, deadline: now.timeIntervalSince1970 + 900, resolved: false, comments: [], simulatorCaptures: captures)
        #expect(try CommentsMCPInbox.validateSimulatorBatchRequest(request, document: doc, allowed: true, now: now).map(\.id) == ["f0", "f1", "f2"])
        #expect(throws: (any Error).self) { try CommentsMCPInbox.validateSimulatorBatchRequest(request, document: doc, allowed: false, now: now) }
        #expect(throws: (any Error).self) { try CommentsMCPInbox.validateSimulatorBatchRequest(request, document: doc, allowed: true, now: now.addingTimeInterval(901)) }
        request.simulatorCapture = captures[0]
        #expect(throws: (any Error).self) { try CommentsMCPInbox.validateSimulatorBatchRequest(request, document: doc, allowed: true, now: now) }
        request.simulatorCapture = nil; request.simulatorCaptures = [captures[0], captures[0]]
        #expect(throws: (any Error).self) { try CommentsMCPInbox.validateSimulatorBatchRequest(request, document: doc, allowed: true, now: now) }
        request.simulatorCaptures = captures; request.frameImage = .init(frameID: "f0", beforeHash: captures[0].beforeHash, dataURL: "invalid")
        #expect(throws: (any Error).self) { try CommentsMCPInbox.validateSimulatorBatchRequest(request, document: doc, allowed: true, now: now) }
        request.frameImage = nil
        doc.undoManager?.disableUndoRegistration(); doc.workspace.setSimulatorCapture(id: "f2", recipe: android); doc.undoManager?.enableUndoRegistration()
        #expect(throws: (any Error).self) { try CommentsMCPInbox.validateSimulatorBatchRequest(request, document: doc, allowed: true, now: now) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WF_BATCH_CAPTURE_LIVE"] == "1"))
    func populatedCominMixedBatchUIAndMCPUndoSaveReopen() async throws {
        let env = ProcessInfo.processInfo.environment
        let doc = makeTestDocument(); defer { close(doc) }
        try doc.read(from: FileWrapper(url: URL(fileURLWithPath: try #require(env["WF_NATIVE_CAPTURE_BOARD"]))), ofType: WebFramesDocument.fileTypeIdentifier)
        let evidence = URL(fileURLWithPath: try #require(env["WF_NATIVE_CAPTURE_EVIDENCE"]))
        let undo = try #require(doc.undoManager); undo.groupsByEvent = false; undo.disableUndoRegistration()
        var welcome = android; welcome.steps = [.init(action: .wait, value: "Забыли пароль?")]
        for (id, recipe) in [("wf10-current", ios), ("wf10-reference", android), ("wf10-recovery", welcome)] {
            doc.workspace.setSimulatorCapture(id: id, recipe: recipe)
        }
        undo.enableUndoRegistration()
        let before = doc.workspace.frames, comments = doc.workspace.annotations, links = doc.workspace.links
        #expect(before.count == 3 && comments.count == 3 && links.count == 2)
        doc.makeWindowControllers(); doc.showWindows()
        let controller = try #require(doc.windowControllers.first as? DocumentWindowController), window = try #require(controller.window)
        defer { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .stop) } }
        controller.canvasHost.setFrameSelection(["wf10-current", "wf10-recovery"])
        #expect(controller.canvasHost.simulatorBatchFrames(all: false).map(\.id) == ["wf10-current", "wf10-recovery"])
        #expect(controller.canvasHost.simulatorBatchFrames(all: true).count == 3)
        controller.refreshAllScreenshots(nil) // real AppKit menu action + progress + save + summary
        #expect(window.attachedSheet != nil)
        func text(_ view: NSView) -> [String] { (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(text) }
        var summaryShown = false
        for _ in 0..<9_000 {
            if let content = window.attachedSheet?.contentView {
                let labels = text(content)
                if labels.contains(where: { $0.contains("of 3 screenshots updated") }) {
                    summaryShown = labels.contains("3 of 3 screenshots updated")
                    if !summaryShown { Issue.record("Batch summary: \(labels.joined(separator: "\n"))") }
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(summaryShown)
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .stop) }
        let after = doc.workspace.frames
        #expect(zip(before, after).allSatisfy { $0.extras["imgUrl"] != $1.extras["imgUrl"] })
        for (name, target) in [("updated", after), ("undo", before), ("redo", after)] {
            try await save(doc)
            let reopened = try WebFramesDocument(contentsOf: #require(doc.fileURL), ofType: WebFramesDocument.fileTypeIdentifier)
            #expect(reopened.workspace.frames == target)
            #expect(reopened.workspace.annotations == comments && reopened.workspace.links == links)
            try JSONEncoder().encode(reopened.payload).write(to: evidence.appendingPathComponent("batch-\(name).json"))
            close(reopened)
            if name == "updated" { undo.undo() } else if name == "undo" { undo.redo() }
        }
        #expect(zip(before, after).allSatisfy { a, b in a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h && a.label == b.label && a.num == b.num && a.simulatorCapture == b.simulatorCapture })
        // The UI document has its real (disabled) inbox. Use another managed
        // test document for injected permission so the two watchers cannot
        // delete each other's request directory on defaults notifications.
        let agentDoc = makeTestDocument(); defer { close(agentDoc) }
        try agentDoc.read(from: FileWrapper(url: #require(doc.fileURL)), ofType: WebFramesDocument.fileTypeIdentifier)
        let agentUndo = try #require(agentDoc.undoManager); agentUndo.groupsByEvent = false
        let inbox = CommentsMCPInbox(document: agentDoc, permission: { false }, frameImagesPermission: { false }, simulatorPermission: { true })
        inbox.start(); defer { inbox.stop() }
        // Swap recovery targets so the second batch also produces distinct pixels.
        agentUndo.disableUndoRegistration()
        agentDoc.workspace.setSimulatorCapture(id: "wf10-reference", recipe: welcome)
        agentDoc.workspace.setSimulatorCapture(id: "wf10-recovery", recipe: android)
        agentUndo.enableUndoRegistration()
        let beforeAgent = agentDoc.workspace.frames
        let captures = try beforeAgent.map { frame -> CommentsMCPInbox.SimulatorRequest in
            guard case .string(let url)? = frame.extras["imgUrl"] else { throw SimulatorCapture.failure("Missing image") }
            return .init(frameID: frame.id, beforeHash: CommentsMCPInbox.imageHash(try #require(CommentsMCPInbox.imageBytes(url))), recipe: frame.simulatorCapture!)
        }
        let request = CommentsMCPInbox.Request(id: UUID().uuidString, deadline: Date().timeIntervalSince1970 + 900, resolved: false, comments: [], simulatorCaptures: captures)
        let directory = CommentsMCPInbox.directory(for: try #require(agentDoc.fileURL)), reply = directory.appendingPathComponent(request.id + ".response.json")
        try #require(FileManager.default.fileExists(atPath: directory.path))
        try JSONEncoder().encode(request).write(to: directory.appendingPathComponent(request.id + ".request.json"), options: .atomic)
        for _ in 0..<9_000 {
            if FileManager.default.fileExists(atPath: reply.path) { break }
            try #require(FileManager.default.fileExists(atPath: directory.path))
            try await Task.sleep(for: .milliseconds(100))
        }
        let data = try Data(contentsOf: reply), result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try data.write(to: evidence.appendingPathComponent("batch-mcp.json"))
        #expect(result?["ok"] as? Bool == true && result?["updated"] as? Int == 3)
        let afterAgent = agentDoc.workspace.frames
        #expect(agentDoc.workspace.annotations == comments && agentDoc.workspace.links == links)
        agentUndo.undo(); #expect(agentDoc.workspace.frames == beforeAgent)
        agentUndo.redo(); #expect(agentDoc.workspace.frames == afterAgent)
        try await save(agentDoc)
        let copy = evidence.appendingPathComponent("Comin Batch Capture.webframes")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: #require(agentDoc.fileURL), to: copy)
        try? FileManager.default.removeItem(at: reply)
    }
}
