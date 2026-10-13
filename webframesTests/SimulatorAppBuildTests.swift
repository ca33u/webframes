import AppKit
import Testing

@testable import Web_Frames

@Suite("Native app build and install") @MainActor struct SimulatorAppBuildTests {
    private let ios = SimulatorCaptureRecipe(
        deviceID: "1781B954-FC16-45CB-AD60-58F4224410F3", deviceName: "iPhone 18 Pro Max",
        appBundleID: "app.essazanov.Comin", restartApp: true)
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WFBuildTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func oldRecipeDecodesWithoutBuildingAndNewBindingRoundTrips() throws {
        var recipe = ios
        let old = try JSONEncoder().encode(recipe)
        #expect(try JSONDecoder().decode(SimulatorCaptureRecipe.self, from: old).build == nil)
        recipe.build = .init(projectPath: "/Source/Comin.xcodeproj", scheme: "Comin")
        try recipe.validate()
        #expect(SimulatorCaptureRecipe(jsonValue: recipe.jsonValue) == recipe)
        var frame = FrameModel(
            id: "build", url: "image://build", label: "Build", x: 0, y: 0, w: 100, h: 100, num: 1, isImage: true)
        frame.simulatorCapture = recipe
        #expect(frame.simulatorCapture == recipe)
    }
    @Test func rejectsOptionsTraversalAndMissingApp() throws {
        for build in [
            SimulatorAppBuild(projectPath: "relative.xcodeproj", scheme: "Comin"),
            .init(projectPath: "/Source/../Comin.xcodeproj", scheme: "Comin"),
            .init(projectPath: "/Source/Comin.xcodeproj", scheme: "-help"),
            .init(projectPath: "/Source/Comin.xcodeproj", scheme: "Comin\narchive"),
            .init(projectPath: "/Source/Comin", scheme: "Comin"),
        ] {
            #expect(throws: (any Error).self) { try build.validate(platform: .iOS) }
        }
        for module in [":app", "../app", "app;echo", "-app"] {
            #expect(throws: (any Error).self) {
                try SimulatorAppBuild(projectPath: "/Source/Android", module: module).validate(platform: .android)
            }
        }
        for variant in ["debug publish", "Debug:upload", "-Release"] {
            #expect(throws: (any Error).self) {
                try SimulatorAppBuild(projectPath: "/Source/Android", variant: variant).validate(platform: .android)
            }
        }
        var recipe = ios
        recipe.appBundleID = ""
        recipe.build = .init(projectPath: "/Source/Comin.xcodeproj", scheme: "Comin")
        #expect(throws: (any Error).self) { try recipe.validate() }
    }
    @Test func changingPlatformClearsSourceBuildAndApplicationID() throws {
        var recipe = ios
        recipe.build = .init(projectPath: "/Source/Comin.xcodeproj", scheme: "Comin")
        let panel = SimulatorBuildPanel(recipe: recipe)
        #expect(panel.isEnabled && panel.appID == recipe.appBundleID)
        panel.platform = .android
        #expect(!panel.isEnabled && panel.appID.isEmpty)
        #expect(try panel.settings() == nil)
    }
    @Test func permissionIsCheckedBeforeAnyProjectExecution() async throws {
        var recipe = ios
        recipe.build = .init(projectPath: "/Source/Comin.xcodeproj", scheme: "Comin")
        var executed = false
        let builder = SimulatorAppBuilder(
            service: SimulatorCapture(), cache: URL(fileURLWithPath: "/tmp/WFBuildTests"), permission: { _ in false },
            execute: { _, _, _, _ in
                executed = true
                return Data()
            })
        await #expect(throws: (any Error).self) { try await builder.buildAndInstall(recipe) { _ in } }
        #expect(!executed)
        let service = SimulatorCapture(buildPermission: { _ in false })
        await #expect(throws: (any Error).self) { try await service.capture(recipe) }
        #expect(try await service.withCaptureSession { _ in true })
    }
    @Test func buildFailureAndCancellationDoNotReachInstall() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project with spaces.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var recipe = ios
        recipe.build = .init(projectPath: project.path, scheme: "Comin", configuration: "Debug")
        var commands: [[String]] = []
        let failed = SimulatorAppBuilder(
            service: SimulatorCapture(), cache: root, permission: { _ in true },
            execute: { _, args, _, _ in
                commands.append(args)
                throw SimulatorCapture.failure("Compile error")
            })
        await #expect(throws: (any Error).self) { try await failed.buildAndInstall(recipe) { _ in } }
        #expect(commands.count == 1 && commands[0].last == "build")
        #expect(commands[0].contains(project.path) && commands[0].contains("CODE_SIGNING_ALLOWED=NO"))
        var started = false
        let cancelled = SimulatorAppBuilder(
            service: SimulatorCapture(), cache: root, permission: { _ in true },
            execute: { _, _, _, _ in
                started = true
                try await Task.sleep(for: .seconds(30))
                return Data()
            })
        let task = Task { try await cancelled.buildAndInstall(recipe) { _ in } }
        for _ in 0..<100 {
            if started { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(started)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func buildConsentCanBeDeclinedGrantedAndRevokedWithoutSourceSharing() async throws {
        let root = try temporary()
        defer {
            try? FileManager.default.removeItem(at: root)
            SimulatorBuildTrust.revoke(root)
        }
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        func button(_ view: NSView, title: String) -> NSButton? {
            if let value = view as? NSButton, value.title == title { return value }
            return view.subviews.compactMap { button($0, title: title) }.first
        }
        for approve in [false, true] {
            let task = Task { await SimulatorBuildTrust.approve(root, window: window) }
            for _ in 0..<200 {
                if window.attachedSheet != nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let content = try #require(window.attachedSheet?.contentView)
            try #require(button(content, title: approve ? "Allow Builds" : "Cancel")).performClick(nil)
            #expect(await task.value == approve)
            #expect(SimulatorBuildTrust.isTrusted(root) == approve)
            #expect(!ProjectTrust.isTrusted(root))
        }
        SimulatorBuildTrust.revoke(root)
        #expect(!SimulatorBuildTrust.isTrusted(root))
    }
    @Test func verifiesIOSProductIdentityPlatformAndLocation() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Products/Comin.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "app.essazanov.Comin", "CFBundleSupportedPlatforms": ["iPhoneSimulator"],
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(
            to: app.appendingPathComponent("Info.plist"))
        var settings = [
            "PRODUCT_BUNDLE_IDENTIFIER": "app.essazanov.Comin", "WRAPPER_EXTENSION": "app",
            "PLATFORM_NAME": "iphonesimulator", "TARGET_BUILD_DIR": app.deletingLastPathComponent().path,
            "FULL_PRODUCT_NAME": "Comin.app",
        ]
        func bytes() throws -> Data { try JSONSerialization.data(withJSONObject: [["buildSettings": settings]]) }
        #expect(
            try SimulatorAppBuilder.iosProduct(settings: bytes(), bundleID: "app.essazanov.Comin", derived: root).path
                == app.resolvingSymlinksInPath().path
        )
        #expect(throws: (any Error).self) {
            try SimulatorAppBuilder.iosProduct(settings: bytes(), bundleID: "another.app", derived: root)
        }
        #expect(throws: (any Error).self) {
            try SimulatorAppBuilder.iosProduct(
                settings: bytes(), bundleID: "app.essazanov.Comin", derived: root.appendingPathComponent("Elsewhere"))
        }
        settings["PLATFORM_NAME"] = "iphoneos"
        #expect(throws: (any Error).self) {
            try SimulatorAppBuilder.iosProduct(settings: bytes(), bundleID: "app.essazanov.Comin", derived: root)
        }
    }
    @Test func verifiesAndroidVariantIdentityAndRejectsSplitOrEscapingAPK() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("debug")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: output.appendingPathComponent("app-debug.apk"))
        func metadata(_ file: String = "app-debug.apk", split: Bool = false) throws {
            try JSONSerialization.data(withJSONObject: [
                "applicationId": "com.essazanov.comin", "variantName": "debug",
                "elements": [
                    ["outputFile": file, "filters": split ? [["filterType": "ABI", "value": "arm64-v8a"]] : []]
                ],
            ])
            .write(to: output.appendingPathComponent("output-metadata.json"))
        }
        try metadata()
        #expect(
            try SimulatorAppBuilder.androidProduct(outputs: root, variant: "Debug", bundleID: "com.essazanov.comin")
                .lastPathComponent == "app-debug.apk")
        #expect(throws: (any Error).self) {
            try SimulatorAppBuilder.androidProduct(outputs: root, variant: "Release", bundleID: "com.essazanov.comin")
        }
        #expect(throws: (any Error).self) {
            try SimulatorAppBuilder.androidProduct(outputs: root, variant: "Debug", bundleID: "another.app")
        }
        try metadata(split: true)
        #expect(throws: (any Error).self) {
            try SimulatorAppBuilder.androidProduct(outputs: root, variant: "Debug", bundleID: "com.essazanov.comin")
        }
        try metadata("../../outside.apk")
        #expect(throws: (any Error).self) {
            try SimulatorAppBuilder.androidProduct(outputs: root, variant: "Debug", bundleID: "com.essazanov.comin")
        }
    }
}

