import AppKit
import Testing
import WebKit
@testable import Web_Frames

/// A frame's controls (toolbar, link handles, resize grips) must stay above
/// every other frame, and hidden controls must not take clicks.
@MainActor
@Suite("Card controls layering")
struct CardChromeLayeringTests {

    private func card(_ id: String, _ rect: NSRect) -> FrameCardView {
        let container = FrameContainer(webView: WKWebView(), frame: .zero, logicalSize: rect.size)
        let card = FrameCardView(id: id, container: container)
        card.frame = rect
        return card
    }

    @Test func controlsOfACoveredFrameStayAboveTheFrameOnTop() {
        let layer = FrameLayerView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
        let below = card("below", NSRect(x: 100, y: 100, width: 400, height: 500))
        let above = card("above", NSRect(x: 200, y: 300, width: 400, height: 500))
        layer.addSubview(below)
        layer.addSubview(above)   // `above` is drawn over `below`

        let order = layer.subviews
        let topCard = order.lastIndex(where: { $0 is FrameCardView })!
        let belowChrome = order.firstIndex(where: { $0 === below.chromeHost })!
        #expect(belowChrome > topCard)

        // The controls use the card's coordinates and follow it.
        below.setFrameOrigin(NSPoint(x: 150, y: 120))
        #expect(below.chromeHost.convert(NSPoint.zero, to: layer) == NSPoint(x: 150, y: 120))

        // Reordering (Bring to Front) keeps every chrome host on top.
        layer.addSubview(below, positioned: .above, relativeTo: nil)
        let reordered = layer.subviews
        let lastCard = reordered.lastIndex(where: { $0 is FrameCardView })!
        #expect(reordered.indices.filter { reordered[$0] is CardChromeHostView }.allSatisfy { $0 > lastCard })

        // Not hovered or selected: hidden, and clicks pass to the frames.
        #expect(below.chromeHost.isHidden)
        #expect(below.chromeHost.hitTest(NSPoint(x: 300, y: 115)) == nil)

        below.removeFromSuperview()
        #expect(below.chromeHost.superview == nil)
    }
}
