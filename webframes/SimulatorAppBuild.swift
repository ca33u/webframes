import AppKit
import CryptoKit
import os

/// Typed local build settings. No shell commands, extra arguments, credentials or upload operations.
nonisolated struct SimulatorAppBuild: Codable, Hashable, Sendable {
    var projectPath: String
    var scheme: String = ""
    var configuration: String = "Debug"
    var module: String = "app"
    var variant: String = "Debug"

    var project: URL { URL(fileURLWithPath: projectPath).standardizedFileURL.resolvingSymlinksInPath() }

    func validate(platform: SimulatorCaptureRecipe.Platform) throws {
        guard projectPath.hasPrefix("/"), projectPath.utf8.count <= 4_096,
            !projectPath.contains("\0"), !projectPath.split(separator: "/").contains("..")
        else {
            throw SimulatorCapture.failure("Choose an absolute local project path.")
        }
        func name(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 200 && !value.hasPrefix("-")
                && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
        switch platform {
        case .iOS:
            guard ["xcodeproj", "xcworkspace"].contains(project.pathExtension), name(scheme), name(configuration) else {
                throw SimulatorCapture.failure("Choose an Xcode project / workspace, scheme and configuration.")
            }
        case .android:
            guard
                module.range(of: "^[A-Za-z][A-Za-z0-9_-]*(?::[A-Za-z][A-Za-z0-9_-]*)*$", options: .regularExpression)
                    != nil,
                variant.range(of: "^[A-Za-z][A-Za-z0-9]*$", options: .regularExpression) != nil,
                module.count <= 200, variant.count <= 100
            else {
                throw SimulatorCapture.failure("Enter an Android module (such as app) and variant (such as Debug).")
            }
        }
    }
}

/// Native builds have their own local permission; they never grant source sharing / Fix permissions.
@MainActor enum SimulatorBuildTrust {
    static let key = "webframes.simulatorBuildProjects"
    static func isTrusted(_ project: URL) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(ProjectTrust.canonicalPath(project))
    }
    static func revoke(_ project: URL) {
        UserDefaults.standard.set(
            (UserDefaults.standard.stringArray(forKey: key) ?? [])
                .filter { $0 != ProjectTrust.canonicalPath(project) }, forKey: key)
    }
    static func approve(_ project: URL, window: NSWindow) async -> Bool {
        if isTrusted(project) { return true }
        let alert = NSAlert()
        alert.messageText = "Allow Local Builds for This Project?"
        alert.informativeText =
            "Web Frames will run Xcode / Gradle and this project’s build scripts on your Mac, then update the app on the selected simulator.\n\n\(project.path)\n\nThis also permits agent-requested captures to rebuild this saved project when simulator capture is enabled. Sources are not uploaded. You can revoke this permission in Simulator Capture settings."
        alert.addButton(withTitle: "Allow Builds")
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        guard response == .alertFirstButtonReturn else { return false }
        var paths = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        paths.insert(ProjectTrust.canonicalPath(project))
        UserDefaults.standard.set(Array(paths).sorted(), forKey: key)
        return true
    }
}

