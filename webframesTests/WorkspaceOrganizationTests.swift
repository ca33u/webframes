import AppKit
import Testing
@testable import Web_Frames

@Suite("Workspace organization") @MainActor struct WorkspaceOrganizationTests {
    func frame(_ id: String, _ num: Int) -> FrameModel {
        FrameModel(id: id, url: "https://example.com/" + id, label: id, x: CGFloat(num * 100), y: 10, w: 640, h: 480, num: num, isImage: false, filePath: nil)
    }
    @Test func reorderPreservesContentAndRoundTrips() throws {
        let store = WorkspaceStore()
        for (i, id) in ["a", "b", "c"].enumerated() { store.createFrame(frame(id, i + 1)) }
        store.createLink(LinkModel(id: "link", fromId: "a", fromSide: .right, toId: "b", toSide: .left))
        let old = store.serialize(); let previousFrames = store.frames; let previousLinks = store.links
        store.reorderFrames(["c", "a", "b"])
        #expect(store.frames.map(\.id) == ["c", "a", "b"])
        #expect(store.frames.first == previousFrames.last)
        #expect(store.links == previousLinks)
        #expect(store.nextFrameNum == old.nextNum)
        let restored = try JSONDecoder().decode(DocumentPayload.self, from: JSONEncoder().encode(store.serialize()))
        let loaded = WorkspaceStore(); loaded.apply(restored)
        #expect(loaded.frames == store.frames)
        let version = store.version
        for invalid in [["a", "a", "b"], ["a", "b"], ["a", "b", "other"], ["c", "a", "b"]] { store.reorderFrames(invalid) }
        #expect(store.version == version)
        #expect(store.frames.map(\.id) == ["c", "a", "b"])
    }
    @Test func reorderHasUndoAndRedo() throws {
        let doc = makeTestDocument()
        let undo = try #require(doc.undoManager); undo.groupsByEvent = false
        undo.disableUndoRegistration()
        doc.workspace.createFrame(frame("a", 1)); doc.workspace.createFrame(frame("b", 2))
        undo.enableUndoRegistration(); undo.beginUndoGrouping()
        doc.workspace.reorderFrames(["b", "a"])
        undo.endUndoGrouping()
        #expect(undo.canUndo)
        undo.undo(); #expect(doc.workspace.frames.map(\.id) == ["a", "b"])
        undo.redo(); #expect(doc.workspace.frames.map(\.id) == ["b", "a"])
    }
    @Test func commentsAreNativeInspector() {
        let controller = DocumentSplitViewController(document: makeTestDocument())
        #expect(controller.splitViewItems.count == 3)
        #expect(controller.splitViewItems.first?.behavior == .sidebar)
        #expect(controller.splitViewItems.last?.behavior == .inspector)
        #expect(controller.splitViewItems.last?.canCollapse == true)
        #expect(controller.splitViewItems.last?.isCollapsed == true)
        #expect(controller.canvasVC.canvasHost.annotationPanel.superview !== controller.canvasVC.canvasHost)
    }
}
