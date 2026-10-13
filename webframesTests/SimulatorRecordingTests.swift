import AppKit
import Testing

@testable import Web_Frames

@Suite("Native action recording") @MainActor struct SimulatorRecordingTests {
    private let ios = SimulatorCaptureRecipe(
        deviceID: "1781B954-FC16-45CB-AD60-58F4224410F3", deviceName: "iPhone 18 Pro Max",
        appBundleID: "app.essazanov.Comin", restartApp: true)
    private let android = SimulatorCaptureRecipe(
        deviceID: "android-avd:WF_Comin_Capture", deviceName: "WF_Comin_Capture",
        appBundleID: "com.essazanov.comin", restartApp: true, platform: .android)

    @Test func previewMapsLetterboxingAndDistinguishesTapsAndVerticalSwipes() throws {
        #expect(
            SimulatorRecordingPreview.action(from: .init(x: 0.3, y: 0.4), to: .init(x: 0.31, y: 0.41))
                == .tap(.init(x: 0.31, y: 0.41)))
        #expect(
            SimulatorRecordingPreview.action(from: .init(x: 0.5, y: 0.8), to: .init(x: 0.5, y: 0.2))
                == .swipeUp)
        #expect(
            SimulatorRecordingPreview.action(from: .init(x: 0.5, y: 0.2), to: .init(x: 0.5, y: 0.8))
                == .swipeDown)
        #expect(
            SimulatorRecordingPreview.action(from: .init(x: 0.2, y: 0.5), to: .init(x: 0.8, y: 0.5))
                == nil)
        let rep = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
        rep.bitmapData?.initialize(repeating: 255, count: rep.bytesPerRow * rep.pixelsHigh)
        let preview = SimulatorRecordingPreview(frame: .init(x: 0, y: 0, width: 200, height: 200))
        preview.image = try SimulatorCapturedImage(
            data: #require(rep.representation(using: .png, properties: [:])))
        #expect(preview.imageRect == .init(x: 50, y: 0, width: 100, height: 200))
        #expect(preview.normalized(.init(x: 20, y: 100)) == nil)
        #expect(
            preview.normalized(preview.point(for: .init(x: 0.25, y: 0.75))) == .init(x: 0.25, y: 0.75))
    }
    @Test func invalidInputAndDeviceSelectionNeverStartRecording() async throws {
        #expect(throws: (any Error).self) {
            try SimulatorRecordingAction.tap(.init(x: CGFloat.nan, y: 0)).command(id: UUID().uuidString)
        }
        #expect(throws: (any Error).self) {
            try SimulatorRecordingAction.tap(.init(x: 1.5, y: 0)).command(id: UUID().uuidString)
        }
        #expect(throws: (any Error).self) {
            try SimulatorRecordingAction.type("   ").command(id: UUID().uuidString)
        }
        #expect(throws: (any Error).self) {
            try SimulatorRecordingAction.type(String(repeating: "界", count: 2_000)).command(
                id: UUID().uuidString)
        }
        var missingApp = ios
        missingApp.appBundleID = ""
        let session = SimulatorRecordingSession(recipe: missingApp)
        await #expect(throws: (any Error).self) { try await session.start() }
        #expect(session.snapshot == nil && session.steps.isEmpty)
        await session.cancelAndWait()
    }
    @Test func recorderCannotInterleaveWithCaptureSession() async throws {
        let service = SimulatorCapture()
        let session = SimulatorRecordingSession(recipe: ios, service: service)
        var rejected = false
        try await service.withCaptureSession { _ in
            do { try await session.start() } catch {
                rejected = error.localizedDescription.contains("Another simulator capture")
            }
        }
        #expect(rejected && session.snapshot == nil && session.steps.isEmpty)
        await session.cancelAndWait()
        #expect(try await service.withCaptureSession { _ in true })
    }
    private func awaitReady(_ session: SimulatorRecordingSession, count: Int = 0) async throws {
        for _ in 0..<3_000 {
            if session.phase == .failed {
                throw session.failure ?? SimulatorCapture.failure(session.status)
            }
            if session.phase == .ready && session.steps.count >= count { return }
            if session.phase == .ready, session.steps.count < count,
                !session.status.hasPrefix("Click or swipe"), !session.status.hasSuffix("actions recorded")
            {
                throw SimulatorCapture.failure(session.status)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SimulatorCapture.failure("Recorder test timed out: " + session.status)
    }
    private func click(_ node: SimulatorRecordingNode, recorder: SimulatorRecordingWindowController)
        throws
    {
        try gesture(from: node.center, to: node.center, recorder: recorder)
    }
    private func gesture(from start: CGPoint, to end: CGPoint, recorder: SimulatorRecordingWindowController) throws {
        let preview = recorder.preview
        let window = try #require(recorder.window)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(preview.bounds.width > 0 && preview.bounds.height > 0)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let location = preview.convert(preview.point(for: type == .leftMouseDown ? start : end), to: nil)
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
                    pressure: 1))
            if type == .leftMouseDown {
                preview.mouseDown(with: event)
            } else {
                preview.mouseUp(with: event)
            }
        }
    }
    private func recordButton(_ view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.accessibilityIdentifier() == "capture.recordActions" {
            return button
        }
        return view.subviews.compactMap(recordButton).first
    }
    private func close(_ doc: WebFramesDocument) {
        doc.updateChangeCount(.changeCleared)
        doc.close()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WF_RECORDING_SECURE_CHECK"] == "1"))
    func protectedAndroidRecordingKeepsPreviousRecipe() async throws {
        var original = android
        original.steps = [.init(action: .wait, value: "Забыли пароль?")]
        let panel = SimulatorCapturePanel(recipe: original)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 520, height: 500), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.contentView = panel
        window.makeKeyAndOrderFront(nil)
        defer {
            panel.cancelDiscovery()
            window.close()
        }
        for _ in 0..<300 {
            if (try? panel.recipe()) != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(recordButton(panel)).performClick(nil)
        let recorder = try #require(panel.recordingWindow)
        for _ in 0..<1200 {
            if recorder.session.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(recorder.session.failure?.localizedDescription.contains("FLAG_SECURE") == true)
        #expect(recorder.session.snapshot == nil && recorder.session.steps.isEmpty)
        recorder.close()
        await recorder.session.cancelAndWait()
        #expect(try panel.recipe() == original)
    }
    private func save(_ doc: WebFramesDocument) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            doc.save(to: doc.fileURL!, ofType: WebFramesDocument.fileTypeIdentifier, for: .saveOperation) {
                if let error = $0 { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WF_RECORDING_LIVE"] == "1"))
    func recordCominThroughNativePreviewThenReplayBatchWithMCPUndoReopen() async throws {
        let env = ProcessInfo.processInfo.environment
        let evidence = URL(
            fileURLWithPath: try #require(
                ProcessInfo.processInfo.environment["WF_NATIVE_CAPTURE_EVIDENCE"]))
        var recorded: [SimulatorCaptureRecipe.Platform: SimulatorCaptureRecipe] = [:]
        for base in [ios, android].filter({
            env["WF_RECORDING_PLATFORM"] == nil || env["WF_RECORDING_PLATFORM"] == $0.platform.rawValue
        }) {
            print("WF_RECORD_TEST \(base.platform.rawValue) start")
            let panel = SimulatorCapturePanel(recipe: base)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 500), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.contentView = panel
            window.makeKeyAndOrderFront(nil)
            defer {
                panel.cancelDiscovery()
                window.close()
            }
            for _ in 0..<300 {
                if (try? panel.recipe()) != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(try panel.recipe() == base)
            let record = try #require(recordButton(panel))
            #expect(record.isEnabled)
            record.performClick(nil)
            let recorder = try #require(panel.recordingWindow)
            defer { recorder.close() }
            try await awaitReady(recorder.session)
            try gesture(from: .init(x: 0.5, y: 0.75), to: .init(x: 0.5, y: 0.25), recorder: recorder)
            try await awaitReady(recorder.session, count: 1)
            let forgot = try #require(
                recorder.session.snapshot?.nodes.first {
                    $0.label == "Забыли пароль?" || $0.selector == "Забыли пароль?"
                })
            try click(forgot, recorder: recorder)
            try await awaitReady(recorder.session, count: 2)
            if let snapshot = recorder.session.snapshot {
                try snapshot.image.data.write(
                    to: evidence.appendingPathComponent("\(base.platform.rawValue)-after-tap.png"))
                try JSONEncoder().encode(snapshot.nodes).write(
                    to: evidence.appendingPathComponent("\(base.platform.rawValue)-after-tap-nodes.json"))
            }
            let field = try #require(
                recorder.session.snapshot?.nodes.first { $0.editable && !$0.secure }
                    ?? recorder.session.snapshot?.nodes.first { $0.label == "E-mail" || $0.selector == "E-mail" })
            try click(field, recorder: recorder)
            try await awaitReady(recorder.session, count: 3)
            recorder.textInput.stringValue = "recording@example.invalid"
            recorder.sendTextButton.performClick(nil)
            try await awaitReady(recorder.session, count: 4)
            #expect(recorder.session.steps.map(\.action) == [.swipeUp, .tap, .tap, .type])
            #expect(recorder.session.steps.last?.value == "recording@example.invalid")
            try recorder.session.snapshot?.image.data.write(
                to: evidence.appendingPathComponent("\(base.platform.rawValue)-recorded.png"))
            recorder.useButton.performClick(nil)
            for _ in 0..<600 {
                if panel.recordingWindow == nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let recipe = try panel.recipe()
            #expect(
                recipe.steps.count == 4 && recipe.deviceID == base.deviceID
                    && recipe.platform == base.platform)
            recorded[base.platform] = recipe
            print("WF_RECORD_TEST \(base.platform.rawValue) saved")
            // A second recording runs real actions but Cancel leaves the saved
            // action list intact, and releases the shared runner before replay.
            record.performClick(nil)
            let cancelled = try #require(panel.recordingWindow)
            try await awaitReady(cancelled.session)
            let target = try #require(
                cancelled.session.snapshot?.nodes.first {
                    $0.label == "Забыли пароль?" || $0.selector == "Забыли пароль?"
                })
            try click(target, recorder: cancelled)
            try await awaitReady(cancelled.session, count: 1)
            cancelled.close()
            await cancelled.session.cancelAndWait()
            #expect(try panel.recipe() == recipe)
            print("WF_RECORD_TEST \(base.platform.rawValue) cancel preserved")
        }
        try JSONEncoder().encode(
            Dictionary(uniqueKeysWithValues: recorded.map { ($0.key.rawValue, $0.value) })
        ).write(to: evidence.appendingPathComponent("recorded-recipes.json"))
        let doc = makeTestDocument()
        defer { close(doc) }
        try doc.read(
            from: FileWrapper(url: URL(fileURLWithPath: try #require(env["WF_NATIVE_CAPTURE_BOARD"]))),
            ofType: WebFramesDocument.fileTypeIdentifier)
        let undo = try #require(doc.undoManager)
        undo.groupsByEvent = false
        undo.disableUndoRegistration()
        if let recipe = recorded[.iOS] { doc.workspace.setSimulatorCapture(id: "wf10-current", recipe: recipe) }
        if let recipe = recorded[.android] { doc.workspace.setSimulatorCapture(id: "wf10-reference", recipe: recipe) }
        undo.enableUndoRegistration()
        let before = doc.workspace.frames
        let comments = doc.workspace.annotations
        let links = doc.workspace.links
        #expect(before.count == 3 && comments.count == 3 && links.count == 2)
        let ids = ["wf10-current": SimulatorCaptureRecipe.Platform.iOS, "wf10-reference": .android].filter {
            recorded[$0.value] != nil
        }.map(\.key)
        let frames = before.filter { ids.contains($0.id) }
        let captures = try frames.map { frame -> CommentsMCPInbox.SimulatorRequest in
            guard case .string(let url)? = frame.extras["imgUrl"] else {
                throw SimulatorCapture.failure("Missing image")
            }
            return .init(
                frameID: frame.id,
                beforeHash: CommentsMCPInbox.imageHash(try #require(CommentsMCPInbox.imageBytes(url))),
                recipe: frame.simulatorCapture!)
        }
        let inbox = CommentsMCPInbox(
            document: doc, permission: { false }, frameImagesPermission: { false },
            simulatorPermission: { true })
        inbox.start()
        defer { inbox.stop() }
        let directory = CommentsMCPInbox.directory(for: try #require(doc.fileURL))
        let request = CommentsMCPInbox.Request(
            id: UUID().uuidString, deadline: Date().timeIntervalSince1970 + 900, resolved: false,
            comments: [], simulatorCaptures: captures)
        let reply = directory.appendingPathComponent(request.id + ".response.json")
        try JSONEncoder().encode(request).write(
            to: directory.appendingPathComponent(request.id + ".request.json"), options: .atomic)
        for _ in 0..<9000 {
            if FileManager.default.fileExists(atPath: reply.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let data = try Data(contentsOf: reply)
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try data.write(to: evidence.appendingPathComponent("recorded-mcp.json"))
        #expect(result?["updated"] as? Int == recorded.count)
        let after = doc.workspace.frames
        #expect(
            zip(frames, after.filter { ids.contains($0.id) }).allSatisfy {
                $0.extras["imgUrl"] != $1.extras["imgUrl"]
            })
        #expect(after.first { $0.id == "wf10-recovery" } == before.first { $0.id == "wf10-recovery" })
        for (name, target) in [("updated", after), ("undo", before), ("redo", after)] {
            try await save(doc)
            let reopened = try WebFramesDocument(
                contentsOf: #require(doc.fileURL), ofType: WebFramesDocument.fileTypeIdentifier)
            #expect(
                reopened.workspace.frames == target && reopened.workspace.annotations == comments
                    && reopened.workspace.links == links)
            try JSONEncoder().encode(reopened.payload).write(
                to: evidence.appendingPathComponent("recorded-\(name).json"))
            close(reopened)
            if name == "updated" { undo.undo() } else if name == "undo" { undo.redo() }
        }
        let copy = evidence.appendingPathComponent("Comin Recorded Capture.webframes")
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: #require(doc.fileURL), to: copy)
        try? FileManager.default.removeItem(at: reply)
    }
}
