import AppKit

/// Native dock — replaces the HTML `.dock` that used to live in index.html.
///
/// Why native: the HTML dock painted into the canvas WKWebView, which sits
/// BELOW the per-frame WKWebViews in z-order. Every time a frame overlapped
/// the dock we had to push a "chrome hole" from JS → native so the frame
/// mask punched out the dock region. That round-trip was fragile (coord
/// systems, border-radius, y-flip, timing on show/hide of tooltips and
/// modals). A native view on top of the frame layer removes the entire
/// class of bug: the dock just paints, frames are naturally occluded where
/// they overlap.
///
/// Chrome: macOS 26 (Tahoe) Liquid Glass. Four `NSGlassEffectView` pills
/// inside an `NSGlassEffectContainerView`. The container guarantees
/// consistent ambient sampling and fluid merging animations when pills
/// move (e.g., if we ever animate pill dismissal). Matches the toolbar
/// pattern Apple ships in Finder/Mail/Safari on Tahoe — groups of
/// related actions read as distinct glass chips.
///
/// The dock is purely a view — it does not own state. Clicks emit `Action`
/// values through `DockViewDelegate`; canvas JS still owns the app logic
/// (zoom, pan, annotations) and pushes state back via setters on this view.
protocol DockViewDelegate: AnyObject {
    func dock(_ dock: DockView, didPerform action: DockView.Action)
}

final class DockView: NSView {

    /// String raw values match the `action` field in the `dock-action`
    /// envelope sent on the canvas `wf-native` channel. Keep in sync with
    /// the handler in bridge.js.
    enum Action: String {
        case addFrame         = "add-frame"
        case refreshAll       = "refresh-all"
        case togglePan        = "toggle-pan"
        case selectCursor     = "select-cursor"
        case selectPan        = "select-pan"
        case zoomOut          = "zoom-out"
        case zoomIn           = "zoom-in"
        case zoomFit          = "zoom-fit"
        case toggleAnnotation = "toggle-annotation"
        case toggleNotes      = "toggle-notes"
        // `toggleSidebar` used to live here and route the dock's sidebar
        // button through `CanvasHost.toggleFramesSidebar()` →
        // `NSSplitViewController.toggleSidebar(_:)`. Egor asked on
        // 2026-04-21 to remove the dock entry-point entirely — the
        // toolbar's `.toggleSidebar` item and ⌘⌥S still work through
        // the responder chain, so the dock button was redundant chrome.
    }

    weak var delegate: DockViewDelegate?

    // Buttons are exposed as ivars so state setters can mutate symbol/tooltip/active.
    //
    // `sidebarBtn` used to live here (sidebar.left glyph, ⌘⌥S) and sat as the
    // leading cell of the nav pill. Removed on 2026-04-21 — the sidebar is
    // now toggled exclusively from the window toolbar's `.toggleSidebar`
    // item and the system ⌘⌥S keyboard shortcut, both of which flow through
    // the responder chain to `NSSplitViewController.toggleSidebar(_:)` on
    // the parent split VC. Having a third entry point in the dock was
    // redundant chrome that Egor asked to drop.
    private let addBtn:        DockButton
    private let cursorBtn:     DockButton
    private let panBtn:        DockButton
    private let zoomOutBtn:    DockButton
    private let zoomLabel:     NSTextField
    private let zoomInBtn:     DockButton
    private let zoomFitBtn:    DockButton
    private let annBtn:        DockButton

    // Liquid Glass chrome (macOS 26 Tahoe).
    // `container` coordinates all glass sampling; individual pills live
    // inside its `contentView`. The container owns elevation/shadow —
    // we don't draw our own anymore.
    private let container: WFGlassEffectContainerView
    private let accentPill: WFGlassEffectView   // [addBtn]
    private let navPill: WFGlassEffectView      // [cursorBtn, panBtn]
    private let zoomPill: WFGlassEffectView     // [zoomOut, 100%, zoomIn, zoomFit]
    private let actionsPill: WFGlassEffectView  // [annBtn]

