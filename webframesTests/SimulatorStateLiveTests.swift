import AppKit
import Testing

@testable import Web_Frames

@Suite("Test state and selected-frame live preview", .serialized) @MainActor struct SimulatorStateLiveTests {
    private let ios = SimulatorCaptureRecipe(
        deviceID: "1781B954-FC16-45CB-AD60-58F4224410F3", deviceName: "iPhone 18 Pro Max",
        appBundleID: "app.essazanov.Comin", restartApp: true)
    private let android = SimulatorCaptureRecipe(
        deviceID: "android-avd:WF_Comin_Capture", deviceName: "WF_Comin_Capture", appBundleID: "com.essazanov.comin",
        restartApp: true, platform: .android)
    private func state(_ recipe: SimulatorCaptureRecipe, account: String, tag: String, theme: SimulatorTestState.Theme)
        -> SimulatorCaptureRecipe
    {
        var result = recipe
        result.testState = .init(
            name: account + " — " + tag, account: account, data: ["tag": tag], theme: theme,
            preparation: [
                .init(action: .wait, value: "Забыли пароль?"), .init(action: .tap, value: "Забыли пароль?"),
                .init(action: .tap, value: recipe.platform == .iOS ? "Почта восстановления" : "E-mail"),
                .init(action: .type, value: "{{account}}+{{data.tag}}@example.invalid"),
            ], readySelector: "Сброс пароля")
        return result
    }
    private func packet(_ value: Data) -> Data {
        let n = value.count
        return Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)]) + value
    }
    @Test func stateExpansionIsSinglePassAndRoundTripsWithoutChangingSavedValues() throws {
        let saved = state(ios, account: "alice", tag: "{{account}}", theme: .dark)
        let execution = try saved.resolvingTestState()
        #expect(execution.testState?.preparation.last?.value == "alice+{{account}}@example.invalid")
        #expect(saved.testState?.preparation.last?.value == "{{account}}+{{data.tag}}@example.invalid")
        #expect(SimulatorCaptureRecipe(jsonValue: saved.jsonValue) == saved)
        var old = ios
        old.testState = nil
        #expect(try JSONDecoder().decode(SimulatorCaptureRecipe.self, from: JSONEncoder().encode(old)).testState == nil)
        let context = try #require(saved.testState).launchEnvironment
        #expect(context["WEBFRAMES_TEST_ACCOUNT"] == "alice" && context["WEBFRAMES_TEST_THEME"] == "dark")
    }
    @Test func invalidStateFailsBeforeDeviceCommands() async throws {
        var recipe = state(ios, account: "alice", tag: "one", theme: .light)
        recipe.testState?.readySelector = ""
        #expect(throws: (any Error).self) { try recipe.validate() }
        await #expect(throws: (any Error).self) { try await SimulatorCapture().capture(recipe) }
        recipe.testState?.readySelector = "Ready"
        recipe.testState?.preparation = [.init(action: .type, value: "{{data.missing}}")]
        #expect(throws: (any Error).self) { try recipe.resolvingTestState() }
        recipe.testState?.preparation = [.init(action: .type, value: "{{account")]
        #expect(throws: (any Error).self) { try recipe.resolvingTestState() }
        recipe.testState?.data = ["bad.key": "x"]
        #expect(throws: (any Error).self) { try recipe.validate() }
        var unsupported = android
        unsupported.testState = .init(name: "Unsupported", launchArguments: ["-flag"], readySelector: "Ready")
        #expect(throws: (any Error).self) { try unsupported.validate() }
        unsupported.testState?.launchArguments = []
        unsupported.testState?.account = "a\0b"
        #expect(throws: (any Error).self) { try unsupported.validate() }
    }
    @Test func stateEditorRestoresAndCanRemovePreset() throws {
        let recipe = state(ios, account: "alice", tag: "baseline", theme: .dark)
        let panel = SimulatorTestStatePanel(state: recipe.testState)
        #expect(try panel.settings() == recipe.testState)
        let alert = NSAlert()
        alert.messageText = "Test State"
        alert.informativeText = "Prepare account, data and appearance before opening this screen."
        alert.accessoryView = panel
        alert.addButton(withTitle: "Use State")
        alert.addButton(withTitle: "Cancel")
        alert.layout()
        let content = try #require(alert.window.contentView)
        content.layoutSubtreeIfNeeded()
        #expect(panel.bounds.width >= 500 && panel.bounds.height >= 560)
        if let path = ProcessInfo.processInfo.environment["WF_NATIVE_CAPTURE_EVIDENCE"] {
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: path).appendingPathComponent("test-state-settings.png"))
        }
        func checkbox(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.accessibilityIdentifier() == "capture.state.enabled" {
                return button
            }
            return view.subviews.compactMap(checkbox).first
        }
        let toggle = try #require(checkbox(panel))
        toggle.performClick(nil)
        #expect(try panel.settings() == nil)
    }
    @Test func framedStreamHandlesPartialPacketsAndDropsOlderFrames() throws {
        let buffer = SimulatorLiveFrameBuffer()
        let first = packet(Data([1, 2, 3]))
        let second = packet(Data([7, 8]))
        buffer.feed(first.prefix(2))
        #expect(try buffer.take() == nil)
        buffer.feed(first.dropFirst(2) + second)
        #expect(try buffer.take() == Data([7, 8]))
        #expect(try buffer.take() == nil)
        buffer.finish()
        #expect(throws: (any Error).self) { try buffer.take() }
        let bad = SimulatorLiveFrameBuffer()
        bad.feed(Data([0xff, 0xff, 0xff, 0xff]))
        #expect(throws: (any Error).self) { try bad.take() }
        let short = SimulatorLiveFrameBuffer()
        short.feed(Data([0, 0, 0, 3, 1]))
        short.finish()
        #expect(throws: (any Error).self) { try short.take() }
    }
    @Test func invalidSelectionDoesNotReserveRunnerAndCanBeStoppedImmediately() async throws {
        let coordinator = SimulatorLivePreview()
        var cleared = false
        _ = coordinator.start(
            frameID: "absent", recipe: ios, valid: { false }, image: { if $0 == nil { cleared = true } })
        await coordinator.waitUntilIdle()
        #expect(coordinator.activeID == nil && cleared)
        let id = coordinator.start(frameID: "absent", recipe: ios, valid: { false }, image: { _ in })
        await coordinator.stopAndWait(id)
        #expect(coordinator.activeID == nil)
    }
    private func close(_ doc: WebFramesDocument) {
        doc.updateChangeCount(.changeCleared)
        doc.close()
    }
    private func save(_ doc: WebFramesDocument) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            doc.save(to: doc.fileURL!, ofType: WebFramesDocument.fileTypeIdentifier, for: .saveOperation) {
                if let error = $0 { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }
    private func luminance(_ image: SimulatorCapturedImage) throws -> Double {
        let bitmap = try #require(NSBitmapImageRep(data: image.data))
        var sum = 0.0
        var count = 0.0
        for y in stride(
            from: bitmap.pixelsHigh / 10, to: bitmap.pixelsHigh * 9 / 10, by: max(1, bitmap.pixelsHigh / 25))
        {
            for x in stride(
                from: bitmap.pixelsWide / 10, to: bitmap.pixelsWide * 9 / 10, by: max(1, bitmap.pixelsWide / 25))
            {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                    sum += Double(color.redComponent + color.greenComponent + color.blueComponent) / 3
                    count += 1
                }
            }
        }
        return sum / max(1, count)
    }
    private func clickLive(_ host: CanvasHost, id: String) throws {
        func card(_ view: NSView) -> FrameCardView? {
            if let view = view as? FrameCardView, view.id == id { return view }
            return view.subviews.compactMap(card).first
        }
        func button(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == "capture.live" { return view }
            return view.subviews.compactMap(button).first
        }
        let frame = try #require(card(host))
        let target = try #require(button(frame.chromeHost))
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: host.window?.windowNumber ?? 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        target.mouseDown(with: event)
    }
    private func awaitLive(_ host: CanvasHost, id: String, changedFrom: Double? = nil) async throws
        -> SimulatorCapturedImage
    {
        for _ in 0..<3_600 {
            if let image = host.bridge.simulatorLiveImage(id: id) {
                if let value = changedFrom {
                    if abs(try luminance(image) - value) > 0.1 { return image }
                } else {
                    return image
                }
            }
            if host.simulatorLiveFrameID == nil {
                throw SimulatorLivePreview.shared.failure
                    ?? SimulatorCapture.failure("Live preview ended before the expected frame")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SimulatorCapture.failure("Live frame did not arrive / change")
    }
    private func appearance(_ recipe: SimulatorCaptureRecipe, service: SimulatorCapture) async throws -> String {
        let bytes: Data
        if recipe.platform == .iOS {
            bytes = try await service.command(["simctl", "ui", recipe.deviceID, "appearance"])
        } else {
            let serial = try #require(try await service.android.serial(for: recipe.deviceID))
            bytes = try await service.android.shell(serial, ["cmd", "uimode", "night"])
        }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WF_STATE_LIVE"] == "1"))
    func populatedCominStateMCPUndoReopenAndSelectedLiveCycle() async throws {
        let env = ProcessInfo.processInfo.environment
        let evidence = URL(fileURLWithPath: try #require(env["WF_NATIVE_CAPTURE_EVIDENCE"]))
        let doc = makeTestDocument()
        defer { close(doc) }
        try doc.read(
            from: FileWrapper(url: URL(fileURLWithPath: try #require(env["WF_NATIVE_CAPTURE_BOARD"]))),
            ofType: WebFramesDocument.fileTypeIdentifier)
        var alice = state(ios, account: "alice", tag: "baseline", theme: .dark)
        var bob = state(android, account: "bob", tag: "variant", theme: .light)
        if let source = env["WF_COMIN_SOURCE"] {
            alice.build = .init(projectPath: source + "/Comin/Comin.xcodeproj", scheme: "Comin")
            bob.build = .init(projectPath: source + "/Android/Comin")
        }
        let allowed = Set([alice, bob].compactMap { $0.build?.project.path })
        let service = SimulatorCapture(buildPermission: { allowed.contains($0.path) })
        let iosAppearance = try await appearance(alice, service: service)
        let androidAppearance = try await appearance(bob, service: service)
        let undo = try #require(doc.undoManager)
        undo.groupsByEvent = false
        undo.disableUndoRegistration()
        doc.workspace.setSimulatorCapture(id: "wf10-current", recipe: alice)
        doc.workspace.setSimulatorCapture(id: "wf10-reference", recipe: bob)
        undo.enableUndoRegistration()
        let before = doc.workspace.frames
        let comments = doc.workspace.annotations
        let links = doc.workspace.links
        #expect(before.count == 3 && comments.count == 3 && links.count == 2)
        try await save(doc)
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
        let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        try bytes.write(to: evidence.appendingPathComponent("state-mcp.json"))
        #expect(result?["updated"] as? Int == 2, "\(String(decoding: bytes, as: UTF8.self))")
        let after = doc.workspace.frames
        #expect(try await appearance(alice, service: service) == iosAppearance)
        #expect(try await appearance(bob, service: service) == androidAppearance)
        #expect(after[2] == before[2])
        #expect(doc.workspace.annotations == comments && doc.workspace.links == links)
        for (name, expected) in [("updated", after), ("undo", before), ("redo", after)] {
            try await save(doc)
            let copy = try WebFramesDocument(
                contentsOf: #require(doc.fileURL), ofType: WebFramesDocument.fileTypeIdentifier)
            #expect(
                copy.workspace.frames == expected && copy.workspace.annotations == comments
                    && copy.workspace.links == links)
            try JSONEncoder().encode(copy.payload).write(to: evidence.appendingPathComponent("state-\(name).json"))
            close(copy)
            if name == "updated" { undo.undo() } else if name == "undo" { undo.redo() }
        }
        for frame in after.prefix(2) {
            guard case .string(let value)? = frame.extras["imgUrl"] else { continue }
            try CommentsMCPInbox.imageBytes(value)?.write(to: evidence.appendingPathComponent(frame.id + "-state.png"))
        }
        // Real live preview is on the frame itself, without saving each image.
        // Use installed apps here; the preceding MCP batch already tested source builds.
        alice.build = nil
        bob.build = nil
        undo.disableUndoRegistration()
        doc.workspace.setSimulatorCapture(id: "wf10-current", recipe: alice)
        doc.workspace.setSimulatorCapture(id: "wf10-reference", recipe: bob)
        undo.enableUndoRegistration()
        let streamBefore = doc.workspace.frames
        doc.makeWindowControllers()
        doc.showWindows()
        let controller = try #require(doc.windowControllers.first as? DocumentWindowController)
        let host = controller.canvasHost
        defer { host.stopSimulatorLive() }
        for (id, recipe) in [("wf10-current", alice), ("wf10-reference", bob)] {
            host.setFrameSelection([id])
            try clickLive(host, id: id)
            let first = try await awaitLive(host, id: id)
            let light = try luminance(first)
            try first.data.write(to: evidence.appendingPathComponent(recipe.platform.rawValue + "-live-first.png"))
            if recipe.platform == .iOS {
                _ = try await service.command(["simctl", "ui", recipe.deviceID, "appearance", "light"])
            } else {
                let serial = try #require(try await service.android.serial(for: recipe.deviceID))
                _ = try await service.android.shell(serial, ["cmd", "uimode", "night", "yes"])
            }
            let next = try await awaitLive(host, id: id, changedFrom: light)
            try next.data.write(to: evidence.appendingPathComponent(recipe.platform.rawValue + "-live-changed.png"))
            #expect(doc.workspace.frames == streamBefore)
            await #expect(throws: (any Error).self) {
                try await SimulatorCapture.shared.withCaptureSession { _ in true }
            }
            try await save(doc)
            let savedWhileLive = try WebFramesDocument(
                contentsOf: #require(doc.fileURL), ofType: WebFramesDocument.fileTypeIdentifier)
            #expect(
                savedWhileLive.workspace.frames == streamBefore && savedWhileLive.workspace.annotations == comments
                    && savedWhileLive.workspace.links == links)
            close(savedWhileLive)
            #expect(host.bridge.simulatorLiveImage(id: id == "wf10-current" ? "wf10-reference" : "wf10-current") == nil)
            host.setFrameSelection(["wf10-recovery"])
            await SimulatorLivePreview.shared.waitUntilIdle()
            #expect(SimulatorLivePreview.shared.activeID == nil && host.bridge.simulatorLiveImage(id: id) == nil)
            #expect(doc.workspace.frames == streamBefore)
            #expect(
                try await appearance(recipe, service: service)
                    == (recipe.platform == .iOS ? iosAppearance : androidAppearance))
        }
        host.setFrameSelection(["wf10-current"])
        try clickLive(host, id: "wf10-current")
        _ = try await awaitLive(host, id: "wf10-current")
        host.setAnnotationMode(true)
        await SimulatorLivePreview.shared.waitUntilIdle()
        #expect(host.simulatorLiveFrameID == nil && doc.workspace.frames == streamBefore)
        host.setAnnotationMode(false)
        host.setFrameSelection(["wf10-reference"])
        try clickLive(host, id: "wf10-reference")
        _ = try await awaitLive(host, id: "wf10-reference")
        controller.window?.orderOut(nil)
        await SimulatorLivePreview.shared.waitUntilIdle()
        #expect(host.simulatorLiveFrameID == nil && doc.workspace.frames == streamBefore)
        #expect(try await appearance(bob, service: service) == androidAppearance)
        // A bad ready assertion keeps the saved screenshot and releases the runner.
        var missing = alice
        missing.testState?.readySelector = "WF_State_That_Does_Not_Exist"
        await #expect(throws: (any Error).self) { try await service.capture(missing) }
        #expect(doc.workspace.frames == streamBefore)
        try await save(doc)
        let copy = evidence.appendingPathComponent("Comin State and Live.webframes")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: #require(doc.fileURL), to: copy)
        try JSONSerialization.data(
            withJSONObject: [
                "agentUpdated": result?["updated"] ?? 0, "iosLiveChanged": true, "androidLiveChanged": true,
                "singleSelectedStream": true, "windowHideStoppedStream": true, "deviceThemesRestored": true,
                "liveDidNotChangeDocument": doc.workspace.frames == streamBefore,
                "commentsPreserved": doc.workspace.annotations == comments,
                "linksPreserved": doc.workspace.links == links,
            ], options: [.prettyPrinted, .sortedKeys]
        )
        .write(to: evidence.appendingPathComponent("verification.json"))
        try? FileManager.default.removeItem(at: reply)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WF_STATE_LIVE"] == "1"))
    func cominOfflineSignedInStateUsesSavedDataAndTheme() async throws {
        let service = SimulatorCapture()
        let evidence = URL(
            fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WF_NATIVE_CAPTURE_EVIDENCE"]))
        let originalAppearance = try await appearance(ios, service: service)
        var recipe = ios
        recipe.testState = .init(
            name: "Comin signed-in demo", account: "offline-demo", data: ["room": "!family:demo"], theme: .light,
            launchArguments: ["-CominDemoUI", "-CominDemoOpenRoom", "{{data.room}}"], readySelector: "Семья")
        let family = try await service.capture(recipe)
        try family.data.write(to: evidence.appendingPathComponent("ios-signed-in-family.png"))
        #expect(try await appearance(recipe, service: service) == originalAppearance)
        recipe.testState?.data["room"] = "!mom:demo"
        recipe.testState?.readySelector = "Мама"
        recipe.testState?.theme = .dark
        let mom = try await service.capture(recipe)
        try mom.data.write(to: evidence.appendingPathComponent("ios-signed-in-mom.png"))
        #expect(try luminance(family) - luminance(mom) > 0.1)
        #expect(try await appearance(recipe, service: service) == originalAppearance)
        recipe.testState?.data["room"] = "!family:demo"
        recipe.testState?.readySelector = "Семья"
        recipe.testState?.theme = .light
        let repeated = try await service.capture(recipe)
        #expect(abs(try luminance(repeated) - luminance(family)) < 0.05)
        #expect(try await appearance(recipe, service: service) == originalAppearance)
        // Return the isolated installation to its normal guest launch configuration.
        _ = try await service.command(["simctl", "terminate", ios.deviceID, ios.appBundleID])
        _ = try await service.command(["simctl", "launch", ios.deviceID, ios.appBundleID])
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WF_STATE_LIVE"] == "1"))
    func androidLiveSurvivesAppThemeChange() async throws {
        let service = SimulatorCapture()
        let recipe = state(android, account: "live", tag: "theme", theme: .light)
        let original = try await appearance(recipe, service: service)
        let session = SimulatorRecordingSession(recipe: recipe, service: service, mode: .live)
        do {
            try await session.start()
            let baseline = try luminance(#require(session.snapshot).image)
            let serial = try #require(try await service.android.serial(for: recipe.deviceID))
            _ = try await service.android.shell(serial, ["cmd", "uimode", "night", "yes"])
            var changed = false
            for _ in 0..<200 {
                if let frame = try await session.nextLiveImage(), abs(try luminance(frame) - baseline) > 0.1 {
                    changed = true
                    break
                }
                try await Task.sleep(for: .milliseconds(300))
            }
            #expect(changed)
            // Leaving the app must stop the stream, with no home-screen frame emitted.
            _ = try await service.android.shell(serial, ["input", "keyevent", "KEYCODE_HOME"])
            var rejected = false
            for _ in 0..<100 {
                do { _ = try await session.nextLiveImage() } catch {
                    rejected = true
                    break
                }
                try await Task.sleep(for: .milliseconds(300))
            }
            #expect(rejected)
            await session.cancelAndWait()
            #expect(try await appearance(recipe, service: service) == original)
        } catch {
            await session.cancelAndWait()
            throw error
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WF_STATE_LIVE_SECURE"] == "1"))
    func protectedCominCannotStartLiveAndRunnerIsReleased() async throws {
        let preview = SimulatorLivePreview()
        let service = SimulatorCapture()
        var failure: Error?
        var frames = 0
        _ = preview.start(
            frameID: "protected", recipe: android, service: service, valid: { true },
            image: { if $0 != nil { frames += 1 } }, ended: { failure = $0 })
        await preview.waitUntilIdle()
        #expect(frames == 0 && failure?.localizedDescription.contains("FLAG_SECURE") == true)
        #expect(preview.activeID == nil)
        #expect(try await service.withCaptureSession { _ in true })
    }
}
