import AppKit
import Testing
@testable import Web_Frames

@Suite("Canvas pointer routing") @MainActor
struct CanvasPointerRoutingTests {
    private func fixture() throws -> (WebFramesDocument, DocumentWindowController, FrameCardView) {
        let doc = try PostLaunchWorkflowTests().document()
        doc.undoManager?.disableUndoRegistration()
        for (id, x) in [("source", CGFloat(100)), ("target", CGFloat(500))] {
            doc.workspace.createFrame(FrameModel(id: id, url: "about:blank", label: id,
                x: x, y: 130, w: 240, h: 220, num: 1, isImage: false, filePath: nil))
        }
        doc.undoManager?.enableUndoRegistration()
        let controller = DocumentWindowController(document: doc)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let host = controller.canvasHost
        // Frame creation fades in asynchronously. Test visible, selected
        // controls without depending on the window server's animation clock.
        host.bridge.setAllFramesVisible(true)
        host.setFrameSelection(["source"])
        let card = try #require(host.frameLayer.subviews.compactMap { $0 as? FrameCardView }.first { $0.id == "source" })
        try #require(!card.chromeHost.isHidden)
        card.chromeHost.alphaValue = 1
        return (doc, controller, card)
    }

    @MainActor private final class Pointer {
        let controller: DocumentWindowController
        private var target: NSView?
        var targetClass: String { target.map { String(describing: type(of: $0)) } ?? "nil" }
        init(_ controller: DocumentWindowController) { self.controller = controller }

        func send(_ type: NSEvent.EventType, at point: NSPoint) throws {
            let window = try #require(controller.window)
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            // Run the production window monitor's gate before delivery to
            // AppKit's actual hit target. Retain that target across the drag
            // as NSWindow does, without depending on application activation.
            let forwarded = controller.handleCanvasPanDrag(event) != nil
            if target != nil { #expect(forwarded, "Canvas swallowed \(type) from \(targetClass)") }
            guard forwarded else { return }
            switch type {
            case .leftMouseDown:
                let root = try #require(window.contentView)
                target = root.hitTest(root.convert(root.convert(point, from: nil), to: root.superview))
                target?.mouseDown(with: event)
            case .leftMouseDragged: target?.mouseDragged(with: event)
            case .leftMouseUp: target?.mouseUp(with: event); target = nil
            default: break
            }
        }
    }

    @Test(arguments: ["left", "right", "top", "bottom"])
    func linkHandlesKeepTheirDrag(side: String) throws {
        let (doc, controller, card) = try fixture()
        defer { controller.close(); doc.updateChangeCount(.changeCleared); doc.close() }
        let pointer = Pointer(controller)
        let host = controller.canvasHost
        let local: NSPoint
        switch side {
        case "left": local = NSPoint(x: 0, y: card.bounds.midY)
        case "right": local = NSPoint(x: card.bounds.maxX, y: card.bounds.midY)
        case "top": local = NSPoint(x: card.bounds.midX, y: 2)
        default: local = NSPoint(x: card.bounds.midX, y: card.bounds.maxY - 2)
        }
        let start = card.convert(local, to: nil)
        #expect(host.frameCardId(at: host.convert(start, from: nil)) == "source")
        try pointer.send(.leftMouseDown, at: start)
        #expect(pointer.targetClass == "LinkHandleView")
        #expect(!host.isMarqueeSelecting)
        #expect(host.linkDragState?.fromId == "source")
        #expect(host.linkDragState?.fromSide.rawValue == side)
        let target = try #require(host.frameLayer.subviews.compactMap { $0 as? FrameCardView }.first { $0.id == "target" })
        let end = target.convert(NSPoint(x: 10, y: target.bounds.midY), to: nil)
        try pointer.send(.leftMouseDragged, at: end)
        try pointer.send(.leftMouseUp, at: end)
        #expect(host.linkDragState == nil)
        #expect(doc.workspace.links.count == 1)
        #expect(doc.workspace.links.first?.fromId == "source")
        #expect(doc.workspace.links.first?.toId == "target")
    }

    @Test(arguments: ["bottom", "corner"])
    func resizeGripsKeepTheirDrag(mode: String) throws {
        let (doc, controller, card) = try fixture()
        defer { controller.close(); doc.updateChangeCount(.changeCleared); doc.close() }
        let pointer = Pointer(controller)
        let host = controller.canvasHost
        let local = mode == "bottom"
            ? NSPoint(x: card.bounds.midX, y: card.bounds.maxY + 6)
            : NSPoint(x: card.bounds.maxX - 9, y: card.bounds.maxY - 9)
        let start = card.convert(local, to: nil)
        #expect(host.frameCardId(at: host.convert(start, from: nil)) == "source")
        try pointer.send(.leftMouseDown, at: start)
        #expect(!host.isMarqueeSelecting)
        #expect(host.frameResizeState?.id == "source")
        let end = NSPoint(x: start.x + 40, y: start.y - 60)
        try pointer.send(.leftMouseDragged, at: end)
        try pointer.send(.leftMouseUp, at: end)
        #expect(host.frameResizeState == nil)
        #expect(doc.workspace.frame(id: "source")?.h == 280)
        #expect(doc.workspace.frame(id: "source")?.w == (mode == "bottom" ? 240 : 280))
    }

    @Test func emptyChromePaddingStillStartsMarquee() throws {
        let (doc, controller, card) = try fixture()
        defer { controller.close(); doc.updateChangeCount(.changeCleared); doc.close() }
        let pointer = Pointer(controller)
        let host = controller.canvasHost
        let start = card.convert(NSPoint(x: -30, y: card.bounds.midY), to: nil)
        #expect(host.frameCardId(at: host.convert(start, from: nil)) == nil)
        try pointer.send(.leftMouseDown, at: start)
        #expect(host.isMarqueeSelecting)
        try pointer.send(.leftMouseUp, at: start)
        #expect(!host.isMarqueeSelecting)
    }
}
