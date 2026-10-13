import AppKit

nonisolated struct SimulatorRecordingNode: Codable, Sendable {
    let selector: String
    let label: String
    let x: Double, y: Double, w: Double, h: Double
    let editable: Bool, secure: Bool
    var center: CGPoint { .init(x: x + w / 2, y: y + h / 2) }
    var isValid: Bool {
        !selector.isEmpty && selector.utf8.count <= 4_096 && label.utf8.count <= 8_192
            && [x, y, w, h].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && w > 0 && h > 0 && x + w <= 1.001
            && y + h <= 1.001
    }
}
nonisolated enum SimulatorRecordingAction: Equatable, Sendable {
    case tap(CGPoint)
    case type(String)
    case swipeUp, swipeDown, refresh
    var name: String {
        switch self {
        case .tap: "tap"
        case .type: "type"
        case .swipeUp: "swipeUp"
        case .swipeDown: "swipeDown"
        case .refresh: "refresh"
        }
    }
    func command(id: String) throws -> Data {
        var object: [String: Any] = ["id": id, "action": name]
        switch self {
        case .tap(let point):
            guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y)
            else { throw SimulatorCapture.failure("Tap inside the preview.") }
            object["x"] = point.x
            object["y"] = point.y
        case .type(let value):
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= 2_000,
                value.utf8.count <= 4_096
            else { throw SimulatorCapture.failure("Enter text up to 2000 characters (4 KiB).") }
            object["value"] = value
        default: break
        }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
struct SimulatorRecordingSnapshot {
    let image: SimulatorCapturedImage
    let nodes: [SimulatorRecordingNode]
    let step: SimulatorCaptureRecipe.Step?
}

/// A recording owns the same runner reservation as capture/batch. Nothing is
/// written into the board until the user chooses Use Recording and saves it.
@MainActor final class SimulatorRecordingSession {
    enum Phase { case idle, starting, ready, working, finishing, stopped, failed }
    enum Mode { case recording, live }
    private let mode: Mode
    private(set) var phase: Phase = .idle
    private(set) var snapshot: SimulatorRecordingSnapshot?
    private(set) var steps: [SimulatorCaptureRecipe.Step] = []
    private(set) var status = "Preparing recorder…"
    private(set) var failure: Error?
    var onChange: (() -> Void)?
    private let base: SimulatorCaptureRecipe
    private let service: SimulatorCapture
    private let transport: SimulatorRecordingTransport
    private var lifetime: Task<Void, Never>?

    init(recipe: SimulatorCaptureRecipe, service: SimulatorCapture = .shared, mode: Mode = .recording) {
        self.mode = mode
        self.base = recipe
        self.service = service
        self.transport = SimulatorRecordingTransport(service: service)
    }
    func start() async throws {
        guard phase == .idle else { throw SimulatorCapture.failure("Recording already started.") }
        var recipe = try base.resolvingTestState()
        if mode == .recording { recipe.steps = [] }
        try recipe.validate()
        guard !recipe.appBundleID.isEmpty else {
            throw SimulatorCapture.failure("Choose an installed app before recording.")
        }
        trace("start")
        phase = .starting
        onChange?()
        lifetime = Task {
            do {
                try await service.withCaptureSession { _ in
                    do {
                        try await transport.start(recipe, live: mode == .live) {
                            self.status = $0
                            self.onChange?()
                        }
                        trace("runner launched")
                        snapshot = try await transport.reply(id: "ready", timeout: 180 + Double((recipe.testState?.preparation.count ?? 0) + recipe.steps.count) * 15)
                        if mode == .live { try transport.startLiveReader() }
                        trace("first screen received")
                        phase = .ready
                        status = "Click or swipe the screen. Tap a field before typing."
                        onChange?()
                        try await transport.wait()
                        trace("runner ended")
                    } catch {
                        let cleanupError = await transport.cleanup()
                        throw cleanupError ?? error
                    }
                    if let cleanupError = await transport.cleanup() { throw cleanupError }
                }
                if phase != .failed { phase = .stopped }
            } catch is CancellationError {
                trace("lifetime cancelled")
                phase = .stopped
            } catch {
                trace("lifetime failed: \((error as NSError).domain) \((error as NSError).code)")
                failure = error
                phase = .failed
                status = error.localizedDescription
            }
            onChange?()
        }
        do {
            while phase == .starting { try await Task.sleep(for: .milliseconds(100)) }
            if let failure { throw failure }
            guard snapshot != nil else {
                throw SimulatorCapture.failure("Recorder stopped before the first screen: \(status)")
            }
        } catch {
            cancel()
            throw error
        }
    }
    func nextLiveImage() async throws -> SimulatorCapturedImage? {
        if let failure { throw failure }
        guard mode == .live, phase == .ready else { throw SimulatorCapture.failure("Live preview is not ready.") }
        return try await transport.liveImage()
    }
    func perform(_ action: SimulatorRecordingAction) async throws {
        guard mode == .recording else { throw SimulatorCapture.failure("Live preview is view-only.") }
        guard phase == .ready else {
            throw SimulatorCapture.failure("Wait for the recorder to finish its current action.")
        }
        guard action == .refresh || steps.count < 30 else {
            throw SimulatorCapture.failure(
                "Recording limit reached (30 actions). Use this recording or start another.")
        }
        let id = UUID().uuidString
        let data = try action.command(id: id)
        phase = .working
        status = "Performing \(action.name)…"
        onChange?()
        do {
            try await transport.send(data)
            let updated = try await transport.reply(id: id, timeout: 45)
            try Task.checkCancellation()
            if let step = updated.step { steps.append(step) }
            snapshot = updated
            phase = .ready
            status = "\(steps.count) actions recorded"
            onChange?()
        } catch {
            if (error as NSError).domain == "WebFramesRecording.Action" {
                phase = .ready
                status = error.localizedDescription
                onChange?()
            } else {
                failure = error
                status = error.localizedDescription
                phase = .failed
                cancel()
            }
            throw error
        }
    }
    func finish() async throws -> SimulatorCaptureRecipe {
        guard phase == .ready, !steps.isEmpty else {
            throw SimulatorCapture.failure("Record at least one action first.")
        }
        var recipe = base
        recipe.steps = steps
        try recipe.validate()
        phase = .finishing
        status = "Finishing recording…"
        onChange?()
        do {
            try await transport.stop()
            await lifetime?.value
            if let failure { throw failure }
            return recipe
        } catch {
            cancel()
            throw error
        }
    }
    func cancel(file: StaticString = #fileID, line: UInt = #line) {
        trace("cancel from \(file):\(line)")
        lifetime?.cancel()
        transport.cancel()
    }
    private func trace(_ message: String) {
        guard let path = ProcessInfo.processInfo.environment["WF_RECORDING_DIAGNOSTICS"] else { return }
        let file = URL(fileURLWithPath: path).appendingPathComponent("recording-events.log")
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(
            contentsOf: Data(
                "\(Date()) \(base.platform.rawValue) \(ObjectIdentifier(self)) \(phase): \(message)\n".utf8))
    }
    func cancelAndWait() async {
        cancel()
        await lifetime?.value
    }
}

/// Nonces and fixed filenames form a local, app-private command channel. Only
/// typed actions are accepted by the bundled runners; no user code is executed.
@MainActor private final class SimulatorRecordingTransport {
    private let service: SimulatorCapture
    private let id = UUID().uuidString
    private let run = FileManager.default.temporaryDirectory.appendingPathComponent(
        "WebFramesRecording-" + UUID().uuidString)
    private var recipe: SimulatorCaptureRecipe?
    private var directory: URL?
    private var serial: String?
    private var process: Task<Void, Error>?
    private var ended = false
    private var processError: Error?
    private var appearance: SimulatorAppearanceLease?
    private var liveReader: Task<Void, Error>?
    private let liveFrames = SimulatorLiveFrameBuffer()
    private var remote: String { "files/recording-" + id }
    init(service: SimulatorCapture) { self.service = service }

    func start(_ recipe: SimulatorCaptureRecipe, live: Bool = false, progress: @escaping (String) -> Void) async throws {
        self.recipe = recipe
        try FileManager.default.createDirectory(
            at: run, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        progress("Starting \(recipe.deviceName)…")
        try await service.prepareApplication(recipe, progress: progress)
        try await service.startDevice(id: recipe.deviceID, platform: recipe.platform)
        let appearance = SimulatorAppearanceLease(service: service, recipe: recipe)
        self.appearance = appearance
        try await appearance.apply()
        guard
            try await service.apps(deviceID: recipe.deviceID, platform: recipe.platform).contains(where: {
                $0.id == recipe.appBundleID
            })
        else {
            throw SimulatorCapture.failure("The selected app is not installed on this device.")
        }
        progress("Preparing native recorder (first run can take a minute)…")
        if recipe.platform == .iOS {
            let spec = try await service.runnerSpecification(recipe: recipe, run: run, recordingID: id, live: live)
            launch {
                _ = try await self.service.command(
                    [
                        "xcodebuild", "test-without-building", "-xctestrun", spec.path,
                        "-destination", "platform=iOS Simulator,id=\(recipe.deviceID)",
                        "-parallel-testing-enabled", "NO",
                        "-maximum-concurrent-test-simulator-destinations", "1", "-resultBundlePath",
                        self.run.appendingPathComponent("Recording.xcresult").path,
                    ], timeout: 1_020,
                    observeOutput: { bytes in
                        self.acceptOutput(bytes, recipe: recipe, progress: progress)
                    })
            }
        } else {
            let android = service.android
            guard let serial = try await android.serial(for: recipe.deviceID) else {
                throw SimulatorCapture.failure("Android emulator disconnected.")
            }
            self.serial = serial
            let apk = try await android.prepareRunner()
            let installed = try await android.adb(["-s", serial, "install", "-r", apk.path], timeout: 60)
            guard String(decoding: installed, as: UTF8.self).contains("Success") else {
                throw SimulatorCapture.failure("Could not install the native recorder.")
            }
            try await android.launchApp(recipe, serial: serial)
            try await android.checkScreenProtection(serial: serial)
            let encoded = try JSONEncoder().encode(recipe).base64EncodedString()
            launch {
                let bytes = try await android.shell(
                    serial,
                    [
                        "am", "instrument", "-w", "-r", "-e", "recipe", encoded,
                        "-e", "runID", self.id, "-e", "recording", "true", "-e", "live", live ? "true" : "false",
                        AndroidEmulatorCapture.package + "/.CaptureInstrumentation",
                    ], timeout: 1_020)
                let output = String(decoding: bytes, as: UTF8.self)
                guard output.contains("INSTRUMENTATION_RESULT: wfResult=ok"),
                    output.contains("INSTRUMENTATION_CODE: -1")
                else {
                    throw SimulatorCapture.failure(
                        "Android recorder ended unexpectedly. " + String(output.suffix(1_000)))
                }
            }
        }
    }
    private func launch(_ body: @escaping () async throws -> Void) {
        process = Task {
            defer { ended = true }
            do { try await body() } catch {
                processError = error
                throw error
            }
        }
    }
    private func acceptOutput(_ bytes: Data, recipe: SimulatorCaptureRecipe, progress: (String) -> Void) {
        let lines = String(decoding: bytes, as: UTF8.self).components(separatedBy: .newlines)
        let markers = lines.filter { $0.contains("WF_RECORDING_") }
        if !markers.isEmpty, let path = ProcessInfo.processInfo.environment["WF_RECORDING_DIAGNOSTICS"] {
            try? Data(markers.joined(separator: "\n").utf8).write(
                to: URL(fileURLWithPath: path).appendingPathComponent("ios-channel.txt"), options: .atomic)
        }
        for line in markers {
            guard let range = line.range(of: "WF_RECORDING_CHANNEL ") else { continue }
            let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.path.contains("/\(recipe.deviceID)/data/Containers/Data/Application/"),
                candidate.lastPathComponent == "WebFramesRecording-" + id,
                candidate.deletingLastPathComponent().lastPathComponent == "Documents"
            else { continue }
            if directory != candidate {
                directory = candidate
                progress("Native recorder connected; preparing screen…")
            }
        }
    }
    func startLiveReader() throws {
        guard let serial else { return }
        let executable = try AndroidEmulatorCapture.sdkRoot().appendingPathComponent("platform-tools/adb")
        liveReader = Task {
            try await service.runLivePipe(executable: executable,
                arguments: ["-s", serial, "exec-out", "run-as", AndroidEmulatorCapture.package, "cat", remote + "/frames"], frames: liveFrames)
        }
    }
    func liveImage() async throws -> SimulatorCapturedImage? {
        try Task.checkCancellation()
        if ended { throw processError ?? SimulatorCapture.failure("Live preview ended.") }
        if let serial {
            // Check protection before displaying every frame; never show a blocked app.
            try await service.android.checkScreenProtection(serial: serial)
            guard let bytes = try liveFrames.take() else { return nil }
            return try SimulatorCapturedImage(data: bytes)
        }
        guard let bytes = try await read("screen.png") else { return nil }
        return try SimulatorCapturedImage(data: bytes)
    }
    func wait() async throws { try await process?.value }
    func cancel() { process?.cancel(); liveReader?.cancel() }
    func cleanup() async -> Error? {
        process?.cancel(); liveReader?.cancel()
        return await Task { @MainActor () -> Error? in
            _ = try? await liveReader?.value
            _ = try? await process?.value
            if let serial {
                _ = try? await service.android.shell(
                    serial, ["am", "force-stop", AndroidEmulatorCapture.package])
                _ = try? await service.android.shell(
                    serial, ["run-as", AndroidEmulatorCapture.package, "rm", "-rf", remote])
            } else if let recipe {
                _ = try? await service.command([
                    "simctl", "terminate", recipe.deviceID, "app.essazanov.webframes.capture.xctrunner",
                ])
                if let directory { try? FileManager.default.removeItem(at: directory) }
            }
            defer { try? FileManager.default.removeItem(at: run) }
            do { try await appearance?.restore(); return nil }
            catch { return SimulatorCapture.failure("Could not restore the device theme: " + error.localizedDescription) }
        }.value
    }
    private func read(_ name: String) async throws -> Data? {
        if let serial {
            return try await service.android.adb([
                "-s", serial, "exec-out", "run-as", AndroidEmulatorCapture.package, "cat",
                remote + "/" + name,
            ])
        }
        guard let directory else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }
    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !ended else { throw processError ?? SimulatorCapture.failure("Recording has ended.") }
        if let serial {
            try await service.android.checkScreenProtection(serial: serial)
            let command =
                "printf %s " + AndroidEmulatorCapture.shellQuote(data.base64EncodedString())
                + " | base64 -d > " + remote + "/command.tmp && mv " + remote + "/command.tmp " + remote
                + "/command.json"
            _ = try await service.android.shell(
                serial, ["run-as", AndroidEmulatorCapture.package, "sh", "-c", command])
        } else if let directory {
            try data.write(to: directory.appendingPathComponent("command.json"), options: .atomic)
        } else {
            throw SimulatorCapture.failure("Recorder is not ready.")
        }
    }
    func stop() async throws {
        try await send(
            JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "action": "stop"]))
    }
    private struct Reply: Decodable {
        let id: String
        let nodes: [SimulatorRecordingNode]
        let action: String?
        let value: String?
        let error: String?
    }
    func reply(id: String, timeout: Double) async throws -> SimulatorRecordingSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let data = try await read("reply.json"), data.count <= 4 * 1024 * 1024,
                let reply = try? JSONDecoder().decode(Reply.self, from: data), reply.id == id
            {
                if let error = reply.error {
                    throw NSError(
                        domain: "WebFramesRecording.Action", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: error])
                }
                guard reply.nodes.count <= 1_000, reply.nodes.allSatisfy(\.isValid),
                    let bytes = try await read("screen.png")
                else { throw SimulatorCapture.failure("Invalid recorder response.") }
                if let serial { try await service.android.checkScreenProtection(serial: serial) }
                let image = try SimulatorCapturedImage(data: bytes)
                let step: SimulatorCaptureRecipe.Step?
                if let action = reply.action {
                    guard let action = SimulatorCaptureRecipe.Step.Action(rawValue: action) else {
                        throw SimulatorCapture.failure("Unsupported recorded action.")
                    }
                    step = .init(action: action, value: reply.value ?? "")
                    var candidate = recipe!
                    candidate.steps = [step!]
                    try candidate.validate()
                } else {
                    step = nil
                }
                return .init(image: image, nodes: reply.nodes, step: step)
            }
            if ended {
                throw processError ?? SimulatorCapture.failure("Recorder ended before sending a screen.")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw SimulatorCapture.failure("Recorder did not respond. Start a new recording.")
    }
}
