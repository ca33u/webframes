import AppKit

// MARK: - Pin model

/// Per-pin state pushed from canvas JS. Mirrors the fields the old DOM
/// `.pin` element tracked via `dataset` / `style` / `className`:
///   - `xPct` / `yPct`    — percent coordinates inside the frame body
///   - `initialScrollX/Y` — scroll offset at pin-drop time; used to
///                          compute the delta for follow-scroll behaviour
struct PinModel: Equatable {
    let id: String
    let num: Int
    let color: String        // "blue" | "red" | "amber" | "green" | "purple"
    let xPct: CGFloat
    let yPct: CGFloat
    let initialScrollX: CGFloat
    let initialScrollY: CGFloat
    /// Area comment size in percent of the frame body; 0 for a point pin.
    /// The pin sits on the area's top-left corner (`xPct`/`yPct`).
    var areaWPct: CGFloat = 0
    var areaHPct: CGFloat = 0

    var hasArea: Bool { areaWPct > 0 && areaHPct > 0 }

    static func parse(_ dict: [String: Any]) -> PinModel? {
        guard let id = dict["id"] as? String else { return nil }
        func cg(_ k: String) -> CGFloat {
            if let n = dict[k] as? CGFloat { return n }
            if let n = dict[k] as? Double  { return CGFloat(n) }
            if let n = dict[k] as? Int     { return CGFloat(n) }
            if let s = dict[k] as? String, let d = Double(s) { return CGFloat(d) }
            return 0
        }
        let num = (dict["num"] as? Int) ?? Int(cg("num"))
        let color = (dict["color"] as? String) ?? "blue"
        return PinModel(
            id: id,
            num: num,
            color: color,
            xPct: cg("xPct"),
            yPct: cg("yPct"),
            initialScrollX: cg("initialScrollX"),
            initialScrollY: cg("initialScrollY"),
            areaWPct: cg("areaWPct"),
            areaHPct: cg("areaHPct")
        )
    }
}

protocol PinOverlayDelegate: AnyObject {
    /// User clicked a pin. Overlay has no annotation context; the delegate
    /// (FrameManager → bridge → canvas) forwards the id so JS can look up
    /// the ann and open the pin editor.
    func pinOverlay(_ overlay: PinOverlayView, didClickPinId id: String)
}

// MARK: - PinOverlayView

/// Per-frame overlay that paints annotation pins as native `PinDotView`s.
/// Sits above the frame's WKWebView inside `FrameContainer` — so clicks on
/// pins are swallowed natively and never reach the web content underneath.
///
/// Hit testing:
/// - Annotation-mode OFF: pin dot hits return the dot (opens editor);
///   empty-space hits return nil so mouse events fall through to WKWebView.
/// - Annotation-mode ON: `FrameContainer.hitTest` returns nil for the whole
///   container, so this overlay never receives events — clicks fall through
///   to the canvas shield and drop a new pin.
final class PinOverlayView: NSView {

    weak var delegate: PinOverlayDelegate?

    private var pins: [PinModel] = []
    private var pinViews: [String: PinDotView] = [:]
    /// Outlines of area comments, drawn below every pin dot.
    private var areaLayers: [String: CAShapeLayer] = [:]
    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0

