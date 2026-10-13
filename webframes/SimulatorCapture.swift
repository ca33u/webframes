import AppKit
import CryptoKit
import ImageIO

nonisolated struct SimulatorCaptureRecipe: Codable, Hashable, Sendable {
    enum Platform: String, Codable, CaseIterable, Sendable { case iOS = "ios", android }
    struct Step: Codable, Hashable, Sendable {
        enum Action: String, Codable, CaseIterable, Sendable {
            case tap, wait, type, swipeUp, swipeDown
            var title: String {
                switch self {
                case .tap: "Tap"
                case .wait: "Wait for"
                case .type: "Type text"
                case .swipeUp: "Swipe up"
                case .swipeDown: "Swipe down"
                }
            }
        }
        var action: Action
        var value: String
    }
    var deviceID: String
    var deviceName: String
    var platform: Platform = .iOS
    var appBundleID: String = ""
    var restartApp: Bool = false
    var deeplink: String? = nil
    var steps: [Step] = []
    var build: SimulatorAppBuild? = nil
    var testState: SimulatorTestState? = nil

    func validate() throws {
        try build?.validate(platform: platform)
        try testState?.validate()
        if platform == .android, testState?.launchArguments.isEmpty == false {
            throw SimulatorCapture.failure("Launch arguments are available for iOS; Android receives test context as intent extras.")
        }
        if testState != nil, try JSONEncoder().encode(self).count > 64 * 1024 { throw SimulatorCapture.failure("The complete test recipe must fit within 64 KiB.") }
        if testState != nil, appBundleID.isEmpty { throw SimulatorCapture.failure("Choose an app for test-state preparation.") }
        if build != nil, appBundleID.isEmpty { throw SimulatorCapture.failure("Enter the bundle / application ID of the app to build.") }
        let validDevice = platform == .iOS ? UUID(uuidString: deviceID) != nil :
            deviceID.range(of: "^(android-avd:[A-Za-z0-9_.-]+|emulator-[0-9]+)$", options: .regularExpression) != nil
        let packagePattern = platform == .android ? "^[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)+$" : "^[A-Za-z0-9_-]+(\\.[A-Za-z0-9_-]+)+$"
        guard validDevice, steps.count <= 30,
              appBundleID.utf8.count <= 255, !appBundleID.hasPrefix("-"),
              appBundleID.isEmpty || appBundleID.range(of: packagePattern, options: .regularExpression) != nil else {
            throw SimulatorCapture.failure("Choose a simulator and an installed app. A flow can contain up to 30 steps.")
        }
        if appBundleID.isEmpty, !steps.isEmpty || deeplink != nil || restartApp {
            throw SimulatorCapture.failure("Choose an app to launch or run screen actions.")
        }
        for step in steps {
            guard step.value.utf8.count <= 4_096,
                  ![.tap, .wait, .type].contains(step.action) || !step.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SimulatorCapture.failure("Enter a label or accessibility identifier for each Tap / Wait step, and text for Type text.")
            }
        }
        if let deeplink {
            guard deeplink.utf8.count <= 4_096, let url = URL(string: deeplink),
                  let scheme = url.scheme, !["file", "javascript", "data"].contains(scheme.lowercased()) else {
                throw SimulatorCapture.failure("Enter an app deeplink such as myapp://screen.")
            }
        }
    }
    var jsonValue: JSONValue? {
        guard let bytes = try? JSONEncoder().encode(self) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: bytes)
    }
    init(deviceID: String, deviceName: String, appBundleID: String = "", restartApp: Bool = false,
         deeplink: String? = nil, steps: [Step] = [], platform: Platform = .iOS, build: SimulatorAppBuild? = nil, testState: SimulatorTestState? = nil) {
        self.deviceID = deviceID; self.deviceName = deviceName; self.appBundleID = appBundleID
        self.restartApp = restartApp; self.deeplink = deeplink; self.steps = steps
        self.platform = platform
        self.build = build
        self.testState = testState
    }
    private enum CodingKeys: String, CodingKey { case deviceID, deviceName, platform, appBundleID, restartApp, deeplink, steps, build, testState }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        platform = try c.decodeIfPresent(Platform.self, forKey: .platform) ?? .iOS
        appBundleID = try c.decode(String.self, forKey: .appBundleID)
        restartApp = try c.decode(Bool.self, forKey: .restartApp)
        deeplink = try c.decodeIfPresent(String.self, forKey: .deeplink)
        steps = try c.decode([Step].self, forKey: .steps)
        build = try c.decodeIfPresent(SimulatorAppBuild.self, forKey: .build)
        testState = try c.decodeIfPresent(SimulatorTestState.self, forKey: .testState)
    }
    init?(jsonValue: JSONValue?) {
        guard let jsonValue, let bytes = try? JSONEncoder().encode(jsonValue),
              let recipe = try? JSONDecoder().decode(Self.self, from: bytes) else { return nil }
        self = recipe
    }
}

