import AppKit
import Testing
@testable import Web_Frames

@Suite("Native simulator capture") @MainActor struct SimulatorCaptureTests {
    private var recipe: SimulatorCaptureRecipe {
        if ProcessInfo.processInfo.environment["WF_CAPTURE_PLATFORM"] == "android" {
            return .init(deviceID: "android-avd:WF_Comin_Capture", deviceName: "WF_Comin_Capture", appBundleID: "com.essazanov.comin", restartApp: true,
                steps: [.init(action: .wait, value: "Забыли пароль?"), .init(action: .tap, value: "Забыли пароль?"), .init(action: .wait, value: "Сброс пароля")], platform: .android)
        }
        return .init(deviceID: "1781B954-FC16-45CB-AD60-58F4224410F3", deviceName: "iPhone 18 Pro Max",
              appBundleID: "app.essazanov.Comin", restartApp: true,
              steps: [.init(action: .wait, value: "Забыли пароль?"), .init(action: .tap, value: "Забыли пароль?"),
                      .init(action: .wait, value: "Сброс пароля")])
    }
    @Test func rejectsInvalidRecipesAndImages() throws {
        var invalid = recipe; invalid.deviceID = "booted; echo injected"
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = recipe; invalid.steps = [.init(action: .tap, value: " ")]
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = recipe; invalid.appBundleID = ""
        #expect(throws: (any Error).self) { try invalid.validate() }
        invalid = recipe; invalid.deeplink = "file:///tmp/app"
        #expect(throws: (any Error).self) { try invalid.validate() }
        #expect(throws: (any Error).self) { try SimulatorCapturedImage(data: Data("fake png".utf8)) }
        #expect(SimulatorCaptureRecipe(jsonValue: recipe.jsonValue) == recipe)
    }

    @Test func androidRecipeValidationAndLegacyIOSCompatibility() throws {
        let legacy = Data("""
        {"deviceID":"1781B954-FC16-45CB-AD60-58F4224410F3","deviceName":"iPhone","appBundleID":"app.essazanov.Comin","restartApp":true,"steps":[]}
        """.utf8)
        #expect(try JSONDecoder().decode(SimulatorCaptureRecipe.self, from: legacy).platform == .iOS)
        var android = SimulatorCaptureRecipe(deviceID: "android-avd:WF_Comin_Capture", deviceName: "Comin", appBundleID: "com.essazanov.comin", platform: .android)
        try android.validate()
        #expect(SimulatorCaptureRecipe(jsonValue: android.jsonValue) == android)
        android.deviceID = "emulator-5554"; try android.validate()
        android.deviceID = "R58RealPhone"
        #expect(throws: (any Error).self) { try android.validate() }
        let secure = "  Window #0 Window{test}:\n    fl=LAYOUT_IN_SCREEN SECURE HARDWARE_ACCELERATED\n    mHasSurface=true\n    isVisible=true\n"
        #expect(AndroidEmulatorCapture.hasSecureVisibleWindow(secure))
        #expect(!AndroidEmulatorCapture.hasSecureVisibleWindow(secure.replacingOccurrences(of: "isVisible=true", with: "isVisible=false")))
        #expect(!AndroidEmulatorCapture.hasSecureVisibleWindow(secure.replacingOccurrences(of: " SECURE", with: "")))
        let oldAndroid = "  Window #0 Window{test}:\n    mAttrs={ty=1 fl=#2000}\n    mHasSurface=true\n    isVisible=true\n"
        #expect(AndroidEmulatorCapture.hasSecureVisibleWindow(oldAndroid))
        android.deviceID = "android-avd:test;whoami"
        #expect(throws: (any Error).self) { try android.validate() }
    }