    /// Top-left origin so `yPct` reads the same way CSS percent-top did on
    /// the DOM `.pin`. Parent (`FrameContainer`) is not flipped — that's
    /// fine, the overlay's own subviews just use the flipped coord space.
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Transparent — pins are self-coloured. Using a layer anyway so
        // `layer?.zPosition` could be tweaked later if we move the overlay
        // out of the container in a future iteration.
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Empty space should pass through to whatever is underneath (the
    /// WKWebView). A hit that resolves to `self` means "not on a pin" —
    /// turn it into a miss so web content keeps interactivity.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    // MARK: - State

    /// Replace the full pin list. Reconciliation is diff-based so existing
    /// pins keep their views (no flicker on color/number updates) and only
    /// removed ids tear down.
    func setPins(_ next: [PinModel]) {
        pins = next
        let nextIds = Set(next.map(\.id))
        for (id, view) in pinViews where !nextIds.contains(id) {
            view.removeFromSuperview()
            pinViews.removeValue(forKey: id)
        }
        for (id, area) in areaLayers where !next.contains(where: { $0.id == id && $0.hasArea }) {
            area.removeFromSuperlayer()
            areaLayers.removeValue(forKey: id)
        }
        for pin in next {
            let view = pinViews[pin.id] ?? makePinView(for: pin.id)
            view.apply(pin)
            if pin.hasArea {
                let area = areaLayers[pin.id] ?? makeAreaLayer(for: pin.id)
                let color = PinDotView.color(for: pin.color)
                area.strokeColor = color.withAlphaComponent(0.9).cgColor
                area.fillColor = color.withAlphaComponent(0.08).cgColor
            }
        }
        layoutPins()
    }

    /// Update the current frame scroll. Pins shift by the delta from their
    /// `initialScroll*` — same formula the old DOM path used, so pins
    /// track the element they were dropped on as the user scrolls the
    /// frame's web content.
    func setScroll(x: CGFloat, y: CGFloat) {
        guard x != scrollX || y != scrollY else { return }
        scrollX = x
        scrollY = y
        layoutPins()
    }

    override func layout() {
        super.layout()
        layoutPins()
    }

    // MARK: - Internals

    private func makePinView(for id: String) -> PinDotView {
        let v = PinDotView()
        v.onClick = { [weak self] id in
            guard let self else { return }
            self.delegate?.pinOverlay(self, didClickPinId: id)
        }
        addSubview(v)
        pinViews[id] = v
        return v
    }

    private func makeAreaLayer(for id: String) -> CAShapeLayer {
        let area = CAShapeLayer()
        area.lineWidth = 1.5
        area.lineDashPattern = [5, 3]
        area.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        // Below the dots: sublayers are ordered after subview layers are
        // inserted, so put areas at the very bottom.
        layer?.insertSublayer(area, at: 0)
        areaLayers[id] = area
        return area
    }

    private func layoutPins() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // Reuse the DOM-era formula verbatim so pins land on the exact same
        // pixels they did before the migration:
        //   deltaXPct = (curScroll - initialScroll) / visualW * 100
        // visual bounds on both sides makes the conversion zoom-agnostic
        // within a single frame (the canvas JS had the same behaviour).
        for pin in pins {
            guard let view = pinViews[pin.id] else { continue }
            let deltaXPct = (scrollX - pin.initialScrollX) / w * 100
            let deltaYPct = (scrollY - pin.initialScrollY) / h * 100
            let cx = (pin.xPct - deltaXPct) / 100 * w
            let cy = (pin.yPct - deltaYPct) / 100 * h
            // 22pt dot centred on (cx, cy) — matches the old CSS
            // `transform: translate(-50%, -50%)`.
            view.frame = NSRect(x: cx - 11, y: cy - 11, width: 22, height: 22)
            if let area = areaLayers[pin.id] {
                let rect = CGRect(x: cx, y: cy, width: pin.areaWPct / 100 * w, height: pin.areaHPct / 100 * h)
                area.frame = bounds
                area.path = CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 3, cornerHeight: 3, transform: nil)
            }
        }
    }
}

// MARK: - PinDotView

/// A single pin — rounded coloured circle, 2pt white stroke, centred
/// monospace-ish digit label. Matches the DOM `.pin` visual language.
final class PinDotView: NSView {

    var onClick: ((String) -> Void)?
    private var id: String = ""
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.borderColor = NSColor.white.cgColor
        layer?.borderWidth = 2
        // Drop shadow — same shape as the old CSS box-shadow on .pin.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 4
        // Shadow needs to escape the view's backing store but the corner
        // rounding is achieved via cornerRadius, not a mask — so
        // masksToBounds stays off and the shadow renders cleanly.
        layer?.masksToBounds = false

        label.alignment = .center
        label.font = .systemFont(ofSize: 9, weight: .bold)
        label.textColor = .white
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false
        label.backgroundColor = .clear
        label.drawsBackground = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityIdentifier("webframes.pinDot")
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ pin: PinModel) {
        id = pin.id
        label.stringValue = "\(pin.num)"
        layer?.backgroundColor = Self.color(for: pin.color).cgColor
        setAccessibilityLabel("Comment \(pin.num)")
    }

    /// Matches the old CSS palette:
    ///   blue   → #38bdf8 (sky-400)
    ///   red    → #ef4444
    ///   amber  → #f59e0b
    ///   green  → #22c55e
    ///   purple → #a855f7
    static func color(for name: String) -> NSColor {
        switch name {
        case "red":    return NSColor(calibratedRed: 239/255, green:  68/255, blue:  68/255, alpha: 1)
        case "amber":  return NSColor(calibratedRed: 245/255, green: 158/255, blue:  11/255, alpha: 1)
        case "green":  return NSColor(calibratedRed:  34/255, green: 197/255, blue:  94/255, alpha: 1)
        case "purple": return NSColor(calibratedRed: 168/255, green:  85/255, blue: 247/255, alpha: 1)
        default:       return NSColor(calibratedRed:  56/255, green: 189/255, blue: 248/255, alpha: 1)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow the full click — no mouseUp forwarding needed because the
        // editor opens on click-down (same feel as the DOM handler, which
        // listened on 'click' but stopped propagation before the page could
        // see it). Quick scale bump for visual feedback.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        layer?.setAffineTransform(CGAffineTransform(scaleX: 1.2, y: 1.2))
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.08)
            self?.layer?.setAffineTransform(.identity)
            CATransaction.commit()
        }
        onClick?(id)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
