import AppKit

/// Passive overlay above the cards. It never takes mouse or keyboard focus.
final class FrameSnapGuideView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var lines: [FrameSnapping.Guide] = []

    func show(_ guides: [FrameSnapping.Guide], viewport: ViewportModel) {
        lines = guides.map {
            FrameSnapping.Guide(
                start: CGPoint(x: $0.start.x * viewport.scale + viewport.panX, y: $0.start.y * viewport.scale + viewport.panY),
                end: CGPoint(x: $0.end.x * viewport.scale + viewport.panX, y: $0.end.y * viewport.scale + viewport.panY))
        }
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemPink.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        for line in lines { path.move(to: line.start); path.line(to: line.end) }
        path.stroke()
    }
}
