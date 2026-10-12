import AppKit
import Testing
@testable import Web_Frames

@Suite("Magnetic guides and image batches") @MainActor
struct FrameSnappingTests {
    @Test func queuedHeaderDragUsesEachEventPosition() throws {
        let header = DragCapableView(frame: CGRect(x: 0, y: 0, width: 300, height: 40))
        var positions: [CGPoint] = []
        var ended = false
        header.onIntent = { intent in
            switch intent {
            case let .dragStart(x, y), let .dragMove(x, y): positions.append(CGPoint(x: x, y: y))
            case .dragEnd: ended = true
            default: break
            }
        }
        let start = CGPoint(x: 100, y: 400)
        let end = CGPoint(x: 596, y: 104)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        // Queued events keep their positions even when the cursor is elsewhere.
        header.mouseDown(with: try event(.leftMouseDown, start))
        header.mouseDragged(with: try event(.leftMouseDragged, end))
        header.mouseUp(with: try event(.leftMouseUp, end))
        #expect(positions == [start, end])
        #expect(ended)
    }
    @Test func alignsEdgesAndCentersAndReleasesOutsideRadius() {
        let moving = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = CGRect(x: 200, y: 400, width: 200, height: 200)
        let edge = FrameSnapping.snap(bounds: moving, delta: CGPoint(x: 195, y: 395), targets: [target], scale: 1)
        #expect(edge.delta == CGPoint(x: 200, y: 400))
        #expect(edge.guides.count == 2)
        let center = FrameSnapping.snap(bounds: moving, delta: CGPoint(x: 252, y: 452), targets: [target], scale: 1)
        #expect(center.delta == CGPoint(x: 250, y: 450))
        #expect(center.guides.first?.start.x == 300)
        let free = FrameSnapping.snap(bounds: moving, delta: CGPoint(x: 180, y: 380), targets: [target], scale: 1)
        #expect(free.delta == CGPoint(x: 180, y: 380))
        #expect(free.guides.isEmpty)
        let opposite = FrameSnapping.snap(bounds: moving, delta: CGPoint(x: 95, y: 295), targets: [target], scale: 1)
        #expect(opposite.delta == CGPoint(x: 100, y: 300))
    }

    @Test func thresholdIsConstantOnScreenAndTieBreakIsStable() {
        let moving = CGRect(x: 0, y: 0, width: 100, height: 100)
        let target = CGRect(x: 300, y: 300, width: 100, height: 100)
        for scale: CGFloat in [0.5, 1, 2] {
            let near = FrameSnapping.snap(bounds: moving, delta: CGPoint(x: 300 - 5 / scale, y: 300 - 5 / scale), targets: [target], scale: scale)
            #expect(near.delta == CGPoint(x: 300, y: 300))
            let far = FrameSnapping.snap(bounds: moving, delta: CGPoint(x: 300 - 7 / scale, y: 300 - 7 / scale), targets: [target], scale: scale)
            #expect(far.guides.isEmpty)
        }
        let targets = [CGRect(x: 195, y: 1000, width: 100, height: 100), CGRect(x: 205, y: 1000, width: 100, height: 100)]
        let a = FrameSnapping.snap(bounds: moving, delta: CGPoint(x: 200, y: 0), targets: targets, scale: 1)
        let b = FrameSnapping.snap(bounds: moving, delta: CGPoint(x: 200, y: 0), targets: targets.reversed(), scale: 1)
        #expect(a.delta == b.delta)
        #expect(a.delta.x == 195)
    }

    func frame(_ id: String, x: CGFloat = 0, y: CGFloat = 0, w: CGFloat = 100, h: CGFloat = 100) -> FrameModel {
        FrameModel(id: id, url: "image://test", label: id, x: x, y: y, w: w, h: h, num: 1, isImage: true, filePath: nil)
    }

    @Test func snappingIsTransientGroupMoveIsOneUndoAndClickDoesNotJump() throws {
        let doc = try PostLaunchWorkflowTests().document()
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        let undo = try #require(doc.undoManager)
        undo.groupsByEvent = false; undo.disableUndoRegistration()
        doc.workspace.createFrame(frame("a")); doc.workspace.createFrame(frame("b", x: 150))
        doc.workspace.createFrame(frame("target", x: 500, y: 300, w: 250))
        undo.enableUndoRegistration()
        let host = CanvasHost(document: doc)
        host.setFrameSelection(["a", "b"])
        host.beginFrameDrag(id: "a", clientX: 0, clientY: 0)
        host.updateFrameDrag(clientX: 0, clientY: 0)
        host.endFrameDrag()
        #expect(!undo.canUndo)
        host.beginFrameDrag(id: "a", clientX: 0, clientY: 0)
        host.updateFrameDrag(clientX: 496, clientY: -296)
        #expect(doc.workspace.frame(id: "a")?.x == 0)
        #expect(host.frameSnapGuides.count == 2)
        undo.beginUndoGrouping(); host.endFrameDrag(); undo.endUndoGrouping()
        #expect(host.frameSnapGuides.isEmpty)
        #expect(doc.workspace.frame(id: "a")?.x == 500)
        #expect(doc.workspace.frame(id: "b")?.x == 650)
        #expect(doc.workspace.frame(id: "b")?.y == 300)
        undo.undo()
        #expect(doc.workspace.frame(id: "a")?.x == 0)
        #expect(doc.workspace.frame(id: "b")?.x == 150)
        undo.redo()
        #expect(doc.workspace.frame(id: "a")?.x == 500)
        #expect(doc.workspace.frame(id: "target")?.y == 300)
    }