    @Test func processKeepsBinaryOutputSeparateFromDiagnostics() async throws {
        let service = SimulatorCapture()
        var observed: Data?
        let data = try await service.runCommand(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf PNG; printf warning >&2"], observeOutput: { observed = $0 })
        #expect(data == Data("PNG".utf8))
        #expect(observed == data)
        let literal = "x'; printf INJECTED; ' `echo X` $(echo Y)\nПривет"
        let roundTrip = try await service.runCommand(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf %s " + AndroidEmulatorCapture.shellQuote(literal)])
        #expect(roundTrip == Data(literal.utf8))
    }

    @Test func importedCaptureRetainsBindingAndAgentCannotOverrideRecipe() throws {
        let data = try JSONEncoder().encode(recipe)
        let object = try JSONSerialization.jsonObject(with: data)
        let screenshot = try image(.red)
        let frames = AddFrameSpecApplier.frames(for: ["kind": "image", "images": [["name": "Comin", "dataURL": screenshot.dataURL,
            "natW": screenshot.width, "natH": screenshot.height, "simulatorCapture": object]]], existingFrameCount: 0,
            viewport: .init(scale: 1, panX: 0, panY: 0), allocateNum: { 1 }, generateId: { "comin" })
        let frame = try #require(frames.first)
        #expect(frame.simulatorCapture == recipe)
        let doc = makeTestDocument(); defer { close(doc) }
        doc.undoManager?.disableUndoRegistration(); doc.workspace.createFrame(frame)
        let hash = CommentsMCPInbox.imageHash(screenshot.data)
        func request(_ value: SimulatorCaptureRecipe, deadline: Double = Date().timeIntervalSince1970 + 120) -> CommentsMCPInbox.Request {
            .init(id: UUID().uuidString, deadline: deadline, resolved: false, comments: [],
                  simulatorCapture: .init(frameID: frame.id, beforeHash: hash, recipe: value))
        }
        #expect(try CommentsMCPInbox.validateSimulatorRequest(request(recipe), document: doc, allowed: true) == frame)
        #expect(throws: (any Error).self) { try CommentsMCPInbox.validateSimulatorRequest(request(recipe), document: doc, allowed: false) }
        var other = recipe; other.steps = [.init(action: .type, value: "unauthorized")]
        #expect(throws: (any Error).self) { try CommentsMCPInbox.validateSimulatorRequest(request(other), document: doc, allowed: true) }
        #expect(throws: (any Error).self) { try CommentsMCPInbox.validateSimulatorRequest(request(recipe, deadline: 0), document: doc, allowed: true) }
        #expect(doc.workspace.frames == frames)
    }

    private func image(_ color: NSColor) throws -> SimulatorCapturedImage {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 20,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let rgb = try #require(color.usingColorSpace(.deviceRGB))
        let bytes = try #require(rep.bitmapData)
        for y in 0..<20 { for x in 0..<10 {
            let offset = y * rep.bytesPerRow + x * 4
            bytes[offset] = UInt8(rgb.redComponent * 255); bytes[offset + 1] = UInt8(rgb.greenComponent * 255)
            bytes[offset + 2] = UInt8(rgb.blueComponent * 255); bytes[offset + 3] = 255
        } }
        return try SimulatorCapturedImage(data: #require(rep.representation(using: .png, properties: [:])))
    }
    private func close(_ doc: WebFramesDocument) { doc.updateChangeCount(.changeCleared); doc.close() }
    private func save(_ doc: WebFramesDocument) async throws {
        let url = try #require(doc.fileURL)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            doc.save(to: url, ofType: WebFramesDocument.fileTypeIdentifier, for: .saveOperation) {
                if let error = $0 { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    @Test func recipeAndImageUndoSaveReopenPreserveEvidenceAndRejectStaleCapture() async throws {
        let doc = makeTestDocument(); defer { close(doc) }
        let old = try image(.red), new = try image(.blue)
        let undo = try #require(doc.undoManager)
        undo.groupsByEvent = false; undo.disableUndoRegistration()
        let f = FrameModel(id: "comin", url: "image://comin", label: "Comin", x: 10, y: 20, w: 390, h: 844,
                           num: 1, isImage: true, extras: ["imgUrl": .string(old.dataURL)])
        doc.workspace.createFrame(f)
        doc.workspace.createFrame(.init(id: "other", url: "https://example.com", label: "other", x: 500, y: 0, w: 390, h: 844, num: 2, isImage: false))
        doc.workspace.createLink(.init(id: "link", fromId: "comin", fromSide: .right, toId: "other", toSide: .left))
        doc.workspace.createAnnotation(.init(id: "pin", num: 1, frameId: "comin", xPct: 10, yPct: 20, color: "blue", comment: "Original evidence", resolved: false, edits: [:], extras: ["element": .object(["screenshot": .string(old.dataURL)])]))
        let comments = doc.workspace.annotations, links = doc.workspace.links
        undo.enableUndoRegistration()
        undo.beginUndoGrouping(); doc.workspace.setSimulatorCapture(id: f.id, recipe: recipe); undo.endUndoGrouping()
        undo.undo(); #expect(doc.workspace.frames[0].simulatorCapture == nil)
        undo.redo(); #expect(doc.workspace.frames[0].simulatorCapture == recipe)
        let expected = doc.workspace.frames[0]
        undo.beginUndoGrouping(); try doc.applySimulatorCapture(new, frameID: f.id, expected: expected); undo.endUndoGrouping()
        #expect(doc.workspace.frames[0].extras["imageUpdatedBy"] == .string("Simulator"))
        #expect(doc.workspace.frames[0].x == f.x && doc.workspace.frames[0].w == f.w)
        #expect(doc.workspace.annotations == comments && doc.workspace.links == links)
        undo.disableUndoRegistration()
        #expect(throws: (any Error).self) { try doc.applySimulatorCapture(old, frameID: f.id, expected: expected) }
        undo.enableUndoRegistration()
        for expectedURL in [new.dataURL, old.dataURL, new.dataURL] {
            try await save(doc)
            let reopened = try WebFramesDocument(contentsOf: #require(doc.fileURL), ofType: WebFramesDocument.fileTypeIdentifier)
            #expect(reopened.workspace.frames[0].extras["imgUrl"] == .string(expectedURL))
            #expect(reopened.workspace.frames[0].simulatorCapture == recipe)
            #expect(reopened.workspace.annotations == comments && reopened.workspace.links == links)
            close(reopened)
            if expectedURL == old.dataURL { undo.redo() } else { undo.undo() }
        }
    }

    /// Opt-in live integration: the production service, real Comin, and a copy of its real board.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WF_NATIVE_CAPTURE_LIVE"] == "1"))
    func realCominFlowCaptureUpdateUndoReopenAndFailure() async throws {
        let env = ProcessInfo.processInfo.environment
        let board = try #require(env["WF_NATIVE_CAPTURE_BOARD"])
        let evidence = URL(fileURLWithPath: try #require(env["WF_NATIVE_CAPTURE_EVIDENCE"]))
        let doc = makeTestDocument(); defer { close(doc) }
        try doc.read(from: FileWrapper(url: URL(fileURLWithPath: board)), ofType: WebFramesDocument.fileTypeIdentifier)
        let id = env["WF_NATIVE_CAPTURE_FRAME_ID"] ?? "f17917746709640.40143288687534273"
        let undo = try #require(doc.undoManager); undo.groupsByEvent = false
        undo.disableUndoRegistration(); doc.workspace.setSimulatorCapture(id: id, recipe: recipe); undo.enableUndoRegistration()
        let expected = try #require(doc.workspace.frames.first { $0.id == id })
        let comments = doc.workspace.annotations, links = doc.workspace.links
        let before = doc.workspace.frames
        let cache = env["WF_NATIVE_CAPTURE_CACHE"].map { URL(fileURLWithPath: $0) } ?? evidence.appendingPathComponent("RunnerCache")
        let service = SimulatorCapture(cache: cache)
        let capture = try await service.capture(recipe)
        try capture.data.write(to: evidence.appendingPathComponent("comin-native.png"))
        undo.beginUndoGrouping(); try doc.applySimulatorCapture(capture, frameID: id, expected: expected); undo.endUndoGrouping()
        let updated = try #require(doc.workspace.frames.first { $0.id == id })
        #expect(updated.extras["imgUrl"] != expected.extras["imgUrl"])
        #expect(updated.x == expected.x && updated.y == expected.y && updated.w == expected.w && updated.h == expected.h && updated.num == expected.num && updated.label == expected.label)
        #expect(doc.workspace.annotations == comments && doc.workspace.links == links)
        for (name, target) in [("updated", updated), ("undo", expected), ("redo", updated)] {
            try await save(doc)
            let reopened = try WebFramesDocument(contentsOf: #require(doc.fileURL), ofType: WebFramesDocument.fileTypeIdentifier)
            #expect(reopened.workspace.frames.first { $0.id == id } == target)
            #expect(reopened.workspace.annotations == comments && reopened.workspace.links == links)
            try JSONEncoder().encode(reopened.payload).write(to: evidence.appendingPathComponent("comin-\(name).json"))
            close(reopened)
            if name == "updated" { undo.undo() } else if name == "undo" { undo.redo() }
        }
        var missing = recipe; missing.deviceID = UUID().uuidString
        await #expect(throws: (any Error).self) { try await service.capture(missing) }
        #expect(doc.workspace.frames.first { $0.id == id } == updated)
        #expect(doc.workspace.frames.filter { $0.id != id } == before.filter { $0.id != id })
        // The agent uses Web Frames' own bridge, not a second screenshot service.
        let inbox = CommentsMCPInbox(document: doc, permission: { false }, frameImagesPermission: { false },
                                     simulatorPermission: { true }, captureService: service)
        inbox.start(); defer { inbox.stop() }
        let directory = CommentsMCPInbox.directory(for: try #require(doc.fileURL))
        let currentURL = try #require(doc.workspace.frames.first { $0.id == id }?.extras["imgUrl"])
        guard case .string(let url) = currentURL else { Issue.record("Missing screenshot"); return }
        let request = CommentsMCPInbox.Request(id: UUID().uuidString, deadline: Date().timeIntervalSince1970 + 120,
            resolved: false, comments: [], simulatorCapture: .init(frameID: id,
                beforeHash: CommentsMCPInbox.imageHash(try #require(CommentsMCPInbox.imageBytes(url))), recipe: recipe))
        try JSONEncoder().encode(request).write(to: directory.appendingPathComponent(request.id + ".request.json"), options: .atomic)
        let reply = directory.appendingPathComponent(request.id + ".response.json")
        for _ in 0..<1_200 {
            if FileManager.default.fileExists(atPath: reply.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: reply)) as? [String: Any]
        #expect(result?["ok"] as? Bool == true)
        #expect(result?["frame_id"] as? String == id)
        try Data(contentsOf: reply).write(to: evidence.appendingPathComponent("comin-native-mcp.json"))
        #expect(doc.workspace.annotations == comments && doc.workspace.links == links)
        #expect(throws: (any Error).self) { try CommentsMCPInbox.validateSimulatorRequest(request, document: doc, allowed: false) }
        // Cancellation must release the runner and leave the old image untouched.
        let afterAgent = doc.workspace.frames
        var waiting = recipe; waiting.steps = [.init(action: .wait, value: "WF_MISSING_ELEMENT")]
        var actionsStarted = false
        let cancelled = Task { try await service.capture(waiting) { if $0.contains("screen actions") { actionsStarted = true } } }
        if recipe.platform == .android {
            for _ in 0..<600 { if actionsStarted { break }; try await Task.sleep(for: .milliseconds(100)) }
            try await Task.sleep(for: .seconds(2))
        } else { try await Task.sleep(for: .seconds(5)) }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(doc.workspace.frames == afterAgent)
        // Quick capture exercises the simctl path as well as XCTest.
        let quick = try await service.capture(.init(deviceID: recipe.deviceID, deviceName: recipe.deviceName, platform: recipe.platform))
        #expect(quick.width == capture.width && quick.height == capture.height)
        let boardCopy = evidence.appendingPathComponent("Comin Native Capture.webframes")
        try? FileManager.default.removeItem(at: boardCopy)
        try FileManager.default.copyItem(at: #require(doc.fileURL), to: boardCopy)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WF_NATIVE_CAPTURE_LIVE"] == "1" && ProcessInfo.processInfo.environment["WF_CAPTURE_PLATFORM"] == "android"))
    func androidUnicodeEntryAndNavigationFailure() async throws {
        let evidence = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WF_NATIVE_CAPTURE_EVIDENCE"]))
        let service = SimulatorCapture(cache: evidence.appendingPathComponent("RunnerCache"))
        var typing = recipe
        typing.steps += [.init(action: .tap, value: "E-mail"), .init(action: .type, value: "проверка@example.invalid"),
                         .init(action: .wait, value: "проверка@example.invalid")]
        let image = try await service.capture(typing)
        try image.data.write(to: evidence.appendingPathComponent("comin-unicode.png"))
        var missing = recipe; missing.steps = [.init(action: .wait, value: "WF_ELEMENT_THAT_DOES_NOT_EXIST")]
        do { _ = try await service.capture(missing); Issue.record("Missing element must fail") }
        catch { #expect(error.localizedDescription.contains("Visible element not found")) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WF_ANDROID_SECURE_CHECK"] == "1"))
    func protectedAndroidScreenKeepsOriginalFrame() async throws {
        let doc = makeTestDocument(); defer { close(doc) }
        try doc.read(from: FileWrapper(url: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WF_NATIVE_CAPTURE_BOARD"]))), ofType: WebFramesDocument.fileTypeIdentifier)
        let before = doc.workspace.frames
        let service = SimulatorCapture()
        if ProcessInfo.processInfo.environment["WF_ANDROID_COLD_START_CHECK"] == "1" {
            let devices = try await service.devices(platform: .android)
            #expect(devices.contains { $0.id == "android-avd:WF_Comin_Capture" && !$0.booted })
            try await service.startDevice(id: "android-avd:WF_Comin_Capture", platform: .android)
            #expect(try await service.apps(deviceID: "android-avd:WF_Comin_Capture", platform: .android).contains { $0.id == "com.essazanov.comin" })
        }
        do {
            _ = try await service.capture(.init(deviceID: "android-avd:WF_Comin_Capture", deviceName: "Comin", appBundleID: "com.essazanov.comin", restartApp: true, platform: .android))
            Issue.record("FLAG_SECURE must reject capture")
        } catch { #expect(error.localizedDescription.contains("FLAG_SECURE")) }
        do {
            _ = try await service.capture(.init(deviceID: "android-avd:WF_Comin_Capture", deviceName: "Comin", platform: .android))
            Issue.record("FLAG_SECURE must reject quick capture too")
        } catch { #expect(error.localizedDescription.contains("FLAG_SECURE")) }
        #expect(doc.workspace.frames == before)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WF_NATIVE_CAPTURE_LIVE"] == "1"))
    func realCominNativeRefreshAction() async throws {
        let board = try #require(ProcessInfo.processInfo.environment["WF_NATIVE_CAPTURE_BOARD"])
        let doc = makeTestDocument(); defer { close(doc) }
        try doc.read(from: FileWrapper(url: URL(fileURLWithPath: board)), ofType: WebFramesDocument.fileTypeIdentifier)
        let id = ProcessInfo.processInfo.environment["WF_NATIVE_CAPTURE_FRAME_ID"] ?? "f17917746709640.40143288687534273"
        doc.workspace.setSimulatorCapture(id: id, recipe: recipe)
        doc.makeWindowControllers(); doc.showWindows()
        let controller = try #require(doc.windowControllers.first as? DocumentWindowController)
        let window = try #require(controller.window)
        defer { if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) } }
        let host = controller.canvasHost
        let old = try #require(doc.workspace.frames.first { $0.id == id })
        host.refreshSimulatorCapture(id: id)
        #expect(window.attachedSheet != nil)
        for _ in 0..<1_800 {
            if window.attachedSheet == nil, doc.workspace.frames.first(where: { $0.id == id })?.extras["imgUrl"] != old.extras["imgUrl"] { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(window.attachedSheet == nil)
        let updated = try #require(doc.workspace.frames.first { $0.id == id })
        #expect(updated.extras["imgUrl"] != old.extras["imgUrl"])
        #expect(updated.extras["imageUpdatedBy"] == .string("Simulator"))
        try await save(doc)
        let reopened = try WebFramesDocument(contentsOf: #require(doc.fileURL), ofType: WebFramesDocument.fileTypeIdentifier)
        #expect(reopened.workspace.frames.first { $0.id == id } == updated)
        close(reopened)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WF_NATIVE_CAPTURE_LIVE"] == "1"))
    func captureSettingsRenderAndRestoreRecipe() async throws {
        let panel = SimulatorCapturePanel(recipe: recipe)
        defer { panel.cancelDiscovery() }
        for _ in 0..<200 {
            if (try? panel.recipe()) != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(try panel.recipe() == recipe)
        let alert = NSAlert()
        alert.messageText = "Simulator Capture"
        alert.informativeText = "Save a screen recipe and refresh this frame whenever the app changes."
        alert.accessoryView = panel
        alert.addButton(withTitle: "Capture"); alert.addButton(withTitle: "Save Recipe"); alert.addButton(withTitle: "Cancel")
        let parent = NSWindow(contentRect: .init(x: 0, y: 0, width: 1100, height: 900), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        parent.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: parent) { _ in }
        defer { parent.endSheet(alert.window); parent.close() }
        try await Task.sleep(for: .milliseconds(200))
        let view = try #require(alert.window.contentView)
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        #expect(view.bounds.contains(panel.convert(panel.bounds, to: view)))
        #expect(alert.window.frame.height < 900)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let path = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WF_NATIVE_CAPTURE_EVIDENCE"]))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: path.appendingPathComponent("capture-settings.png"))
    }
}
