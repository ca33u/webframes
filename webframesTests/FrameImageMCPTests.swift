import AppKit
import Testing
import WebKit
@testable import Web_Frames

@Suite("Frame image MCP") @MainActor struct FrameImageMCPTests {
    private func pixels(_ color: NSColor, jpeg: Bool = false) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 24,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let rgb = try #require(color.usingColorSpace(.deviceRGB))
        let bytes = try #require(bitmap.bitmapData)
        for y in 0..<24 { for x in 0..<12 {
            let offset = y * bitmap.bytesPerRow + x * 3
            bytes[offset] = UInt8(rgb.redComponent * 255)
            bytes[offset + 1] = UInt8(rgb.greenComponent * 255)
            bytes[offset + 2] = UInt8(rgb.blueComponent * 255)
        } }
        return try #require(bitmap.representation(using: jpeg ? .jpeg : .png, properties: [:]))
    }
    private func dataURL(_ data: Data, jpeg: Bool = false) -> String {
        "data:image/\(jpeg ? "jpeg" : "png");base64," + data.base64EncodedString()
    }
    private func frame(_ id: String, _ url: String) -> FrameModel {
        .init(id: id, url: "image://\(id)", label: id, x: 20, y: 40, w: 390, h: 844, num: 1,
              isImage: true, filePath: "/tmp/original.png", extras: ["imgUrl": .string(url), "natW": .number(12), "natH": .number(24)])
    }
    private func request(_ old: Data, _ new: String, frameID: String = "f") -> CommentsMCPInbox.Request {
        .init(id: UUID().uuidString, deadline: Date().timeIntervalSince1970 + 10, resolved: false, comments: [],
              frameImage: .init(frameID: frameID, beforeHash: CommentsMCPInbox.imageHash(old), dataURL: new))
    }
    private func close(_ doc: WebFramesDocument) {
        doc.updateChangeCount(.changeCleared); doc.close()
        // NSDocument can still have a queued autosave check after close. Keep
        // the fixture in the test-only temporary projects directory until exit.
    }

    @Test func replacementPreservesGeometryOtherFramesAndOriginalCommentEvidenceWithUndo() throws {
        let doc = makeTestDocument(); defer { close(doc) }
        let old = try pixels(.red), new = try pixels(.blue)
        #expect(old != new)
        let oldURL = dataURL(old), newURL = dataURL(new)
        let undo = try #require(doc.undoManager)
        undo.groupsByEvent = false; undo.disableUndoRegistration()
        doc.workspace.createFrame(frame("f", oldURL)); doc.workspace.createFrame(frame("other", oldURL))
        doc.workspace.setFrameScreenRecipe(id: "f", flow: "flows/login.yaml", deeplink: "comin://login")
        doc.workspace.createLink(LinkModel(id: "link", fromId: "f", fromSide: .right, toId: "other", toSide: .left))
        doc.workspace.createAnnotation(AnnotationModel(id: "a", num: 1, frameId: "f", xPct: 20, yPct: 30,
            color: "blue", comment: "Fix spacing", resolved: false, edits: [:],
            extras: ["element": .object(["screenshot": .string(oldURL)])]))
        let original = doc.workspace.frames[0], comments = doc.workspace.annotations, links = doc.workspace.links
        undo.enableUndoRegistration(); undo.beginUndoGrouping()
        try CommentsMCPInbox.apply(request(old, newURL), to: doc, allowed: false, imagesAllowed: true)
        undo.endUndoGrouping()
        let updated = doc.workspace.frames[0]
        #expect(updated.id == original.id && updated.x == original.x && updated.y == original.y)
        #expect(updated.w == original.w && updated.h == original.h && updated.label == original.label)
        #expect(updated.extras["imgUrl"] == .string(newURL))
        #expect(updated.extras["natW"] == .number(12) && updated.extras["natH"] == .number(24))
        #expect(updated.flow == original.flow && updated.deeplink == original.deeplink)
        #expect(updated.filePath == nil && updated.extras["imageUpdatedBy"] == .string("MCP agent"))
        #expect(doc.workspace.frames[1].extras["imgUrl"] == .string(oldURL))
        #expect(doc.workspace.annotations == comments && doc.workspace.links == links)
        let version = doc.workspace.version
        try CommentsMCPInbox.apply(request(old, newURL), to: doc, allowed: false, imagesAllowed: true)
        #expect(doc.workspace.version == version)
        // Changes made after the image update must survive image Undo.
        undo.disableUndoRegistration()
        doc.workspace.moveFrame(id: "f", to: CGPoint(x: 100, y: 200))
        doc.workspace.setFrameScreenRecipe(id: "f", flow: "flows/recovery.yaml", deeplink: nil)
        doc.workspace.updateAnnotation(id: "a", comment: "Check the result", color: nil, edits: nil)
        undo.enableUndoRegistration()
        undo.undo()
        #expect(doc.workspace.frames[0].extras["imgUrl"] == .string(oldURL))
        #expect(doc.workspace.frames[0].filePath == original.filePath)
        #expect(doc.workspace.frames[0].flow == "flows/recovery.yaml")
        #expect(doc.workspace.frames[0].deeplink == nil)
        #expect(doc.workspace.frames[0].x == 100 && doc.workspace.annotations[0].comment == "Check the result")
        undo.redo()
        #expect(doc.workspace.frames[0].extras["imgUrl"] == .string(newURL))
        let package = try doc.fileWrapper(ofType: WebFramesDocument.fileTypeIdentifier)
        let (payload, _) = try DocumentPackage.read(package)
        let loaded = WorkspaceStore(); loaded.apply(payload)
        #expect(loaded.frames == doc.workspace.frames && loaded.annotations == doc.workspace.annotations)
    }

    @Test func permissionsExpiredStaleDeletedLiveAndInvalidImagesCannotMutate() throws {
        let doc = makeTestDocument(); defer { close(doc) }
        let old = try pixels(.red), newURL = dataURL(try pixels(.blue))
        doc.workspace.createFrame(frame("f", dataURL(old)))
        let version = doc.workspace.version
        let update = request(old, newURL)
        #expect(throws: (any Error).self) { try CommentsMCPInbox.apply(update, to: doc, allowed: true) }
        let expired = CommentsMCPInbox.Request(id: update.id, deadline: 1, resolved: false, comments: [], frameImage: update.frameImage)
        #expect(throws: (any Error).self) { try CommentsMCPInbox.apply(expired, to: doc, allowed: false, imagesAllowed: true) }
        #expect(throws: (any Error).self) { try CommentsMCPInbox.apply(request(try pixels(.green), newURL), to: doc, allowed: false, imagesAllowed: true) }
        #expect(throws: (any Error).self) { try CommentsMCPInbox.apply(request(old, newURL, frameID: "missing"), to: doc, allowed: false, imagesAllowed: true) }
        #expect(throws: (any Error).self) { try CommentsMCPInbox.apply(request(old, dataURL(Data("not an image".utf8))), to: doc, allowed: false, imagesAllowed: true) }
        #expect(throws: (any Error).self) { try CommentsMCPInbox.apply(request(old, dataURL(try pixels(.blue), jpeg: true)), to: doc, allowed: false, imagesAllowed: true) }
        let mixed = CommentsMCPInbox.Request(id: update.id, deadline: update.deadline, resolved: true,
            comments: [.init(id: "a", comment: "Fix", resolved: false)], frameImage: update.frameImage)
        #expect(throws: (any Error).self) { try CommentsMCPInbox.apply(mixed, to: doc, allowed: true, imagesAllowed: true) }
        #expect(doc.workspace.version == version)
        var live = frame("live", dataURL(old)); live.isImage = false
        doc.workspace.createFrame(live)
        #expect(throws: (any Error).self) { try CommentsMCPInbox.apply(request(old, newURL, frameID: "live"), to: doc, allowed: false, imagesAllowed: true) }
        try CommentsMCPInbox.apply(request(old, dataURL(try pixels(.blue, jpeg: true), jpeg: true)), to: doc, allowed: false, imagesAllowed: true)
        #expect(doc.workspace.frames[0].extras["imgUrl"] != .string(dataURL(old)))
    }

    @Test func savedImageUpdateUndoAndRedoSurviveAutosaveAndReopen() async throws {
        let doc = makeTestDocument(); defer { close(doc) }
        let old = try pixels(.red), oldURL = dataURL(old), newURL = dataURL(try pixels(.blue))
        let undo = try #require(doc.undoManager)
        undo.disableUndoRegistration()
        doc.workspace.createFrame(frame("f", oldURL))
        doc.workspace.createFrame(frame("other", oldURL))
        doc.workspace.setFrameScreenRecipe(id: "f", flow: "appId: app.essazanov.Comin\n---\n- launchApp\n- tapOn: Забыли пароль?", deeplink: "comin://login")
        doc.workspace.createLink(LinkModel(id: "link", fromId: "f", fromSide: .right, toId: "other", toSide: .left))
        doc.workspace.createAnnotation(AnnotationModel(id: "a", num: 1, frameId: "f", xPct: 20, yPct: 30,
            color: "blue", comment: "Original evidence", resolved: false, edits: [:],
            extras: ["element": .object(["screenshot": .string(oldURL)])]))
        undo.enableUndoRegistration()
        let url = try #require(doc.fileURL)
        func save() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                doc.save(to: url, ofType: WebFramesDocument.fileTypeIdentifier, for: .saveOperation) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
        try await save()
        // Match an opened project, so Cmd+S takes the real autosave path.
        try doc.read(from: FileWrapper(url: url), ofType: WebFramesDocument.fileTypeIdentifier)
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        let original = doc.workspace.frames[0], comments = doc.workspace.annotations, links = doc.workspace.links
        try CommentsMCPInbox.apply(request(old, newURL), to: doc, allowed: false, imagesAllowed: true)
        try await save() // The MCP inbox explicitly saves before acknowledging the update.
        try await Task.sleep(for: .milliseconds(200)) // Let AppKit close the event's undo group.
        for isUndo in [true, false] {
            if isUndo { undo.undo() } else { undo.redo() }
            try await Task.sleep(for: .milliseconds(200))
            let expected = isUndo ? oldURL : newURL
            #expect(doc.workspace.frames[0].extras["imgUrl"] == .string(expected))
            #expect(doc.hasUnautosavedChanges)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                doc.autosave(withImplicitCancellability: false) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            let reopened = try WebFramesDocument(contentsOf: url, ofType: WebFramesDocument.fileTypeIdentifier)
            defer { close(reopened) }
            let restored = try #require(reopened.workspace.frames.first)
            #expect(restored.extras["imgUrl"] == .string(expected))
            #expect(restored.id == original.id && restored.x == original.x && restored.y == original.y)
            #expect(restored.w == original.w && restored.h == original.h && restored.label == original.label)
            #expect(restored.flow == original.flow && restored.deeplink == original.deeplink)
            #expect(reopened.workspace.annotations == comments && reopened.workspace.links == links)
            #expect(restored.extras["imageUpdatedBy"] == (isUndo ? nil : .string("MCP agent")))
        }
    }

    @Test func screenRecipeEditingClearingUndoRedoAndReopen() async throws {
        let doc = makeTestDocument(); defer { close(doc) }
        let undo = try #require(doc.undoManager)
        undo.groupsByEvent = false
        undo.disableUndoRegistration()
        doc.workspace.createFrame(frame("f", dataURL(try pixels(.red))))
        var web = frame("web", ""); web.isImage = false
        doc.workspace.createFrame(web)
        let original = doc.workspace.frames[0]
        let version = doc.workspace.version
        doc.workspace.setFrameScreenRecipe(id: "web", flow: "flows/web.yaml", deeplink: nil)
        doc.workspace.setFrameScreenRecipe(id: "missing", flow: "flows/missing.yaml", deeplink: nil)
        doc.workspace.setFrameScreenRecipe(id: "f", flow: " \n", deeplink: "")
        #expect(doc.workspace.version == version)
        undo.enableUndoRegistration()
        undo.beginUndoGrouping()
        doc.workspace.setFrameScreenRecipe(id: "f", flow: "flows/recovery.yaml", deeplink: " comin://recovery ")
        undo.endUndoGrouping()
        let edited = doc.workspace.frames[0]
        #expect(edited.flow == "flows/recovery.yaml" && edited.deeplink == "comin://recovery")
        let editedVersion = doc.workspace.version
        doc.workspace.setFrameScreenRecipe(id: "f", flow: edited.flow, deeplink: edited.deeplink)
        #expect(doc.workspace.version == editedVersion)

        let url = try #require(doc.fileURL)
        func saveAndCheck(_ expected: FrameModel) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                doc.save(to: url, ofType: WebFramesDocument.fileTypeIdentifier, for: .saveOperation) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
            let reopened = try WebFramesDocument(contentsOf: url, ofType: WebFramesDocument.fileTypeIdentifier)
            defer { close(reopened) }
            #expect(reopened.workspace.frames[0] == expected)
        }
        try await saveAndCheck(edited)
        undo.undo(); #expect(doc.workspace.frames[0] == original)
        try await saveAndCheck(original)
        undo.redo(); #expect(doc.workspace.frames[0] == edited)
        try await saveAndCheck(edited)
        undo.beginUndoGrouping()
        doc.workspace.setFrameScreenRecipe(id: "f", flow: nil, deeplink: nil)
        undo.endUndoGrouping()
        #expect(doc.workspace.frames[0] == original)
        try await saveAndCheck(original)
        undo.undo(); #expect(doc.workspace.frames[0] == edited)
        let yaml = "name: recovery\nsteps:\n  - inputText: |+\n      line one\n      line two\n\n"
        undo.beginUndoGrouping()
        doc.workspace.setFrameScreenRecipe(id: "f", flow: yaml, deeplink: nil)
        undo.endUndoGrouping()
        #expect(doc.workspace.frames[0].flow == yaml)
        try await saveAndCheck(doc.workspace.frames[0])
    }

    @Test func imageOnlyInboxSavesAndRevokesIndependentlyFromCommentPermission() async throws {
        let doc = makeTestDocument(); defer { close(doc) }
        let old = try pixels(.red), newURL = dataURL(try pixels(.blue))
        doc.workspace.createFrame(frame("f", dataURL(old)))
        var imagesAllowed = true
        let inbox = CommentsMCPInbox(document: doc, permission: { false }, frameImagesPermission: { imagesAllowed })
        inbox.start()
        let directory = CommentsMCPInbox.directory(for: try #require(doc.fileURL))
        defer { inbox.stop(); try? FileManager.default.removeItem(at: directory) }
        let update = request(old, newURL)
        try JSONEncoder().encode(update).write(to: directory.appendingPathComponent(update.id + ".request.json"), options: .atomic)
        let reply = directory.appendingPathComponent(update.id + ".response.json")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: reply.path) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: reply)) as! [String: Any]
        #expect(result["ok"] as? Bool == true && result["frame_id"] as? String == "f")
        let stored = try FileWrapper(url: try #require(doc.fileURL), options: [])
        let (payload, _) = try DocumentPackage.read(stored)
        let loaded = WorkspaceStore(); loaded.apply(payload)
        #expect(loaded.frames[0].extras["imgUrl"] == .string(newURL))
        imagesAllowed = false; inbox.updateActivation()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(throws: (any Error).self) { try CommentsMCPInbox.apply(request(try pixels(.blue), dataURL(old)), to: doc, allowed: true, imagesAllowed: false) }
    }

    @Test func existingCanvasFrameRepaintsOnUpdateAndUndo() async throws {
        let doc = makeTestDocument(); defer { close(doc) }
        let old = try pixels(.red), oldURL = dataURL(old), newURL = dataURL(try pixels(.blue))
        doc.workspace.createFrame(frame("f", oldURL))
        let host = CanvasHost(document: doc); defer { host.tearDown() }
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 1000)
        let webView = try #require(host.bridge.astraWebView(id: "f"))
        func expectPixels(_ url: String) async throws {
            for _ in 0..<100 {
                let src = try? await webView.evaluateJavaScript("document.querySelector('img')?.complete ? document.querySelector('img').getAttribute('src') : null")
                if src as? String == url { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            Issue.record("Existing image frame did not display the expected pixels")
        }
        try await expectPixels(oldURL)
        let undo = try #require(doc.undoManager)
        undo.removeAllActions(); undo.groupsByEvent = false; undo.beginUndoGrouping()
        try CommentsMCPInbox.apply(request(old, newURL), to: doc, allowed: false, imagesAllowed: true)
        undo.endUndoGrouping()
        #expect(host.bridge.astraWebView(id: "f") === webView)
        try await expectPixels(newURL)
        undo.undo()
        try await expectPixels(oldURL)
    }
}