    @Test func explicitBypassMovesFreelyAndOverlayDoesNotInterceptInput() throws {
        let doc = try PostLaunchWorkflowTests().document()
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        doc.workspace.createFrame(frame("a")); doc.workspace.createFrame(frame("b", x: 500, y: 300))
        let host = CanvasHost(document: doc); host.setFrameSelection(["a"])
        host.beginFrameDrag(id: "a", clientX: 0, clientY: 0)
        host.updateFrameDrag(clientX: 496, clientY: -296, snap: false)
        host.endFrameDrag()
        #expect(doc.workspace.frame(id: "a")?.x == 496)
        #expect(doc.workspace.frame(id: "a")?.y == 296)
        #expect(host.frameSnapGuides.isEmpty)
        #expect(host.frameSnapGuideView.hitTest(.zero) == nil)
    }

    @Test func batchesKeepMixedSizeCardsApartAndPreserveInputOrder() {
        var frames: [FrameModel] = []
        for i in 0..<7 {
            frames.append(frame(String(i), w: CGFloat(200 + 17 * i), h: CGFloat(300 + 23 * i)))
        }
        let positions = ImageBatchLayout.positions(for: frames, centeredAt: CGPoint(x: -500, y: 700), availableWidth: 1200)
        var rects: [CGRect] = []
        for (f, p) in zip(frames, positions) {
            rects.append(CGRect(origin: p, size: CardGeometry.cardSize(width: f.w, height: f.h)))
        }
        #expect(positions.count == frames.count)
        #expect(Set(positions.map(\.y)).count == 3)
        #expect(positions[0].x < positions[1].x && positions[1].x < positions[2].x)
        for i in rects.indices { for j in rects.indices where i < j { #expect(!rects[i].intersects(rects[j])) } }
        let box = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        #expect(abs(box.midX + 500) <= 0.5 && abs(box.midY - 700) <= 0.5)
        let narrow = ImageBatchLayout.positions(for: frames, centeredAt: .zero, availableWidth: 100)
        #expect(Set(narrow.map(\.x)).count == 1)
        #expect(Set(narrow.map(\.y)).count == 7)
    }

    @Test func importedBatchAvoidsExistingCardsAndEmptyInputIsSafe() {
        let frames = [frame("a", w: 300, h: 500), frame("b", w: 500, h: 200)]
        let existing = frame("old", x: -800, y: -600, w: 1600, h: 1200)
        let positions = ImageBatchLayout.positions(for: frames, centeredAt: .zero, availableWidth: 1200, avoiding: [existing])
        let obstacle = CGRect(x: existing.x - 47, y: existing.y - 47, width: existing.w + 96, height: existing.h + 129)
        for (f, p) in zip(frames, positions) {
            #expect(!CGRect(origin: p, size: CardGeometry.cardSize(width: f.w, height: f.h)).intersects(obstacle))
        }
        #expect(ImageBatchLayout.positions(for: [], centeredAt: .zero, availableWidth: 1200).isEmpty)
    }

    @Test func modalBatchUsesSameLayoutAndUndoRemovesEntireImport() throws {
        let doc = try PostLaunchWorkflowTests().document()
        defer { doc.updateChangeCount(.changeCleared); doc.close() }
        let undo = try #require(doc.undoManager); undo.groupsByEvent = false
        let host = CanvasHost(document: doc); host.frame = CGRect(x: 0, y: 0, width: 1500, height: 1000)
        let modal = AddFrameModal(discovery: LocalServerDiscovery())
        host.addFrameModal(modal, didConfirmSpec: ["kind": "image", "label": "Batch", "images": (0..<9).map { ["name": "\($0).png", "dataURL": "data:image/png;base64,AA==", "natW": 390, "natH": 844] as [String: Any] }])
        #expect(doc.workspace.frames.count == 9)
        #expect(Set(doc.workspace.frames.map(\.y)).count == 3)
        #expect(doc.workspace.frames.allSatisfy { $0.label == "Batch" })
        #expect(host.selectedFrameIDs.count == 9)
        undo.undo(); #expect(doc.workspace.frames.isEmpty)
        undo.redo(); #expect(doc.workspace.frames.count == 9)
    }
}