extension SimulatorAppBuildTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WF_APP_BUILD_LIVE"] == "1"))
    func realXcodeBuildFailureKeepsFrameAndSourceRecipeSupportsUninstalledApp() async throws {
        let env = ProcessInfo.processInfo.environment
        let project = URL(fileURLWithPath: try #require(env["WF_COMIN_SOURCE"])).appendingPathComponent(
            "Comin/Comin.xcodeproj")
        var recipe = ios
        recipe.build = .init(projectPath: project.path, scheme: "WFBuildMissingScheme")
        let service = SimulatorCapture(buildPermission: { $0.path == project.path })
        let doc = makeTestDocument()
        defer {
            doc.updateChangeCount(.changeCleared)
            doc.close()
        }
        try doc.read(
            from: FileWrapper(url: URL(fileURLWithPath: try #require(env["WF_NATIVE_CAPTURE_BOARD"]))),
            ofType: WebFramesDocument.fileTypeIdentifier)
        let undo = try #require(doc.undoManager)
        undo.groupsByEvent = false
        undo.disableUndoRegistration()
        doc.workspace.setSimulatorCapture(id: "wf10-current", recipe: recipe)
        undo.enableUndoRegistration()
        let before = doc.workspace.frames
        let result = try await SimulatorCaptureBatch.run(
            document: doc,
            frames: [try #require(before.first { $0.id == "wf10-current" })], service: service)
        #expect(result.count == 1 && !result[0].updated && result[0].error != nil)
        #expect(result[0].error?.contains("WFBuildMissingScheme") == true)
        #expect(doc.workspace.frames == before && !undo.canUndo)
        recipe.build?.scheme = "Comin"
        recipe.appBundleID = "app.essazanov.WFAbsent"
        let panel = SimulatorCapturePanel(recipe: recipe)
        defer { panel.cancelDiscovery() }
        var ready = false
        panel.onValidityChange = { ready = $0 }
        for _ in 0..<600 {
            if ready { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(ready)
        #expect(try panel.recipe() == recipe)
        func labels(_ view: NSView) -> [String] {
            (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
        }
        #expect(labels(panel).contains("Ready. The source app will be built and installed before capture."))
        let evidence = URL(fileURLWithPath: try #require(env["WF_NATIVE_CAPTURE_EVIDENCE"]))
        try JSONSerialization.data(
            withJSONObject: [
                "realBuildFailureKeptFrame": doc.workspace.frames == before,
                "sourceRecipeSupportsUninstalledApp": ready,
            ], options: .prettyPrinted
        )
        .write(to: evidence.appendingPathComponent("build-failure-verification.json"))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WF_APP_BUILD_LIVE"] == "1"))
    func cominSourceBuildInstallMCPBatchUndoSaveAndReopen() async throws {
        let env = ProcessInfo.processInfo.environment
        let evidence = URL(fileURLWithPath: try #require(env["WF_NATIVE_CAPTURE_EVIDENCE"]))
        let source = URL(fileURLWithPath: try #require(env["WF_COMIN_SOURCE"]))
        let recipesURL = URL(fileURLWithPath: try #require(env["WF_COMIN_RECORDED_RECIPES"]))
        var recipes = try JSONDecoder().decode(
            [String: SimulatorCaptureRecipe].self, from: Data(contentsOf: recipesURL))
        var ios = try #require(recipes["ios"])
        var android = try #require(recipes["android"])
        ios.build = .init(projectPath: source.appendingPathComponent("Comin/Comin.xcodeproj").path, scheme: "Comin")
        android.build = .init(projectPath: source.appendingPathComponent("Android/Comin").path)
        recipes = ["ios": ios, "android": android]
        let allowed = Set(recipes.values.compactMap { $0.build?.project.path })
        let service = SimulatorCapture(buildPermission: { allowed.contains($0.path) })  // one run; no persistent trust changes
        try await service.startDevice(id: ios.deviceID)
        try await service.startDevice(id: android.deviceID, platform: .android)
        for recipe in [ios, android] {
            let panel = SimulatorCapturePanel(recipe: recipe)
            var ready = false
            panel.onValidityChange = { ready = $0 }
            for _ in 0..<600 {
                if ready { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(ready)
            #expect(try panel.recipe() == recipe)
            let settingsWindow = NSWindow(
                contentRect: panel.frame, styleMask: [.titled], backing: .buffered, defer: false)
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.contentView = panel
            settingsWindow.orderFront(nil)
            panel.layoutSubtreeIfNeeded()
            if let bitmap = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
                panel.cacheDisplay(in: panel.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: evidence.appendingPathComponent(recipe.platform.rawValue + "-build-settings.png"))
            }
            try JSONSerialization.data(
                withJSONObject: [
                    "width": panel.bounds.width, "height": panel.bounds.height,
                    "fittingHeight": panel.fittingSize.height,
                ], options: .prettyPrinted
            )
            .write(to: evidence.appendingPathComponent(recipe.platform.rawValue + "-settings-layout.json"))
            panel.cancelDiscovery()
            settingsWindow.close()
        }
        let marker = UUID().uuidString
        func iosData() async throws -> URL {
            let bytes = try await service.command([
                "simctl", "get_app_container", ios.deviceID, ios.appBundleID, "data",
            ])
            return URL(
                fileURLWithPath: String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let markerName = "Documents/wf-build-qa-marker"
        try Data(marker.utf8).write(to: try await iosData().appendingPathComponent(markerName))
        guard let serial = try await service.android.serial(for: android.deviceID) else {
            throw SimulatorCapture.failure("Test AVD unavailable")
        }
        _ = try await service.android.shell(
            serial,
            ["run-as", android.appBundleID, "sh", "-c", "printf '%s' '" + marker + "' > files/wf-build-qa-marker"])
        defer {
            Task { @MainActor in
                if let data = try? await iosData() {
                    try? FileManager.default.removeItem(at: data.appendingPathComponent(markerName))
                }
                _ = try? await service.android.shell(
                    serial, ["run-as", android.appBundleID, "rm", "-f", "files/wf-build-qa-marker"])
            }
        }
        let doc = makeTestDocument()
        defer {
            doc.updateChangeCount(.changeCleared)
            doc.close()
        }
        try doc.read(
            from: FileWrapper(url: URL(fileURLWithPath: try #require(env["WF_NATIVE_CAPTURE_BOARD"]))),
            ofType: WebFramesDocument.fileTypeIdentifier)
        let undo = try #require(doc.undoManager)
        undo.groupsByEvent = false
        undo.disableUndoRegistration()
        doc.workspace.setSimulatorCapture(id: "wf10-current", recipe: ios)
        doc.workspace.setSimulatorCapture(id: "wf10-reference", recipe: android)
        undo.enableUndoRegistration()
        let before = doc.workspace.frames
        let comments = doc.workspace.annotations
        let links = doc.workspace.links
        #expect(before.count == 3 && comments.count == 3 && links.count == 2)
        func saveAndCheck(_ name: String, frames: [FrameModel]) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                doc.save(to: doc.fileURL!, ofType: WebFramesDocument.fileTypeIdentifier, for: .saveOperation) {
                    if let error = $0 { c.resume(throwing: error) } else { c.resume() }
                }
            }
            let reopened = try WebFramesDocument(
                contentsOf: #require(doc.fileURL), ofType: WebFramesDocument.fileTypeIdentifier)
            defer {
                reopened.updateChangeCount(.changeCleared)
                reopened.close()
            }
            #expect(reopened.workspace.frames == frames)
            #expect(reopened.workspace.annotations == comments && reopened.workspace.links == links)
            try JSONEncoder().encode(reopened.payload).write(to: evidence.appendingPathComponent("build-\(name).json"))
        }
        try await saveAndCheck("before", frames: before)
        let inbox = CommentsMCPInbox(
            document: doc, permission: { false }, frameImagesPermission: { false }, simulatorPermission: { true },
            captureService: service)
        inbox.start()
        defer { inbox.stop() }
        let captures = try before.prefix(2).map { frame -> CommentsMCPInbox.SimulatorRequest in
            guard case .string(let url)? = frame.extras["imgUrl"] else {
                throw SimulatorCapture.failure("Missing image")
            }
            return .init(
                frameID: frame.id,
                beforeHash: CommentsMCPInbox.imageHash(try #require(CommentsMCPInbox.imageBytes(url))),
                recipe: try #require(frame.simulatorCapture))
        }
        let request = CommentsMCPInbox.Request(
            id: UUID().uuidString, deadline: Date().timeIntervalSince1970 + 900, resolved: false, comments: [],
            simulatorCaptures: captures)
        let directory = CommentsMCPInbox.directory(for: try #require(doc.fileURL))
        let reply = directory.appendingPathComponent(request.id + ".response.json")
        try JSONEncoder().encode(request).write(
            to: directory.appendingPathComponent(request.id + ".request.json"), options: .atomic)
        for _ in 0..<9_100 {
            if FileManager.default.fileExists(atPath: reply.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let bytes = try Data(contentsOf: reply)
        try bytes.write(to: evidence.appendingPathComponent("build-mcp.json"))
        let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        #expect(
            result?["ok"] as? Bool == true && result?["updated"] as? Int == 2,
            "MCP build result: \(String(decoding: bytes, as: UTF8.self))")
        let after = doc.workspace.frames
        #expect(zip(before.prefix(2), after.prefix(2)).allSatisfy { $0.extras["imgUrl"] != $1.extras["imgUrl"] })
        #expect(after[2] == before[2])
        #expect(
            zip(before, after).allSatisfy { a, b in
                a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h && a.simulatorCapture == b.simulatorCapture
                    && a.label == b.label
            })
        for frame in after.prefix(2) {
            guard case .string(let url)? = frame.extras["imgUrl"] else { continue }
            try CommentsMCPInbox.imageBytes(url)?.write(to: evidence.appendingPathComponent(frame.id + "-built.png"))
        }
        let iosPreserved =
            try Data(contentsOf: try await iosData().appendingPathComponent(markerName)) == Data(marker.utf8)
        let androidPreserved =
            try await service.android.adb([
                "-s", serial, "exec-out", "run-as", android.appBundleID, "cat", "files/wf-build-qa-marker",
            ]) == Data(marker.utf8)
        #expect(iosPreserved && androidPreserved)
        try await saveAndCheck("updated", frames: after)
        #expect(undo.undoActionName == "Update Screenshots")
        undo.undo()
        #expect(doc.workspace.frames == before)
        try await saveAndCheck("undo", frames: before)
        undo.redo()
        #expect(doc.workspace.frames == after)
        try await saveAndCheck("redo", frames: after)
        try JSONEncoder().encode(recipes).write(to: evidence.appendingPathComponent("build-recipes.json"))
        let copy = evidence.appendingPathComponent("Comin Build Capture.webframes")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: #require(doc.fileURL), to: copy)
        try JSONSerialization.data(
            withJSONObject: [
                "platforms": ["ios", "android"], "updated": result?["updated"] ?? 0,
                "iosAppDataPreserved": iosPreserved, "androidAppDataPreserved": androidPreserved,
                "commentsPreserved": doc.workspace.annotations == comments,
                "linksPreserved": doc.workspace.links == links,
                "untouchedThirdFrame": after[2] == before[2],
            ], options: [.prettyPrinted, .sortedKeys]
        )
        .write(to: evidence.appendingPathComponent("verification.json"))
        try? FileManager.default.removeItem(at: reply)
    }
}