extension FrameModel {
    var simulatorCapture: SimulatorCaptureRecipe? {
        get { SimulatorCaptureRecipe(jsonValue: extras["simulatorCapture"]) }
        set { extras["simulatorCapture"] = newValue?.jsonValue }
    }
}

nonisolated struct SimulatorCapturedImage: Sendable {
    let data: Data
    let width: Int
    let height: Int
    var dataURL: String { "data:image/png;base64," + data.base64EncodedString() }
    init(data: Data) throws {
        guard !data.isEmpty, data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int,
              let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 16_384, h <= 16_384, w * h <= 32_000_000,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            throw SimulatorCapture.failure("The simulator did not return a valid PNG (maximum 8 MiB / 32 million pixels).")
        }
        self.data = data; width = w; height = h
    }
}

/// Uses only Xcode's public command-line tools and Web Frames' bundled XCTest source.
/// Work is serialized so two captures cannot steer the same simulator at once.
@MainActor final class SimulatorCapture {
    static let shared = SimulatorCapture()
    nonisolated static func failure(_ message: String) -> NSError {
        NSError(domain: "WebFrames.SimulatorCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    struct Device: Sendable { let id: String; let name: String; let booted: Bool; let runtime: String; var platform: SimulatorCaptureRecipe.Platform = .iOS }
    struct App: Sendable { let id: String; let name: String }
    private var busy = false
    private struct PreparedApp: Hashable {
        let build: SimulatorAppBuild
        let deviceID: String
        let platform: SimulatorCaptureRecipe.Platform
        let appID: String
    }
    private var preparedApps: Set<PreparedApp> = []
    private let runnerRoot: URL?
    private let cache: URL
    private let buildPermission: (URL) -> Bool

    init(runnerRoot: URL? = Bundle.main.resourceURL?.appendingPathComponent("Tools/SimulatorCapture"), cache: URL? = nil,
         buildPermission: @escaping (URL) -> Bool = SimulatorBuildTrust.isTrusted) {
        self.runnerRoot = runnerRoot
        self.cache = cache ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("app.essazanov.webframes/SimulatorCapture", isDirectory: true)
        self.buildPermission = buildPermission
    }

    func prepareApplication(_ recipe: SimulatorCaptureRecipe, progress: (String) -> Void) async throws {
        guard let build = recipe.build else { return }
        guard buildPermission(build.project) else {
            throw Self.failure("Local builds are not allowed for this project. Choose / authorize it in Simulator Capture settings.")
        }
        let key = PreparedApp(build: build, deviceID: recipe.deviceID, platform: recipe.platform, appID: recipe.appBundleID)
        if busy && preparedApps.contains(key) { progress("Using the app built and installed for this batch…"); return }
        try await SimulatorAppBuilder(service: self, cache: cache.appendingPathComponent("AppBuilds"),
                                      permission: buildPermission).buildAndInstall(recipe, progress: progress)
        if busy { preparedApps.insert(key) }
    }

    var android: AndroidEmulatorCapture {
        AndroidEmulatorCapture(commands: self, sources: runnerRoot?.appendingPathComponent("Android"), cache: cache.appendingPathComponent("Android"))
    }
    func devices(platform: SimulatorCaptureRecipe.Platform = .iOS) async throws -> [Device] {
        if platform == .android { return try await android.devices() }
        let bytes = try await command(["simctl", "list", "devices", "available", "-j"])
        struct List: Decodable {
            struct Item: Decodable { let udid: String; let name: String; let state: String }
            let devices: [String: [Item]]
        }
        return try JSONDecoder().decode(List.self, from: bytes).devices
            .filter { $0.key.contains(".iOS-") }.flatMap { runtime, items in
                items.map { Device(id: $0.udid, name: $0.name, booted: $0.state == "Booted",
                                   runtime: runtime.components(separatedBy: ".").last?.replacingOccurrences(of: "-", with: " ") ?? runtime) }
            }
            .sorted { $0.booted != $1.booted ? $0.booted : $0.name < $1.name }
    }

    func startDevice(id: String, platform: SimulatorCaptureRecipe.Platform = .iOS) async throws {
        if platform == .android { try await android.startDevice(id: id); return }
        guard let device = try await devices().first(where: { $0.id == id }) else { throw Self.failure("The simulator is unavailable.") }
        if !device.booted { _ = try await command(["simctl", "boot", id]) }
        _ = try await command(["simctl", "bootstatus", id, "-b"], timeout: 120)
    }

    func apps(deviceID: String, platform: SimulatorCaptureRecipe.Platform = .iOS) async throws -> [App] {
        if platform == .android { return try await android.apps(deviceID: deviceID) }
        guard UUID(uuidString: deviceID) != nil else { throw Self.failure("Choose a simulator.") }
        let bytes = try await command(["simctl", "listapps", deviceID])
        guard let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: [String: Any]] else {
            throw Self.failure("Unable to read installed apps.")
        }
        return plist.compactMap { id, info in
            guard info["ApplicationType"] as? String == "User", !id.hasPrefix("app.essazanov.webframes.capture") else { return nil }
            return App(id: id, name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func capture(_ recipe: SimulatorCaptureRecipe, progress: @escaping (String) -> Void = { _ in }) async throws -> SimulatorCapturedImage {
        try await withCaptureSession { capture in try await capture(recipe, progress) }
    }

    /// Reserve the runner for the entire batch, including gaps between devices.
    func withCaptureSession<T>(_ operation: (_ capture: (SimulatorCaptureRecipe, (String) -> Void) async throws -> SimulatorCapturedImage) async throws -> T) async throws -> T {
        guard !busy else { throw Self.failure("Another simulator capture is running. Wait for it to finish.") }
        busy = true; preparedApps.removeAll()
        defer { busy = false; preparedApps.removeAll() }
        return try await operation { recipe, progress in try await self.captureReserved(recipe, progress: progress) }
    }

    private func captureReserved(_ recipe: SimulatorCaptureRecipe, progress: (String) -> Void) async throws -> SimulatorCapturedImage {
        try Task.checkCancellation()
        let recipe = try recipe.resolvingTestState()
        try await prepareApplication(recipe, progress: progress)
        let appearance = SimulatorAppearanceLease(service: self, recipe: recipe)
        do {
            if recipe.testState != nil {
                progress("Preparing test state: \(recipe.testState!.name)…")
                try await startDevice(id: recipe.deviceID, platform: recipe.platform)
                try await appearance.apply()
            }
            let image = try await capturePrepared(recipe, progress: progress)
            try await appearance.restore()
            return image
        } catch {
            do { try await appearance.restore() } catch { throw Self.failure("Could not restore device appearance: " + error.localizedDescription) }
            throw error
        }
    }

    private func capturePrepared(_ recipe: SimulatorCaptureRecipe, progress: (String) -> Void) async throws -> SimulatorCapturedImage {
        if recipe.platform == .android { return try await android.capture(recipe, progress: progress) }
        let fm = FileManager.default
        let run = fm.temporaryDirectory.appendingPathComponent("WebFramesCapture-" + UUID().uuidString)
        try fm.createDirectory(at: run, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: run) }
        let available = try await devices()
        guard let device = available.first(where: { $0.id == recipe.deviceID }) else {
            throw Self.failure("The saved simulator is unavailable. Choose another device in Simulator Capture.")
        }
        if !device.booted {
            progress("Starting \(device.name)…")
            _ = try await command(["simctl", "boot", device.id])
        }
        _ = try await command(["simctl", "bootstatus", device.id, "-b"], timeout: 120)
        let screenshot: URL
        if recipe.appBundleID.isEmpty {
            progress("Capturing the current screen…")
            screenshot = run.appendingPathComponent("screen.png")
            _ = try await command(["simctl", "io", device.id, "screenshot", "--type=png", screenshot.path])
        } else {
            guard try await apps(deviceID: device.id).contains(where: { $0.id == recipe.appBundleID }) else {
                throw Self.failure("The saved app is not installed on this simulator. Choose an installed app.")
            }
            progress("Preparing screen automation (first run can take a minute)…")
            let spec = try await runnerSpecification(recipe: recipe, run: run)
            let result = run.appendingPathComponent("Capture.xcresult")
            progress("Opening the app and running \(recipe.steps.count) screen actions…")
            _ = try await command(["xcodebuild", "test-without-building", "-xctestrun", spec.path,
                "-destination", "platform=iOS Simulator,id=\(device.id)", "-parallel-testing-enabled", "NO",
                "-maximum-concurrent-test-simulator-destinations", "1", "-resultBundlePath", result.path], timeout: 120 + Double(recipe.steps.count + (recipe.testState?.preparation.count ?? 0)) * 15)
            let exports = run.appendingPathComponent("Screenshots")
            _ = try await command(["xcresulttool", "export", "attachments", "--path", result.path, "--output-path", exports.path])
            struct TestAttachments: Decodable {
                struct Attachment: Decodable { let exportedFileName: String; let suggestedHumanReadableName: String }
                let attachments: [Attachment]
            }
            let manifest = try JSONDecoder().decode([TestAttachments].self, from: Data(contentsOf: exports.appendingPathComponent("manifest.json")))
            guard let attachment = manifest.flatMap(\.attachments).first(where: { $0.suggestedHumanReadableName.hasPrefix("WebFramesCapture") }),
                  attachment.exportedFileName == URL(fileURLWithPath: attachment.exportedFileName).lastPathComponent else {
                throw Self.failure("The screen flow finished without a screenshot.")
            }
            screenshot = exports.appendingPathComponent(attachment.exportedFileName)
        }
        try Task.checkCancellation()
        return try SimulatorCapturedImage(data: Data(contentsOf: screenshot))
    }

    func runnerSpecification(recipe: SimulatorCaptureRecipe, run: URL, recordingID: String? = nil, live: Bool = false) async throws -> URL {
        let fm = FileManager.default
        let products = try await prepareRunner(deviceID: recipe.deviceID)
        let templates = try fm.contentsOfDirectory(at: products, includingPropertiesForKeys: nil).filter { $0.pathExtension == "xctestrun" }
        guard let template = templates.first else { throw Self.failure("Xcode did not create the screen runner.") }
        var config = try PropertyListSerialization.propertyList(from: Data(contentsOf: template), format: nil)
        let encoded = try JSONEncoder().encode(recipe).base64EncodedString()
        func configure(_ value: Any) -> Any {
            if var object = value as? [String: Any] {
                for (key, child) in object { object[key] = configure(child) }
                if object["TestBundlePath"] != nil {
                    var env = object["EnvironmentVariables"] as? [String: String] ?? [:]
                    env["WF_CAPTURE_RECIPE"] = encoded
                    if let recordingID { env["WF_RECORDING_ID"] = recordingID }
                    if live { env["WF_CAPTURE_LIVE"] = "1" }
                    object["EnvironmentVariables"] = env
                }
                return object
            }
            if let array = value as? [Any] { return array.map(configure) }
            if let string = value as? String { return string.replacingOccurrences(of: "__TESTROOT__", with: products.path) }
            return value
        }
        config = configure(config)
        let spec = run.appendingPathComponent("Capture.xctestrun")
        try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0).write(to: spec)
        return spec
    }

    func prepareRunner(deviceID: String) async throws -> URL {
        guard let runnerRoot, FileManager.default.fileExists(atPath: runnerRoot.appendingPathComponent("WebFramesCapture.xcodeproj/project.pbxproj").path) else {
            throw Self.failure("The bundled simulator runner is missing. Reinstall Web Frames.")
        }
        let fm = FileManager.default
        let paths = ["Runner/CaptureRunner.swift", "WebFramesCapture.xcodeproj/project.pbxproj", "WebFramesCapture.xcodeproj/xcshareddata/xcschemes/WebFramesCapture.xcscheme"]
        var fingerprint = try await command(["xcodebuild", "-version"])
        for path in paths { fingerprint.append(try Data(contentsOf: runnerRoot.appendingPathComponent(path))) }
        let key = SHA256.hash(data: fingerprint).map { String(format: "%02x", $0) }.joined()
        let root = cache.appendingPathComponent(key)
        let project = root.appendingPathComponent("Source")
        let derived = root.appendingPathComponent("DerivedData")
        let products = derived.appendingPathComponent("Build/Products")
        let ready = root.appendingPathComponent("ready")
        if fm.fileExists(atPath: ready.path),
           (try? fm.contentsOfDirectory(at: products, includingPropertiesForKeys: nil).contains(where: { $0.pathExtension == "xctestrun" })) == true { return products }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if fm.fileExists(atPath: project.path) { try fm.removeItem(at: project) }
        try fm.copyItem(at: runnerRoot, to: project)
        _ = try await command(["xcodebuild", "build-for-testing", "-project", project.appendingPathComponent("WebFramesCapture.xcodeproj").path,
            "-scheme", "WebFramesCapture", "-destination", "platform=iOS Simulator,id=\(deviceID)",
            "-derivedDataPath", derived.path], timeout: 180)
        try Data().write(to: ready)
        return products
    }

    /// Redirect both pipes to a file to avoid child-process pipe deadlocks. Never invoke a shell with recipe text.
    func command(_ arguments: [String], timeout: Double = 30, observeOutput: ((Data) -> Void)? = nil) async throws -> Data {
        try await runCommand(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: arguments, timeout: timeout, observeOutput: observeOutput)
    }

    func runCommand(executable: URL, arguments: [String], timeout: Double = 30, environment: [String: String] = [:], workingDirectory: URL? = nil, observeOutput: ((Data) -> Void)? = nil) async throws -> Data {
        try Task.checkCancellation()
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("WebFramesCommand-" + UUID().uuidString)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let errorLog = log.appendingPathExtension("stderr")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        let errorHandle = try FileHandle(forWritingTo: errorLog)
        defer { try? handle.close(); try? errorHandle.close(); try? FileManager.default.removeItem(at: log); try? FileManager.default.removeItem(at: errorLog) }
        let process = Process()
        let wrapped = ChildProcessWatchdog.wrap(executable: executable, arguments: arguments)
        process.executableURL = wrapped.executable; process.arguments = wrapped.arguments
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = handle; process.standardError = errorHandle
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        var nextOutput = Date.distantPast
        while process.isRunning {
            if let observeOutput, Date() >= nextOutput {
                if let bytes = try? Data(contentsOf: log) { observeOutput(bytes.suffix(64 * 1024)) }
                nextOutput = Date().addingTimeInterval(1)
            }
            if Task.isCancelled || Date() > deadline {
                process.terminate()
                // The watchdog traps TERM and terminates the complete child tree.
                await Task.detached { try? await Task.sleep(for: .seconds(3)) }.value
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                if Task.isCancelled { throw CancellationError() }
                throw Self.failure("Simulator operation timed out. The old screenshot was kept.")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        let bytes = try Data(contentsOf: log)
        observeOutput?(bytes.suffix(64 * 1024))
        guard process.terminationStatus == 0 else {
            let detail = String(data: (bytes + (try Data(contentsOf: errorLog))).suffix(2_000), encoding: .utf8) ?? "Device command failed."
            throw Self.failure("Simulator operation failed.\n\n" + detail)
        }
        return bytes
    }
}

extension WebFramesDocument {
    /// Optimistic check prevents a slow capture from overwriting an image edited while the runner was working.
    func applySimulatorCapture(_ image: SimulatorCapturedImage, frameID: String, expected: FrameModel) throws {
        try validateSimulatorCapture(frameID: frameID, expected: expected)
        workspace.updateFrameImage(id: frameID, dataURL: image.dataURL,
            pixelSize: CGSize(width: image.width, height: image.height), date: Date(), actor: "Simulator")
    }

    func validateSimulatorCapture(frameID: String, expected: FrameModel) throws {
        guard let frame = workspace.frames.first(where: { $0.id == frameID }), frame.isImage,
              frame.extras["imgUrl"] == expected.extras["imgUrl"], frame.simulatorCapture == expected.simulatorCapture else {
            throw SimulatorCapture.failure("The frame changed during capture. The new screenshot was not applied; refresh again.")
        }
    }
}