/// Build first, verify the exact product identity, then update-install without erasing app data.
@MainActor final class SimulatorAppBuilder {
    private let service: SimulatorCapture
    private let cache: URL
    typealias Command = (URL, [String], Double, [String: String]) async throws -> Data
    private let permission: (URL) -> Bool
    private let execute: Command
    init(service: SimulatorCapture, cache: URL, permission: @escaping (URL) -> Bool, execute: Command? = nil) {
        self.service = service
        self.cache = cache
        self.permission = permission
        self.execute =
            execute ?? { executable, arguments, timeout, environment in
                try await service.runCommand(
                    executable: executable, arguments: arguments, timeout: timeout, environment: environment)
            }
    }
    private func xcrun(_ arguments: [String], timeout: Double) async throws -> Data {
        try await execute(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments, timeout, [:])
    }
    private func authorized(_ build: SimulatorAppBuild) throws {
        try Task.checkCancellation()
        guard permission(build.project) else {
            throw SimulatorCapture.failure(
                "Local builds are not allowed for this project. Choose / authorize it in Simulator Capture settings. The old screenshot was kept."
            )
        }
        guard FileManager.default.fileExists(atPath: build.project.path) else {
            throw SimulatorCapture.failure(
                "The saved source project is unavailable. Choose its new location in Simulator Capture settings.")
        }
    }
    func buildAndInstall(_ recipe: SimulatorCaptureRecipe, progress: (String) -> Void) async throws {
        try recipe.validate()
        guard let build = recipe.build else { return }
        try authorized(build)
        Log.doc.info("simulator app build started platform=\(recipe.platform.rawValue, privacy: .public)")
        let product: URL
        switch recipe.platform {
        case .iOS: product = try await buildIOS(build, recipe: recipe, progress: progress)
        case .android: product = try await buildAndroid(build, recipe: recipe, progress: progress)
        }
        try authorized(build)  // revoked permission / cancellation must not proceed to installation
        progress("Starting \(recipe.deviceName)…")
        try await service.startDevice(id: recipe.deviceID, platform: recipe.platform)
        try authorized(build)
        progress("Installing \(recipe.appBundleID) (keeping app data)…")
        if recipe.platform == .iOS {
            _ = try await service.command(["simctl", "install", recipe.deviceID, product.path], timeout: 120)
        } else {
            guard let serial = try await service.android.serial(for: recipe.deviceID) else {
                throw SimulatorCapture.failure("The selected Android emulator disconnected before installation.")
            }
            _ = try await service.android.adb(["-s", serial, "install", "-r", product.path], timeout: 120)
        }
        try Task.checkCancellation()
        Log.doc.info("simulator app installed platform=\(recipe.platform.rawValue, privacy: .public)")
    }
    private func buildIOS(_ build: SimulatorAppBuild, recipe: SimulatorCaptureRecipe, progress: (String) -> Void)
        async throws -> URL
    {
        let digest = SHA256.hash(data: Data((build.project.path + "\n" + recipe.deviceID).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let derived = cache.appendingPathComponent(digest)
        let args = [
            "xcodebuild", build.project.pathExtension == "xcworkspace" ? "-workspace" : "-project", build.project.path,
            "-scheme", build.scheme, "-configuration", build.configuration,
            "-destination", "platform=iOS Simulator,id=\(recipe.deviceID)", "-derivedDataPath", derived.path,
            "CODE_SIGNING_ALLOWED=NO",
        ]
        progress("Building iOS · \(build.scheme) · \(build.configuration)…")
        _ = try await xcrun(args + ["-quiet", "build"], timeout: 600)
        try authorized(build)
        let settings = try await xcrun(args + ["-showBuildSettings", "-json"], timeout: 90)
        return try Self.iosProduct(settings: settings, bundleID: recipe.appBundleID, derived: derived)
    }
    static func iosProduct(settings: Data, bundleID: String, derived: URL) throws -> URL {
        struct Target: Decodable { let buildSettings: [String: String] }
        let targets = try JSONDecoder().decode([Target].self, from: settings)
        let matches = targets.compactMap { item -> URL? in
            let s = item.buildSettings
            guard s["PRODUCT_BUNDLE_IDENTIFIER"] == bundleID, s["WRAPPER_EXTENSION"] == "app",
                s["PLATFORM_NAME"] == "iphonesimulator", let directory = s["TARGET_BUILD_DIR"],
                let product = s["FULL_PRODUCT_NAME"], product == URL(fileURLWithPath: product).lastPathComponent
            else { return nil }
            return URL(fileURLWithPath: directory).appendingPathComponent(product).resolvingSymlinksInPath()
        }
        guard matches.count == 1, let app = matches.first, contains(app, in: derived),
            let plist = try PropertyListSerialization.propertyList(
                from: Data(contentsOf: app.appendingPathComponent("Info.plist")), format: nil) as? [String: Any],
            plist["CFBundleIdentifier"] as? String == bundleID,
            (plist["CFBundleSupportedPlatforms"] as? [String])?.contains("iPhoneSimulator") == true
        else {
            throw SimulatorCapture.failure(
                "The scheme did not produce one simulator app with bundle ID \(bundleID). Check the project, scheme and app ID."
            )
        }
        return app
    }
    private func buildAndroid(_ build: SimulatorAppBuild, recipe: SimulatorCaptureRecipe, progress: (String) -> Void)
        async throws -> URL
    {
        let root = build.project
        let wrapper = root.appendingPathComponent("gradlew")
        guard Self.contains(wrapper.resolvingSymlinksInPath(), in: root),
            FileManager.default.isExecutableFile(atPath: wrapper.path)
        else {
            throw SimulatorCapture.failure("Choose the Android project folder containing an executable gradlew.")
        }
        let env = ProcessInfo.processInfo.environment
        guard
            let java = [env["JAVA_HOME"], "/Applications/Android Studio.app/Contents/jbr/Contents/Home"].compactMap({
                $0
            })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0 + "/bin/java") })
        else {
            throw SimulatorCapture.failure("Install Android Studio or set JAVA_HOME to a JDK.")
        }
        let sdk = try AndroidEmulatorCapture.sdkRoot()
        let variant = build.variant.prefix(1).uppercased() + build.variant.dropFirst()
        progress("Building Android · \(build.module) · \(variant)…")
        _ = try await service.runCommand(
            executable: wrapper,
            arguments: [
                "-p", root.path, "--no-daemon", "--console=plain",
                ":\(build.module):assemble\(variant)",
            ], timeout: 600,
            environment: ["JAVA_HOME": java, "ANDROID_HOME": sdk.path, "ANDROID_SDK_ROOT": sdk.path],
            workingDirectory: root)
        try authorized(build)
        let outputs = root.appendingPathComponent(build.module.replacingOccurrences(of: ":", with: "/"))
            .appendingPathComponent("build/outputs/apk")
        guard Self.contains(outputs.resolvingSymlinksInPath(), in: root) else {
            throw SimulatorCapture.failure("Android build outputs must remain inside the selected project.")
        }
        let apk = try Self.androidProduct(outputs: outputs, variant: build.variant, bundleID: recipe.appBundleID)
        let tools = try FileManager.default.contentsOfDirectory(
            at: sdk.appendingPathComponent("build-tools"), includingPropertiesForKeys: nil
        )
        .filter { FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent("aapt2").path) }
        .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
        guard let aapt = tools.first?.appendingPathComponent("aapt2") else {
            throw SimulatorCapture.failure("Install Android SDK Build Tools.")
        }
        let bytes = try await service.runCommand(executable: aapt, arguments: ["dump", "badging", apk.path])
        guard
            String(decoding: bytes, as: UTF8.self).components(separatedBy: .newlines)
                .contains(where: { $0.hasPrefix("package: name='" + recipe.appBundleID + "' ") })
        else {
            throw SimulatorCapture.failure(
                "The APK application ID does not match the saved recipe. Nothing was installed.")
        }
        return apk
    }
    static func androidProduct(outputs: URL, variant: String, bundleID: String) throws -> URL {
        struct Metadata: Decodable {
            struct Element: Decodable {
                struct Filter: Decodable { let filterType: String }
                let filters: [Filter]
                let outputFile: String
            }
            let applicationId: String
            let variantName: String
            let elements: [Element]
        }
        let fm = FileManager.default
        guard let files = fm.enumerator(at: outputs, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            throw SimulatorCapture.failure("Gradle did not create APK output metadata.")
        }
        var matches: [URL] = []
        var inspected = 0
        for case let file as URL in files where file.lastPathComponent == "output-metadata.json" {
            inspected += 1
            guard inspected <= 100, contains(file, in: outputs),
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 2 * 1024 * 1024
            else {
                throw SimulatorCapture.failure("Invalid Android build output metadata.")
            }
            let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: file))
            guard metadata.applicationId == bundleID, metadata.variantName.lowercased() == variant.lowercased() else {
                continue
            }
            for element in metadata.elements where element.filters.isEmpty {
                let apk = file.deletingLastPathComponent().appendingPathComponent(element.outputFile)
                    .resolvingSymlinksInPath()
                guard contains(apk, in: outputs), apk.pathExtension == "apk", fm.fileExists(atPath: apk.path) else {
                    continue
                }
                matches.append(apk)
            }
        }
        guard matches.count == 1, let apk = matches.first else {
            throw SimulatorCapture.failure(
                "The variant did not produce one universal APK for \(bundleID). Check module, variant and application ID; split APKs are not supported."
            )
        }
        return apk
    }
    nonisolated static func contains(_ child: URL, in root: URL) -> Bool {
        child.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(
            root.standardizedFileURL.resolvingSymlinksInPath().path + "/")
    }
}
