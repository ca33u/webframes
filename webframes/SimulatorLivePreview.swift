import AppKit

/// One live runner across all boards. Selection changes stop it; screenshots stay document-owned.
@MainActor final class SimulatorLivePreview {
    static let shared = SimulatorLivePreview()
    private(set) var activeID: UUID?
    private(set) var frameID: String?
    private(set) var failure: Error?
    private var job: Task<Void, Never>?
    private var clear: (() -> Void)?
    @discardableResult
    func start(
        frameID: String, recipe: SimulatorCaptureRecipe, service: SimulatorCapture = .shared,
        valid: @escaping () -> Bool, image: @escaping (SimulatorCapturedImage?) -> Void,
        status: @escaping (String) -> Void = { _ in }, ended: @escaping (Error?) -> Void = { _ in }
    ) -> UUID {
        let old = job
        old?.cancel()
        clear?()
        let id = UUID()
        activeID = id
        failure = nil
        self.frameID = frameID
        clear = { image(nil) }
        status("Starting live preview…")
        job = Task { [weak self] in
            _ = await old?.value
            guard let self else { return }
            guard activeID == id, !Task.isCancelled, valid() else {
                if activeID == id {
                    image(nil)
                    activeID = nil
                    self.frameID = nil
                    clear = nil
                    job = nil
                    ended(nil)
                }
                return
            }
            let session = SimulatorRecordingSession(recipe: recipe, service: service, mode: .live)
            var failure: Error?
            do {
                try await session.start()
                try Task.checkCancellation()
                while activeID == id, valid() {
                    if let next = try await session.nextLiveImage() {
                        try Task.checkCancellation()
                        guard activeID == id, valid() else { break }
                        image(next)
                        status("Live · " + recipe.deviceName)
                    }
                    try await Task.sleep(for: .milliseconds(300))
                }
            } catch is CancellationError {} catch { failure = error }
            await session.cancelAndWait()
            if failure == nil { failure = session.failure }
            if activeID == id {
                self.failure = failure
                status(failure?.localizedDescription ?? "Live preview stopped")
                image(nil)
                ended(failure)
                activeID = nil
                self.frameID = nil
                clear = nil
                job = nil
            }
        }
        return id
    }
    func stop(_ id: UUID) {
        guard activeID == id else { return }
        job?.cancel()
        clear?()
        clear = nil
        activeID = nil
        frameID = nil
    }
    func stopAndWait(_ id: UUID) async {
        let task = activeID == id ? job : nil
        stop(id)
        await task?.value
    }
    func stopCurrentAndWait() async {
        let task = job
        if let id = activeID { stop(id) }
        await task?.value
    }
    func waitUntilIdle() async { await job?.value }
}

extension CanvasHost {
    func toggleSimulatorLive(id: String) {
        if simulatorLiveFrameID == id {
            stopSimulatorLive()
            return
        }
        guard !annotationMode, selectedFrameIDs == [id], let window, let document,
            let frame = document.workspace.frame(id: id), frame.isImage,
            let recipe = frame.simulatorCapture
        else {
            if let window {
                SimulatorCaptureUI.presentError(
                    SimulatorCapture.failure("Select one image with a saved Simulator Capture recipe."), window: window)
            }
            return
        }
        stopSimulatorLive()
        simulatorLiveFrameID = id
        simulatorLiveToken = SimulatorLivePreview.shared.start(
            frameID: id, recipe: recipe,
            valid: { [weak self, weak document] in
                guard let self, let document, self.window?.isVisible == true, self.selectedFrameIDs == [id],
                    !self.annotationMode,
                    self.simulatorLiveFrameID == id
                else { return false }
                return (try? document.validateSimulatorCapture(frameID: id, expected: frame)) != nil
            },
            image: { [weak self] image in
                guard let self, self.simulatorLiveFrameID == id else { return }
                self.bridge.setSimulatorLiveImage(id: id, image: image)
                if image == nil {
                    self.simulatorLiveFrameID = nil
                    self.simulatorLiveToken = nil
                }
            },
            status: { [weak self] message in
                guard let self, self.simulatorLiveFrameID == id else { return }
                self.bridge.setSimulatorLiveStatus(id: id, text: message)
            },
            ended: { [weak self] error in
                guard let self, let error, let window = self.window, window.isVisible else { return }
                SimulatorCaptureUI.presentError(error, window: window)
            })
        // Start can be cancelled while the runner is still preparing.
        bridge.setSimulatorLiveStatus(id: id, text: "Starting live preview…")
        _ = window
    }
    func stopSimulatorLive() {
        if let id = simulatorLiveFrameID { bridge.setSimulatorLiveImage(id: id, image: nil) }
        if let token = simulatorLiveToken { SimulatorLivePreview.shared.stop(token) }
        simulatorLiveFrameID = nil
        simulatorLiveToken = nil
    }
}
