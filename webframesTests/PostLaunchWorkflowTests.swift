import AppKit
import Testing
@testable import Web_Frames

@Suite("Post-launch workflows") @MainActor struct PostLaunchWorkflowTests {
    func document() throws -> WebFramesDocument {
        let doc = WebFramesDocument()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("webframes-workflow-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        doc.fileURL = directory.appendingPathComponent(UUID().uuidString + ".webframes")
        let data = try JSONEncoder().encode(DocumentPayload.empty)
        try data.write(to: doc.fileURL!)
        // Written behind NSDocument's back: record the on-disk date, or the
        // first change's autosave check reports an external edit in a modal
        // alert that blocks the whole test run.
        doc.fileModificationDate = try FileManager.default.attributesOfItem(atPath: doc.fileURL!.path)[.modificationDate] as? Date
        try doc.read(from: data, ofType: WebFramesDocument.fileTypeIdentifier)
        return doc
    }
    func frame(_ id: String, x: CGFloat, y: CGFloat = 0, w: CGFloat = 100, h: CGFloat = 100) -> FrameModel {
        FrameModel(id: id, url: "https://example.com", label: id, x: x, y: y, w: w, h: h, num: 1, isImage: false, filePath: nil)
    }
    func annotation(_ id: String) -> AnnotationModel {
        AnnotationModel(id: id, num: 1, frameId: "f", xPct: 0.5, yPct: 0.5, color: "orange", comment: "Fix spacing", resolved: false, edits: [:], frameUrl: nil, frameLabel: nil)
    }
    func request(_ ids: [String], resolved: Bool = true, now: Date = Date()) -> CommentsMCPInbox.Request {
        .init(id: UUID().uuidString, deadline: now.timeIntervalSince1970 + 10, resolved: resolved,
              comments: ids.map { .init(id: $0, comment: "Fix spacing", resolved: false) })
    }
    @Test func alignmentUsesFrameBoundsAndPreservesOtherAxis() {
        let frames = [frame("a", x: -100, y: 30, w: 50), frame("b", x: 300, y: -20, w: 200)]
        let left = FrameArrangement.left.positions(for: frames)
        #expect(left["b"] == CGPoint(x: -100, y: -20))
        let right = FrameArrangement.right.positions(for: frames)
        #expect(right["a"] == CGPoint(x: 450, y: 30))
        let center = FrameArrangement.horizontalCenter.positions(for: frames)
        #expect(center["a"]!.x + 25 == center["b"]!.x + 100)
        let bottom = FrameArrangement.bottom.positions(for: frames)
        #expect(bottom["a"]!.y == bottom["b"]!.y)
    }
    @Test func equalGapsPreserveEndpointsAndHandleDifferentSizes() {
        let frames = [frame("a", x: -100, w: 50), frame("b", x: 0, w: 80), frame("c", x: 400, w: 120)]
        let positions = FrameArrangement.horizontalSpacing.positions(for: frames)
        #expect(positions["a"]!.x == -100)
        #expect(positions["c"]!.x == 400)
        #expect(positions["b"]!.x - (-100 + 50) == 400 - (positions["b"]!.x + 80))
        #expect(FrameArrangement.horizontalSpacing.positions(for: Array(frames.prefix(2))).isEmpty)
    }
    @Test func selectionIsUnboundedDeduplicatedAndToggleable() throws {
        let doc = try document(); defer { doc.updateChangeCount(.changeCleared); doc.close() }
        for i in 0..<5 { doc.workspace.createFrame(frame("f\(i)", x: CGFloat(i*200))) }
        let host = CanvasHost(document: doc)
        host.setFrameSelection(["f0","f1","f2","f3","f4","f2","missing"])
        #expect(host.selectedFrameIDs.count == 5)
        host.selectFrame("f2", additive: true)
        #expect(!host.selectedFrameIDs.contains("f2"))
        host.selectFrame("f1", additive: false)
        #expect(host.selectedFrameIDs.count == 4) // preserved for group drag
    }
    @Test func groupDragCommitsAsOneUndoAndPreservesOffsets() throws {
        let doc = try document(); defer { doc.updateChangeCount(.changeCleared); doc.close() }
        let undo = try #require(doc.undoManager); undo.groupsByEvent = false
        undo.disableUndoRegistration()
        for i in 0..<3 { doc.workspace.createFrame(frame("f\(i)", x: CGFloat(i*200))) }
        undo.enableUndoRegistration()
        let host = CanvasHost(document: doc)
        host.setFrameSelection(["f0","f1","f2"])
        host.beginFrameDrag(id: "f0", clientX: 0, clientY: 0)
        host.updateFrameDrag(clientX: 40, clientY: -20)
        host.endFrameDrag()
        #expect(doc.workspace.frames.map(\.x) == [40,240,440])
        #expect(doc.workspace.frames.map(\.y) == [20,20,20])
        undo.undo(); #expect(doc.workspace.frames.map(\.x) == [0,200,400])
        undo.redo(); #expect(doc.workspace.frames.map(\.x) == [40,240,440])
    }
    @Test func mcpDeniedExpiredAndStaleRequestsAreAtomic() throws {
        let doc = try document(); defer { doc.updateChangeCount(.changeCleared); doc.close() }; doc.workspace.createFrame(frame("f", x: 0)); doc.workspace.createAnnotation(annotation("a"))
        #expect(throws: (any Error).self) { try CommentsMCPInbox.apply(request(["a"]), to: doc, allowed: false) }
        #expect(throws: (any Error).self) { try CommentsMCPInbox.apply(request(["a"], now: Date(timeIntervalSinceNow: -60)), to: doc, allowed: true) }
        #expect(throws: (any Error).self) { try CommentsMCPInbox.apply(request(["a","missing"]), to: doc, allowed: true) }
        doc.workspace.updateAnnotation(id: "a", comment: "New instructions", color: nil, edits: nil)
        #expect(throws: (any Error).self) { try CommentsMCPInbox.apply(request(["a"]), to: doc, allowed: true) }
        #expect(doc.workspace.annotations[0].resolved == false)
    }
    @Test func marqueeAndGroupDeletePreserveOtherFramesAndUndo() throws {
        let doc = try document(); defer { doc.updateChangeCount(.changeCleared); doc.close() }; let undo = try #require(doc.undoManager)
        undo.groupsByEvent = false; undo.disableUndoRegistration()
        for i in 0..<3 { doc.workspace.createFrame(frame("f\(i)", x: CGFloat(i*200), y: 100)) }
        undo.enableUndoRegistration()
        let host = CanvasHost(document: doc)
        host.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        host.beginMarquee(at: CGPoint(x: 0, y: 720), additive: false)
        host.updateMarquee(at: CGPoint(x: 320, y: 580))
        host.endMarquee()
        #expect(host.selectedFrameIDs == ["f0", "f1"])
        #expect(host.deleteSelectedFrame())
        #expect(doc.workspace.frames.map(\.id) == ["f2"])
        undo.undo()
        #expect(Set(doc.workspace.frames.map(\.id)) == Set(["f0", "f1", "f2"]))
        undo.redo(); #expect(doc.workspace.frames.map(\.id) == ["f2"])
    }
    @Test func mcpResolvesBatchWithAuditUndoRedoAndRoundTrip() throws {
        let doc = try document(); defer { doc.updateChangeCount(.changeCleared); doc.close() }; let undo = try #require(doc.undoManager)
        undo.groupsByEvent = false; undo.disableUndoRegistration()
        doc.workspace.createFrame(frame("f", x: 0))
        doc.workspace.createAnnotation(annotation("a")); doc.workspace.createAnnotation(annotation("b"))
        undo.enableUndoRegistration(); undo.beginUndoGrouping()
        try CommentsMCPInbox.apply(request(["a","b"]), to: doc, allowed: true)
        undo.endUndoGrouping()
        #expect(doc.workspace.annotations.allSatisfy { $0.resolved })
        #expect(doc.workspace.annotations[0].extras["resolvedBy"] == .string("MCP agent"))
        let payload = try JSONDecoder().decode(DocumentPayload.self, from: JSONEncoder().encode(doc.workspace.serialize()))
        let loaded = WorkspaceStore(); loaded.apply(payload)
        #expect(loaded.annotations == doc.workspace.annotations)
        undo.undo(); #expect(doc.workspace.annotations.allSatisfy { !$0.resolved })
        #expect(doc.workspace.annotations[0].extras["resolvedBy"] == nil)
        undo.redo(); #expect(doc.workspace.annotations.allSatisfy { $0.resolved })
        let version = doc.workspace.version
        try CommentsMCPInbox.apply(request(["a","b"]), to: doc, allowed: true)
        #expect(doc.workspace.version == version) // retries do not duplicate history or undo
    }
    @Test func inboxSavesLiveDocumentAndHonorsRevocation() async throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        let file = temp.appendingPathComponent("test.webframes")
        let doc = try document(); defer { doc.updateChangeCount(.changeCleared); doc.close() }; doc.fileURL = file
        doc.workspace.createFrame(frame("f", x: 0)); doc.workspace.createAnnotation(annotation("a"))
        try JSONEncoder().encode(doc.workspace.serialize()).write(to: file)
        // The file was written behind NSDocument's back; record its date or
        // the inbox's save sees an external edit and blocks on a modal alert.
        doc.fileModificationDate = try fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        var permitted = true
        let inbox = CommentsMCPInbox(document: doc, permission: { permitted })
        inbox.start()
        let directory = CommentsMCPInbox.directory(for: file)
        defer { inbox.stop(); doc.updateChangeCount(.changeCleared); doc.close(); try? fm.removeItem(at: directory); try? fm.removeItem(at: temp) }
        func send(_ r: CommentsMCPInbox.Request) async throws -> [String: Any] {
            try JSONEncoder().encode(r).write(to: directory.appendingPathComponent(r.id + ".request.json"), options: .atomic)
            let reply = directory.appendingPathComponent(r.id + ".response.json")
            for _ in 0..<80 {
                if let data = try? Data(contentsOf: reply) { return try JSONSerialization.jsonObject(with: data) as! [String: Any] }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw ConnectionSettingsError.message("No inbox response")
        }
        let result = try await send(request(["a"]))
        #expect(result["ok"] as? Bool == true)
        // The inbox saved through NSDocument, which writes the package format.
        let stored = try JSONDecoder().decode(DocumentPayload.self, from: Data(contentsOf: file.appendingPathComponent(DocumentPackage.documentName)))
        let loaded = WorkspaceStore(); loaded.apply(stored)
        #expect(loaded.annotations.first?.resolved == true)
        // Turning the opt-in off removes the request folder, so the MCP server
        // answers at once that the setting is off; nothing else is applied.
        permitted = false
        inbox.updateActivation()
        #expect(!fm.fileExists(atPath: directory.path))
        #expect(doc.workspace.annotations.first?.resolved == true)
        permitted = true
        inbox.updateActivation()
        #expect(fm.fileExists(atPath: directory.path))
    }

}

@Suite("Arrange shortcuts") struct ArrangeShortcutTests {
    @Test func figmaShortcutsAreUniqueAndDistributeNeedsThree() {
        let combos = FrameArrangement.allCases.map { $0.shortcutLabel }
        #expect(Set(combos).count == combos.count)
        #expect(FrameArrangement.left.shortcutLabel == "⌥A" && FrameArrangement.horizontalSpacing.shortcutLabel == "⌃⌥H")
        #expect(FrameArrangement.allCases.filter { $0.minimumSelection == 3 } == [.horizontalSpacing, .verticalSpacing])
    }
}

@Suite("Layer order") struct LayerOrderTests {
    let ids = ["a", "b", "c", "d", "e"]   // front → back

    @Test func frontAndBackKeepRelativeOrder() {
        #expect(FrameStacking.bringToFront.reordered(ids, selected: ["c", "e"]) == ["c", "e", "a", "b", "d"])
        #expect(FrameStacking.sendToBack.reordered(ids, selected: ["a", "c"]) == ["b", "d", "e", "a", "c"])
    }

    @Test func stepwiseMovesJumpOneUnselectedLayer() {
        #expect(FrameStacking.bringForward.reordered(ids, selected: ["c"]) == ["a", "c", "b", "d", "e"])
        #expect(FrameStacking.sendBackward.reordered(ids, selected: ["c"]) == ["a", "b", "d", "c", "e"])
        #expect(FrameStacking.bringForward.reordered(ids, selected: ["a", "b"]) == ids)   // already in front
        #expect(FrameStacking.bringForward.reordered(ids, selected: ["b", "d"]) == ["b", "a", "d", "c", "e"])
    }

    @Test func figmaShortcuts() {
        #expect(FrameStacking.bringForward.keyEquivalent == "]" && FrameStacking.bringForward.keyModifiers == [.command])
        #expect(FrameStacking.sendToBack.keyEquivalent == "[" && FrameStacking.sendToBack.keyModifiers == [.command, .option])
    }
}