    init() {
        addBtn        = DockButton(symbol: "plus",
                                   tooltip: "Add frame  ⎯ F",
                                   style: .primary)
        cursorBtn     = DockButton(symbol: "cursorarrow", tooltip: "Select  ⎯ V")
        cursorBtn.isActive = true
        panBtn        = DockButton(symbol: "hand.raised", tooltip: "Pan canvas  ⎯ H · hold Space temporarily")
        zoomOutBtn    = DockButton(symbol: "minus.magnifyingglass",
                                   tooltip: "Zoom out  ⎯ −")
        zoomInBtn     = DockButton(symbol: "plus.magnifyingglass",
                                   tooltip: "Zoom in  ⎯ +")
        zoomFitBtn    = DockButton(symbol: "arrow.up.left.and.arrow.down.right",
                                   tooltip: "Fit all  ⎯ 0")
        annBtn        = DockButton(symbol: "plus.bubble",
                                   tooltip: "Add comment  ⎯ C")
        zoomLabel = NSTextField(labelWithString: "100%")
        zoomLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        zoomLabel.textColor = WFDesign.text2
        zoomLabel.alignment = .center
        zoomLabel.isEditable = false
        zoomLabel.isBordered = false
        zoomLabel.drawsBackground = false
        zoomLabel.translatesAutoresizingMaskIntoConstraints = false

        container   = WFGlassEffectContainerView()
        accentPill  = WFGlassEffectView()
        navPill     = WFGlassEffectView()
        zoomPill    = WFGlassEffectView()
        actionsPill = WFGlassEffectView()

        super.init(frame: .zero)

        // Constraint-based layout: the pills' intrinsic content sizes
        // drive the container's width/height through the four edge
        // constraints below, which drive DockView's own width/height.
        // If we left `translatesAutoresizingMaskIntoConstraints` at its
        // default (true), AppKit would synthesize width==0 / height==0
        // NSAutoresizingMaskLayoutConstraints from the zero initial frame —
        // those fight the DockButton children's explicit 52pt size
        // constraints and Auto Layout breaks them at runtime ("Conflicting
        // constraints detected … Will attempt to recover by breaking
        // DockButton.width == 52"). CanvasHost positions us via
        // bottom-center constraints on its side.
        translatesAutoresizingMaskIntoConstraints = false

        // Pill corner radius — 25pt = height/2, turning every pill into
        // a TRUE capsule (full half-circle end caps). Every pill is 50pt
        // tall and every button (primary AND standard) is 50×50 with a
        // matching 25pt radius, so the first and last buttons in a pill
        // fill the end-caps edge-to-edge and the active/hover wash
        // traces exactly the pill's own silhouette. Previous iterations
        // tried 44×44 standard buttons with 4pt concentric padding —
        // that left a visible glass halo around an active button (Egor
        // caught it on the screenshot button: "проблема с кнопками и
        // пилюлями, посмотри как сделаны отступы у кнопки add"). The fix
        // is to match Add's geometry across the whole dock: button size
        // == pill height, button radius == pill radius, zero pill padding.
        // 2026-04-21 tweak: sized down from 52×52/r=26 to 50×50/r=25 per
        // Egor's "уменьшим пилюли и кнопки на 2 px" — same geometric
        // family, just a slightly less dominant dock.
        for pill in [accentPill, navPill, zoomPill, actionsPill] {
            pill.cornerRadius = 25
            pill.translatesAutoresizingMaskIntoConstraints = false
        }
        // Accent pill uses `soloPillContent` with zero padding — the
        // primary button is 50×50 and fills the 50×50 pill edge-to-edge
        // as a full circle. Other pills use `pillContent`, which ALSO
        // has zero padding now (previously 4pt all-sides); the standard
        // 50×50 buttons fit exactly inside the 50pt-tall pill, first/
        // last buttons' rounded corners meet the pill's end-cap
        // curvature, and middle buttons sit between 6pt gaps of bare
        // glass. The only difference between `pillContent` and
        // `soloPillContent` is now the inter-button spacing (`pillContent`
        // has 6pt for the gap between adjacent cells; `soloPillContent`
        // has 0 because there's only one cell to host).
        accentPill.contentView  = Self.soloPillContent(addBtn)
        navPill.contentView     = Self.pillContent([cursorBtn, panBtn])
        zoomPill.contentView    = Self.pillContent([zoomOutBtn, zoomLabel, zoomInBtn, zoomFitBtn])
        actionsPill.contentView = Self.soloPillContent(annBtn)

        // The container's `spacing` is the merge threshold — distance below
        // which adjacent pills visually fuse. We keep pills distinct (each
        // is its own logical group), so spacing stays 0 and the 6pt gap in
        // the enclosing stack is preserved. The container still performs
        // its coordination job (unified sampling, subpixel alignment).
        container.spacing = 0
        let pillsStack = NSStackView(views: [accentPill, navPill, zoomPill, actionsPill])
        pillsStack.orientation = .horizontal
        pillsStack.alignment = .centerY
        pillsStack.spacing = 6
        pillsStack.translatesAutoresizingMaskIntoConstraints = false
        container.contentView = pillsStack
        container.translatesAutoresizingMaskIntoConstraints = false

        addSubview(container)
        NSLayoutConstraint.activate([
            zoomLabel.widthAnchor.constraint(equalToConstant: 44),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Wire click callbacks.
        addBtn.onClick        = { [weak self] in self?.fire(.addFrame) }
        cursorBtn.onClick     = { [weak self] in self?.fire(.selectCursor) }
        panBtn.onClick        = { [weak self] in self?.fire(.selectPan) }
        zoomOutBtn.onClick    = { [weak self] in self?.fire(.zoomOut) }
        zoomInBtn.onClick     = { [weak self] in self?.fire(.zoomIn) }
        zoomFitBtn.onClick    = { [weak self] in self?.fire(.zoomFit) }
        annBtn.onClick        = { [weak self] in self?.fire(.toggleAnnotation) }

        setAccessibilityIdentifier("webframes.dock")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func fire(_ action: Action) {
        delegate?.dock(self, didPerform: action)
    }

    /// Builds the horizontal stack that lives inside a pill's `contentView`.
    /// Zero padding on all sides: every standard button is 50×50, same
    /// as the 50pt pill height, so there's no room to pad without
    /// leaving an orphan glass strip top/bottom. First and last buttons
    /// sit flush against the pill's end-cap (button radius 25 == pill
    /// radius 25 → curvatures match pixel-perfect), so the active-wash
    /// orange fill on an edge button traces the pill's silhouette
    /// exactly — matching the Add button's fill-the-pill look that
    /// Egor pointed at (polish #5d, "посмотри как сделаны отступы у
    /// кнопки add"). Previous iterations put 4pt concentric padding
    /// around 44×44 (r=22) buttons; that math was internally consistent
    /// but left a visible glass halo around an active chip, which read
    /// as "button floating in pill" rather than "button IS the pill".
    /// Inter-button spacing stays at 6pt — between adjacent buttons
    /// (in the flat middle of the pill, not at the end-caps) a
    /// 6pt gap of bare glass reads as "cleanly separated cells" and
    /// keeps active washes on neighbouring buttons from visually
    /// merging.
    private static func pillContent(_ views: [NSView]) -> NSView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 6
        s.edgeInsets = NSEdgeInsets()
        return s
    }

    /// Zero-padding wrapper used by the accent pill so the 50×50 primary
    /// button exactly fills the surrounding 50×50 glass surface. Wrapping
    /// in an NSStackView (rather than handing the button directly to the
    /// pill's `contentView`) keeps the `NSGlassEffectView.contentView`
    /// contract — a managed host view — intact.
    private static func soloPillContent(_ view: NSView) -> NSView {
        let s = NSStackView(views: [view])
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 0
        s.edgeInsets = NSEdgeInsets()
        return s
    }

    // MARK: - State setters
    //
    // These are pushed from the canvas JS whenever its own internal state
    // changes (zoom, mode toggles, annotation count). See the
    // `dock-state` envelope dispatched by saveState() / applyT() /
    // updatePanModeUI() in index.html.

    func setZoomPercent(_ pct: Int) {
        zoomLabel.stringValue = "\(pct)%"
    }

    func setPanMode(_ active: Bool) {
        panBtn.isActive = active
        cursorBtn.isActive = !active && !annBtn.isActive
    }

    func setAnnotationMode(_ active: Bool) {
        annBtn.isActive = active
        cursorBtn.isActive = !active && !panBtn.isActive
    }

    // `setSidebarOpen(_:)` used to live here and flipped `sidebarBtn`'s
    // accent wash to mirror the native split VC's collapse state. Deleted
    // on 2026-04-21 alongside the sidebar button itself — there is no
    // dock-level sidebar affordance anymore, so there's nothing for the
    // KVO on `sidebarItem.isCollapsed` to push into the dock. Toolbar
    // `.toggleSidebar` manages its own highlight.
}

// MARK: - DockButton

/// Custom button view — uniformly 50×50 with a 25pt radius (= 50/2),
/// i.e. a full circle. Both standard and primary buttons share this
/// geometry so that every button fills its enclosing pill edge-to-edge,
/// matching the Add button's Add-pill relationship (Egor's feedback:
/// "посмотри как сделаны отступы у кнопки add" — Add is 50×50 in a
/// 50-tall pill with zero inset, so its active wash exactly tracks the
/// pill's half-circle end caps; the rest of the dock should do the
/// same). Rounded background, SF Symbol image, three visual states
/// (idle / hover / active / primary). Built as an NSView rather than
/// NSButton because NSButton's default bezel fights the glass backdrop
/// (draws an opaque system button chrome that masks the blur). The pill
/// around us (NSGlassEffectView) provides surface / elevation; we just
/// paint the glyph and state wash.
final class DockButton: NSView {
    enum Style { case standard, primary }

    var onClick: (() -> Void)?
    var isActive: Bool = false {
        didSet { needsDisplay = true; updateTint() }
    }
    var symbolName: String {
        didSet { updateImage() }
    }
    let style: Style

    /// Corner radius used by both `layer.cornerRadius` (for hit-test
    /// masking) and `draw(_:)` (for the hover / active / primary fill).
    /// Always 25pt — equal to 50/2, making the button a full circle that
    /// matches its enclosing 50-tall pill's radius exactly. At the pill's
    /// end caps the button's rounded edge fuses with the pill's
    /// half-circle with zero halo; in the middle of a multi-button pill
    /// two adjacent circles touch flush against the pill's straight
    /// sides. One uniform radius across standard + primary keeps the
    /// whole dock reading as a single geometric family.
    private let cornerRadius: CGFloat

    private let imageView = NSImageView()
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(symbol: String, tooltip: String, style: Style = .standard) {
        self.style = style
        self.symbolName = symbol
        // Uniform 50×50 across both styles. With `cornerRadius = size/2`
        // the button becomes a perfect circle whose radius matches the
        // pill's (25pt), so when it sits at the pill's end cap the two
        // curvatures coincide exactly — no halo, which is what Add has
        // always looked like and what Egor asked the rest of the dock
        // to match ("посмотри как сделаны отступы у кнопки add").
        // Inter-button spacing inside a multi-button pill is handled by
        // the NSStackView's `spacing`, not by individual insets.
        // 2026-04-21 tweak: was 52, sized down to 50 per Egor's
        // "уменьшим пилюли и кнопки на 2 px".
        let size: CGFloat = 50
        self.cornerRadius = size / 2
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))

        wantsLayer = true
        layer?.cornerRadius = self.cornerRadius
        layer?.masksToBounds = true

        toolTip = tooltip

        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        addSubview(imageView)

        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size),
            heightAnchor.constraint(equalToConstant: size),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 20),
            imageView.heightAnchor.constraint(equalToConstant: 20),
        ])

        updateImage()
        updateTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateImage() {
        let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        let img = NSImage(systemSymbolName: symbolName,
                          accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        imageView.image = img
    }

    private func updateTint() {
        switch (style, isActive) {
        case (.primary, _):
            imageView.contentTintColor = .white
        case (.standard, true):
            // Active icon in the app's accent orange (#FE6337) — matches
            // the frame links, pins, and selected-chrome across the rest
            // of the UI. macOS system blue (controlAccentColor) doesn't
            // belong in this app.
            imageView.contentTintColor = WFDesign.accent
        case (.standard, false):
            imageView.contentTintColor = WFDesign.text2
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Match the layer cornerRadius set in init — must stay in sync so
        // the hover/active wash fill lines up with the clipped corners.
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        switch (style, isActive, hovering) {
        case (.primary, _, _):
            // Solid accent fill + a faint top highlight (1pt, 22% white).
            // Even though we sit inside a glass pill, the primary action
            // reads as a solid accent-coloured chip — Tahoe's HIG for the
            // "prominent" toolbar action. The highlight gives a soft
            // specular sheen that matches NSButton .push buttons.
            WFDesign.accent.setFill()
            path.fill()
            let highlight = NSRect(x: 0, y: bounds.height - 1,
                                   width: bounds.width, height: 1)
            NSColor.white.withAlphaComponent(0.22).setFill()
            highlight.fill()
        case (.standard, _, true):
            // Hover: neutral white wash, regardless of active state. We
            // deliberately do NOT tint the wash orange when active — Egor
            // asked to let the accent-coloured icon alone carry the "on"
            // signal (polish #5e): "давай в активном состоянии будем
            // красить только иконку без полупрозрачного оранжевого фона".
            // Without an orange plate, the active glyph reads as an
            // illuminated symbol on glass, which is calmer and closer to
            // how system toolbar toggles behave in Tahoe.
            //
            // Polish #5f: inset the hover wash by 3pt on each side so it
            // reads as a *halo around the glyph* rather than a pill-
            // filling plate. The wash is a 44×44 rounded-rect centred in
            // the 50×50 button, with radius 22 (= cornerRadius − inset)
            // to stay concentric with the pill's 25pt curvature. Gives a
            // visible gap of bare glass between the wash and the pill's
            // end-cap, which makes the hover feedback feel lighter.
            let hoverInset: CGFloat = 3
            let hoverRect = bounds.insetBy(dx: hoverInset, dy: hoverInset)
            let hoverRadius = max(0, cornerRadius - hoverInset)
            let hoverPath = NSBezierPath(roundedRect: hoverRect,
                                         xRadius: hoverRadius,
                                         yRadius: hoverRadius)
            NSColor.white.withAlphaComponent(0.09).setFill()
            hoverPath.fill()
        default:
            // Idle (active or not) — no fill. For active standard buttons
            // this means the orange-tinted icon from `updateTint()` floats
            // on bare glass; for idle standard buttons the pill itself is
            // the entire surface.
            break
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Subtle press animation — tap feels more responsive when the
        // icon dips on mouseDown. We animate the imageView's layer
        // (not self's) to avoid fighting AppKit's autolayout-driven
        // anchorPoint management on the button background. Mirrors the
        // same pattern used in `spin()` below.
        if let iconLayer = imageView.layer {
            Self.recenterAnchorPoint(for: iconLayer)
            let press = CABasicAnimation(keyPath: "transform.scale")
            press.fromValue = 1.0
            press.toValue   = 0.88
            press.duration  = 0.08
            press.timingFunction = CAMediaTimingFunction(name: .easeOut)
            press.autoreverses = true
            iconLayer.add(press, forKey: "press")
        }
        onClick?()
    }

    /// Shift a layer's `anchorPoint` to its center (0.5, 0.5) while
    /// keeping its visual frame unchanged. NSView-backed layers default
    /// to anchorPoint (0, 0) — naively reassigning to (0.5, 0.5) moves
    /// the layer's visible origin by −bounds/2, which is exactly the
    /// icon-shift-on-first-click bug this helper exists to prevent.
    /// The formula `newPos = oldPos + (newAnchor − oldAnchor) · bounds`
    /// preserves `anchorPoint · bounds` in parent coordinates, which is
    /// the only invariant CA cares about. Idempotent: if the anchor is
    /// already centered, nothing changes.
    private static func recenterAnchorPoint(for layer: CALayer) {
        let target = CGPoint(x: 0.5, y: 0.5)
        guard layer.anchorPoint != target else { return }
        let dx = (target.x - layer.anchorPoint.x) * layer.bounds.width
        let dy = (target.y - layer.anchorPoint.y) * layer.bounds.height
        layer.anchorPoint = target
        layer.position = CGPoint(x: layer.position.x + dx,
                                 y: layer.position.y + dy)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent)  { hovering = false }

    // MARK: - Keyboard focus
    //
    // DockButton is an NSView (not NSButton) because NSButton's default
    // bezel fights the glass backdrop. AppKit normally skips plain
    // NSViews during tab traversal — opting in here lets users reach
    // the dock's controls with Tab / Shift-Tab, and activate them with
    // Space or Return. Activation reuses `onClick`, so the delegate
    // receives the same DockView.Action as mouse clicks.

    // Like system buttons: focusable only with Keyboard Navigation on
    // (System Settings › Keyboard). Otherwise a mouse click would make the
    // button first responder and draw a blue focus ring around it.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    // Focus ring tracks the same rounded-rect silhouette as the hover/
    // active wash so the ring sits snugly against the button glyph,
    // rather than a system-default square halo.
    override func drawFocusRingMask() {
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        path.fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        // Space (" ") and Return ("\r") activate — matches the AppKit
        // convention for default NSButton behavior.
        if chars == " " || chars == "\r" {
            onClick?()
            return
        }
        super.keyDown(with: event)
    }

    override func resetCursorRects() {
        // NSCursor.pointingHand feels right for a clickable button in a
        // floating toolbar.
        discardCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// 360° rotation of the image, mirroring the CSS `spin360` animation
    /// the refresh-all button used to play.
    func spin() {
        guard let layer = imageView.layer else { return }
        // Rotation happens around anchorPoint — NSView-backed layers
        // default to (0, 0), so we re-center with a position-preserving
        // shift (see `recenterAnchorPoint` above for why).
        Self.recenterAnchorPoint(for: layer)
        let anim = CABasicAnimation(keyPath: "transform.rotation.z")
        anim.fromValue = 0
        anim.toValue   = -CGFloat.pi * 2  // clockwise
        anim.duration  = 0.52
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(anim, forKey: "spin")
    }
}
