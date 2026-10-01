import AppKit

// MARK: - CanvasBackdropView
//
// Native dot-grid renderer. Sits at the bottom of `CanvasHost` (below the
// canvas WKWebView), paints the infinite 28-pt dot grid that used to be
// drawn by a 2D `<canvas id="dc">` in index.html.
//
// Why: the dot grid is by far the cheapest thing to migrate — it has no
// inbound events, no per-frame state, just three numbers (scale, px, py)
// that describe the world-space transform. Moving it out of WKWebView:
//   • removes one thing the canvas WKWebView has to render every pan/zoom,
//   • gives us a place in Swift to stand up the eventual native canvas,
//   • lets frame-layer code (already native) reason about a single coordinate
//     system without bouncing through the page.
//
// Canvas JS still owns pan/zoom state + input in Phase 6a — it sends a
// `canvas-view` envelope on every `applyT()` and this view just observes.
// Phase 6b onward will pull input + links + eventually the whole canvas into
// Swift; `CanvasBackdropView` is the seed for that work.
final class CanvasBackdropView: NSView {

    /// Mirrors the canvas JS globals `scale`, `px`, `py`. Updated via
    /// `setView(scale:px:py:)` on every `canvas-view` envelope.
    private var canvasScale: CGFloat = 1
    private var canvasPX:    CGFloat = 80
    private var canvasPY:    CGFloat = 80

    /// World-space dot spacing in points — matches the `sp = 28 * scale` in
    /// the old JS. 28 is a Figma-ish density that stays readable at both
    /// 50 % and 200 % zoom.
    private static let dotSpacing: CGFloat = 28

    /// Dot radius in points. CSS drew 1-pt radius arcs (`ctx.arc(x,y,1,…)`).
    /// Matching that exactly so pixel-level comparisons stay identical to
    /// pre-migration screenshots.
    private static let dotRadius: CGFloat = 1

    /// Dot tint. Matches the CSS `rgba(255,255,255,0.055)` used pre-migration.
    private static let dotColor = NSColor(white: 1.0, alpha: 0.055).cgColor

    /// Below this effective dot spacing the dots overlap into a solid wash
    /// and drawing them individually is wasteful. Skip rendering — the
    /// background just reads as an empty dark field, which is what the old
    /// JS looked like at extreme zoom-out too (dots merged visually).
    private static let minRenderedSpacing: CGFloat = 4

    // Canvas coord space matches JS: origin top-left, y grows downward.
    // The dot-grid formula `sp = 28 * scale; ox = ((px%sp)+sp)%sp` expects
    // that convention; flipping here saves a y-inversion in `draw(_:)`.
    override var isFlipped: Bool { true }

    override var isOpaque: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Paint an explicit dark base. Relying only on the host's layer can
        // reveal the split view's system background during layout/theme
        // transitions, which is white when macOS itself uses Light mode.
        layer?.backgroundColor = WFDesign.bg.cgColor
        // Dots are a function of bounds × view state, so they redraw on any
        // resize. `inLiveResize` costs are negligible at the quick path
        // below (single fillPath call).
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - State

    /// Called from the bridge whenever canvas JS dispatches `canvas-view`.
    /// Cheap no-op if nothing changed so pan-hold idle repaints are free.
    func setView(scale: CGFloat, px: CGFloat, py: CGFloat) {
        guard scale != canvasScale || px != canvasPX || py != canvasPY else { return }
        let rescaled = scale != canvasScale
        canvasScale = scale
        canvasPX = px
        canvasPY = py
        // The dot grid is periodic: panning only shifts it by the pan offset
        // modulo the spacing. The grid is rendered once into a layer one
        // period larger than the view and moved on pan; it is re-rendered
        // only when the zoom or the view size changes. (Redrawing thousands
        // of dots across the window on every pan tick was a large part of
        // the pan cost.)
        if rescaled { renderedGridKey = nil }
        updateGrid()
    }

    private let gridLayer = CALayer()
    private var renderedGridKey: (spacing: CGFloat, backing: CGFloat)?

    override func layout() {
        super.layout()
        updateGrid()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderedGridKey = nil
        updateGrid()
    }

    private func updateGrid() {
        guard let host = layer else { return }
        if gridLayer.superlayer == nil { host.addSublayer(gridLayer) }
        let sp = Self.dotSpacing * canvasScale
        guard sp >= Self.minRenderedSpacing, bounds.width > 0, bounds.height > 0 else {
            gridLayer.isHidden = true
            return
        }
        gridLayer.isHidden = false
        let backing = window?.backingScaleFactor ?? 2
        // One tile holds one dot; Core Animation repeats it, so a zoom step
        // redraws a few pixels instead of the whole grid.
        let tilePixels = max(1, (sp * backing).rounded())
        let tile = tilePixels / backing
        if renderedGridKey.map({ $0.spacing != tile || $0.backing != backing }) ?? true {
            if let image = Self.tileImage(pixels: Int(tilePixels), backing: backing) {
                gridLayer.backgroundColor = NSColor(patternImage: image).cgColor
            }
            renderedGridKey = (tile, backing)
        }
        // Dots sit at offset + k·spacing in view coordinates (top-left origin);
        // the tile's dot is at its center.
        let ox = floorMod(canvasPX, tile)
        let oyTop = floorMod(canvasPY, tile)
        let oy = host.isGeometryFlipped ? oyTop : floorMod(bounds.height - oyTop, tile)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridLayer.frame = CGRect(x: ox - tile * 1.5, y: oy - tile * 1.5,
                                 width: bounds.width + tile * 3, height: bounds.height + tile * 3)
        CATransaction.commit()
    }

    private static func tileImage(pixels: Int, backing: CGFloat) -> NSImage? {
        let side = CGFloat(pixels) / backing
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        guard let rep else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let r = dotRadius
        NSColor(cgColor: dotColor)?.setFill()
        NSBezierPath(ovalIn: NSRect(x: side / 2 - r, y: side / 2 - r, width: r * 2, height: r * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = WFDesign.bg.cgColor
    }

    // Floor-mod: JS `((a%b)+b)%b` when `b > 0`. Returns a value in [0, b).
    private func floorMod(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let r = a.truncatingRemainder(dividingBy: b)
        return r < 0 ? r + b : r
    }
}
