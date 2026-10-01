import CoreGraphics

/// One source for frame-card geometry. A card's visual rect is
/// `(f.w + chromeWidth, f.h + chromeHeight)` world units scaled by the zoom;
/// inside it the header and border keep a fixed size in screen points
/// (FrameCardView lays them out unscaled), so in world units they shrink or
/// grow with 1/scale. There is no separate mobile header.
enum CardGeometry {
    static let border: CGFloat = 1
    static let header: CGFloat = 34
    /// World-unit padding added to the logical frame size for the card rect.
    static let chromeWidth: CGFloat = 2
    static let chromeHeight: CGFloat = 35
    /// Frames at or below this width get the mobile toolbar state.
    static let mobileBreakpoint: CGFloat = 520

    static func cardSize(width: CGFloat, height: CGFloat) -> CGSize {
        CGSize(width: width + chromeWidth, height: height + chromeHeight)
    }

    /// The web content area of a frame card, in world coordinates.
    static func bodyRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, scale: CGFloat) -> CGRect {
        let s = max(scale, 0.0001)
        let card = cardSize(width: width, height: height)
        return CGRect(x: x + border / s,
                      y: y + header / s,
                      width: card.width - 2 * border / s,
                      height: card.height - (header + border) / s)
    }
}
