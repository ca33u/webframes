import AppKit
import CryptoKit

@MainActor final class AndroidEmulatorCapture {
    static let sdkPreference = "webframes.androidSDKPath"
    private let commands: SimulatorCapture
    private let sources: URL?
    private let cache: URL
    static let package = "app.essazanov.webframes.capture"
    init(commands: SimulatorCapture, sources: URL?, cache: URL) { self.commands = commands; self.sources = sources; self.cache = cache }

    static func sdkRoot() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let candidates = [UserDefaults.standard.string(forKey: sdkPreference), env["ANDROID_HOME"], env["ANDROID_SDK_ROOT"],
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk").path].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0 + "/platform-tools/adb") }) else {
            throw SimulatorCapture.failure("Android SDK not found. Choose its folder in Capture settings, or install it with Android Studio.")
        }
        return URL(fileURLWithPath: path)
    }
    nonisolated static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    func adb(_ args: [String], timeout: Double = 30) async throws -> Data {
        try await commands.runCommand(executable: Self.sdkRoot().appendingPathComponent("platform-tools/adb"), arguments: args, timeout: timeout)
    }
    func shell(_ serial: String, _ args: [String], timeout: Double = 30) async throws -> Data {
        try await adb(["-s", serial, "shell"] + args.map(Self.shellQuote), timeout: timeout)
    }
    private func text(_ bytes: Data) -> String { String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    private func running() async throws -> [(serial: String, name: String)] {
        let output = text(try await adb(["devices"]))
        var result: [(String, String)] = []
        for line in output.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, fields[1] == "device",
                  fields[0].range(of: "^emulator-[0-9]+$", options: .regularExpression) != nil else { continue }
            let raw = text(try await adb(["-s", fields[0], "emu", "avd", "name"]))
            let name = raw.components(separatedBy: .newlines).first ?? ""
            result.append((fields[0], name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil && name != "OK" ? name : ""))
        }
        return result
    }
    func devices() async throws -> [SimulatorCapture.Device] {
        let sdk = try Self.sdkRoot()
        let emulator = sdk.appendingPathComponent("emulator/emulator")
        let active = try await running()
        var result: [SimulatorCapture.Device] = []
        for device in active {
            let booted = text(try await shell(device.serial, ["getprop", "sys.boot_completed"])) == "1"
            result.append(.init(id: device.name.isEmpty ? device.serial : "android-avd:" + device.name,
                name: device.name.isEmpty ? device.serial : device.name, booted: booted, runtime: "Android Emulator", platform: .android))
        }
        if FileManager.default.isExecutableFile(atPath: emulator.path) {
            let names = text(try await commands.runCommand(executable: emulator, arguments: ["-list-avds"]))
            let base = ProcessInfo.processInfo.environment["ANDROID_AVD_HOME"].map { URL(fileURLWithPath: $0) } ??
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/avd")
            for name in names.components(separatedBy: .newlines) where !name.isEmpty {
                guard name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
                      !active.contains(where: { $0.name == name }) else { continue }
                let ini = try? String(contentsOf: base.appendingPathComponent(name + ".ini"), encoding: .utf8)
                let path = ini?.components(separatedBy: .newlines).first(where: { $0.hasPrefix("path=") }).map { String($0.dropFirst(5)) }
                let config = path.map { URL(fileURLWithPath: $0).appendingPathComponent("config.ini") } ?? base.appendingPathComponent(name + ".avd/config.ini")
                guard FileManager.default.fileExists(atPath: config.path) else { continue }
                result.append(.init(id: "android-avd:" + name, name: name, booted: false, runtime: "Android Emulator", platform: .android))
            }
        }
        return result.sorted { $0.booted != $1.booted ? $0.booted : $0.name < $1.name }
    }
    func serial(for id: String) async throws -> String? {
        try await running().first(where: { id == $0.serial || id == "android-avd:" + $0.name })?.serial
    }
    func startDevice(id: String) async throws {
        guard id.range(of: "^(android-avd:[A-Za-z0-9_.-]+|emulator-[0-9]+)$", options: .regularExpression) != nil else {
            throw SimulatorCapture.failure("Choose an Android emulator.")
        }
        if try await serial(for: id) == nil {
            guard id.hasPrefix("android-avd:"), try await devices().contains(where: { $0.id == id }) else { throw SimulatorCapture.failure("The saved Android emulator is unavailable.") }
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let log = cache.appendingPathComponent("emulator.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = try Self.sdkRoot().appendingPathComponent("emulator/emulator")
            process.arguments = ["-avd", String(id.dropFirst("android-avd:".count)), "-no-snapshot-save"]
            process.standardOutput = handle; process.standardError = handle
            try process.run()
            process.terminationHandler = { _ in try? handle.close() }
        }
        let end = Date().addingTimeInterval(240)
        while Date() < end {
            try Task.checkCancellation()
            if let serial = try await serial(for: id), text(try await shell(serial, ["getprop", "sys.boot_completed"])) == "1" { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw SimulatorCapture.failure("Android emulator did not finish booting. Check the AVD in Android Studio.")
    }
    func apps(deviceID: String) async throws -> [SimulatorCapture.App] {
        guard let serial = try await serial(for: deviceID) else { throw SimulatorCapture.failure("Start this Android emulator first.") }
        let packages = text(try await shell(serial, ["cmd", "package", "query-activities", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER"]))
        let ids = Set(packages.components(separatedBy: .newlines).compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = line.components(separatedBy: "/").first ?? ""
            return line.contains("/") && id.range(of: "^[A-Za-z0-9_]+(\\.[A-Za-z0-9_]+)+$", options: .regularExpression) != nil && id != Self.package ? id : nil
        })
        return ids.sorted().map { .init(id: $0, name: $0.components(separatedBy: ".").last ?? $0) }
    }

    func capture(_ recipe: SimulatorCaptureRecipe, progress: (String) -> Void) async throws -> SimulatorCapturedImage {
        progress("Starting Android emulator…")
        try await startDevice(id: recipe.deviceID)
        guard let serial = try await serial(for: recipe.deviceID) else { throw SimulatorCapture.failure("Android emulator disconnected.") }
        if recipe.appBundleID.isEmpty {
            progress("Capturing the current Android screen…")
            try await checkScreenProtection(serial: serial)
            return try SimulatorCapturedImage(data: await adb(["-s", serial, "exec-out", "screencap", "-p"]))
        }
        guard try await apps(deviceID: recipe.deviceID).contains(where: { $0.id == recipe.appBundleID }) else { throw SimulatorCapture.failure("The saved app is not installed on this Android emulator.") }
        progress("Preparing Web Frames' Android screen runner…")
        let apk = try await prepareRunner()
        let installed = text(try await adb(["-s", serial, "install", "-r", apk.path], timeout: 60))
        guard installed.contains("Success") else { throw SimulatorCapture.failure("Could not install the local Android capture runner.") }
        let runID = UUID().uuidString
        let screenshot = "files/capture-\(runID).png"
        do {
            try await launchApp(recipe, serial: serial)
            progress("Running \(recipe.steps.count) Android screen actions…")
            let encoded = try JSONEncoder().encode(recipe).base64EncodedString()
            let output = text(try await shell(serial, ["am", "instrument", "-w", "-r", "-e", "recipe", encoded, "-e", "runID", runID,
                Self.package + "/.CaptureInstrumentation"], timeout: 60 + Double(recipe.steps.count) * 15))
            guard output.contains("INSTRUMENTATION_RESULT: wfResult=ok"), output.contains("INSTRUMENTATION_CODE: -1") else {
                let error = output.components(separatedBy: .newlines).first(where: { $0.hasPrefix("INSTRUMENTATION_RESULT: wfError=") })
                throw SimulatorCapture.failure(error.map { String($0.dropFirst("INSTRUMENTATION_RESULT: wfError=".count)) } ?? "Android screen runner failed. " + String(output.suffix(1_000)))
            }
            try await checkScreenProtection(serial: serial)
            let bytes = try await adb(["-s", serial, "exec-out", "run-as", Self.package, "cat", screenshot])
            try Task.checkCancellation()
            let image = try SimulatorCapturedImage(data: bytes)
            await cleanup(serial: serial, screenshot: screenshot)
            return image
        } catch {
            await cleanup(serial: serial, screenshot: screenshot)
            throw error
        }
    }
    func launchApp(_ recipe: SimulatorCaptureRecipe, serial: String) async throws {
        if recipe.restartApp || recipe.testState != nil { _ = try await shell(serial, ["am", "force-stop", recipe.appBundleID]) }
        let componentOutput = text(try await shell(serial, ["cmd", "package", "resolve-activity", "--brief", "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", recipe.appBundleID]))
        guard let component = componentOutput.components(separatedBy: .newlines).last, component.hasPrefix(recipe.appBundleID + "/") else {
            throw SimulatorCapture.failure("The selected Android app has no launcher activity.")
        }
        var arguments = ["am", "start", "-W", "-n", component]
        if let state = recipe.testState {
            for (key, value) in state.launchEnvironment.sorted(by: { $0.key < $1.key }) { arguments += ["--es", key, value] }
        }
        let launch = text(try await shell(serial, arguments))
        guard !launch.contains("Error:") else { throw SimulatorCapture.failure("Android app launch failed: " + launch) }
        if recipe.testState == nil, let link = recipe.deeplink {
            let opened = text(try await shell(serial, ["am", "start", "-W", "-a", "android.intent.action.VIEW", "-d", link, "-p", recipe.appBundleID]))
            guard !opened.contains("Error:") else { throw SimulatorCapture.failure("The selected app cannot open this deeplink.") }
        }
    }

    nonisolated static func hasSecureVisibleWindow(_ dump: String) -> Bool {
        dump.components(separatedBy: "  Window #").dropFirst().contains { block in
            var secure = block.range(of: "\\bfl=[^\\n}]*\\bSECURE\\b", options: .regularExpression) != nil
            if let flags = block.range(of: "\\bfl=(?:#|0x)[0-9a-fA-F]+", options: .regularExpression) {
                let raw = String(block[flags]).dropFirst(3).replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "0x", with: "")
                secure = secure || (UInt64(raw, radix: 16).map { $0 & 0x2000 != 0 } ?? false)
            }
            return secure && block.contains("isVisible=true") && block.contains("mHasSurface=true")
        }
    }
    func checkScreenProtection(serial: String) async throws {
        let dump = text(try await shell(serial, ["dumpsys", "window", "windows"]))
        guard !Self.hasSecureVisibleWindow(dump) else {
            throw SimulatorCapture.failure("This Android screen blocks screenshots (FLAG_SECURE). Allow screenshots in the app's own settings before capture. The old frame image was kept.")
        }
    }
    private func cleanup(serial: String, screenshot: String) async {
        // A cancelled task must still stop the device-side instrumentation, not just its host adb process.
        await Task { @MainActor in
            _ = try? await shell(serial, ["am", "force-stop", Self.package])
            _ = try? await shell(serial, ["run-as", Self.package, "rm", "-f", screenshot])
        }.value
    }

    func prepareRunner() async throws -> URL {
        guard let sources else { throw SimulatorCapture.failure("The bundled Android runner is missing. Reinstall Web Frames.") }
        let fm = FileManager.default, sdk = try Self.sdkRoot()
        let tools = try fm.contentsOfDirectory(at: sdk.appendingPathComponent("build-tools"), includingPropertiesForKeys: nil)
            .filter { fm.isExecutableFile(atPath: $0.appendingPathComponent("aapt2").path) }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        let platforms = try fm.contentsOfDirectory(at: sdk.appendingPathComponent("platforms"), includingPropertiesForKeys: nil)
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("android.jar").path) }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        guard let tools = tools.first, let platform = platforms.first else { throw SimulatorCapture.failure("Install Android SDK Build Tools and a platform in Android Studio.") }
        let env = ProcessInfo.processInfo.environment
        let javaCandidates = [env["JAVA_HOME"], "/Applications/Android Studio.app/Contents/jbr/Contents/Home"].compactMap { $0 }
        guard let java = javaCandidates.first(where: { fm.isExecutableFile(atPath: $0 + "/bin/javac") }) else { throw SimulatorCapture.failure("Install Android Studio or a JDK to prepare the Android runner.") }
        let javaURL = URL(fileURLWithPath: java), javaEnvironment = ["JAVA_HOME": java]
        var fingerprint = Data((sdk.path + tools.lastPathComponent + platform.lastPathComponent + java).utf8)
        for file in ["CaptureInstrumentation.java", "AndroidManifest.xml"] { fingerprint.append(try Data(contentsOf: sources.appendingPathComponent(file))) }
        let key = SHA256.hash(data: fingerprint).map { String(format: "%02x", $0) }.joined()
        let root = cache.appendingPathComponent(key), apk = root.appendingPathComponent("runner.apk")
        if fm.fileExists(atPath: apk.path) { return apk }
        let classes = root.appendingPathComponent("classes"), dex = root.appendingPathComponent("dex")
        try fm.createDirectory(at: classes, withIntermediateDirectories: true); try fm.createDirectory(at: dex, withIntermediateDirectories: true)
        let jar = platform.appendingPathComponent("android.jar").path
        _ = try await commands.runCommand(executable: javaURL.appendingPathComponent("bin/javac"), arguments: ["-source", "8", "-target", "8", "-classpath", jar, "-d", classes.path, sources.appendingPathComponent("CaptureInstrumentation.java").path], timeout: 60)
        let classFiles = (fm.enumerator(at: classes, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "class" }.map(\.path)
        _ = try await commands.runCommand(executable: tools.appendingPathComponent("d8"), arguments: ["--lib", jar, "--min-api", "26", "--output", dex.path] + classFiles, timeout: 60, environment: javaEnvironment)
        let unsigned = root.appendingPathComponent("unsigned.apk"), aligned = root.appendingPathComponent("aligned.apk")
        _ = try await commands.runCommand(executable: tools.appendingPathComponent("aapt2"), arguments: ["link", "--manifest", sources.appendingPathComponent("AndroidManifest.xml").path, "-I", jar, "-o", unsigned.path])
        _ = try await commands.runCommand(executable: URL(fileURLWithPath: "/usr/bin/zip"), arguments: ["-j", unsigned.path, dex.appendingPathComponent("classes.dex").path])
        _ = try await commands.runCommand(executable: tools.appendingPathComponent("zipalign"), arguments: ["-f", "4", unsigned.path, aligned.path])
        let signing = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("app.essazanov.webframes/AndroidRunnerSigning")
        try fm.createDirectory(at: signing, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let keystore = signing.appendingPathComponent("runner.jks"), password = signing.appendingPathComponent("password")
        if !fm.fileExists(atPath: keystore.path) {
            try Data(UUID().uuidString.utf8).write(to: password, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: password.path)
            _ = try await commands.runCommand(executable: javaURL.appendingPathComponent("bin/keytool"), arguments: ["-genkeypair", "-alias", "webframes", "-keyalg", "RSA", "-keysize", "2048", "-validity", "3650", "-dname", "CN=Web Frames Local Runner", "-keystore", keystore.path, "-storepass:file", password.path, "-keypass:file", password.path], timeout: 60)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keystore.path)
        }
        let temporary = root.appendingPathComponent("signed.apk")
        _ = try await commands.runCommand(executable: tools.appendingPathComponent("apksigner"), arguments: ["sign", "--ks", keystore.path, "--ks-key-alias", "webframes", "--ks-pass", "file:" + password.path, "--out", temporary.path, aligned.path], timeout: 60, environment: javaEnvironment)
        try fm.moveItem(at: temporary, to: apk)
        return apk
    }
}
