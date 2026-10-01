import AppKit

// MARK: - Public state + delegate

/// Serializable snapshot of a frame card's chrome. Everything the native
/// view needs to render the header, resize chrome, and link handles is
/// carried here. Pushed from canvas JS (`pushFrameCardsToNative`) as a
/// bulk array on every `dots()` tick so the card stays in sync with the
/// canonical JS state — until Phase 6d moves that state to Swift.
struct FrameCardState {
    let id: String
    let num: Int
    let label: String
    let sourceLabel: String
    /// Navigation URL for web frames (http, https, wf-github).
    /// Empty for image frames. Shown in the header as a read-only
    /// address, mirroring a browser's URL bar.
    let url: String
    /// Logical frame width (page viewport width — NOT card width).
    let w: CGFloat
    /// Logical frame height.
    let h: CGFloat
    let selected: Bool
    let dropTarget: Bool
    /// True when annotation mode is on — native card disables drag on the
    /// header so clicks drop pins instead. Mirrors the old `.fc.shld`
    /// behaviour without needing a literal shield div.
    let annotationMode: Bool
    /// Image frames have no "reload" source-badge semantics and no manual
    /// width/height controls. Render a stripped header in that case.
    let isImage: Bool
    /// True only for image frames created by freezing a live web frame.
    /// These retain their original URL and can be restored in place.
    let canRestoreLive: Bool
}

/// One-shot drag intent shipped back to canvas JS. The JS layer still
/// owns the frames[] array in Phase 6c, so we just funnel user gestures
/// there; JS updates `f.x/f.y/f.w/f.h` and pushes a fresh rect back via
/// the round-trip that already exists (`wfSyncFrameRects`).
enum FrameCardIntent {
    case select
    case close
    case reload
    case goBack
    case freezeSnapshot
    case restoreLive
    case sizePreset(String)           // "desktop" | "mobile"
    case sizeCommit(w: CGFloat, h: CGFloat)
    case titleCommit(String)
    /// Committed URL from the address-bar field on a web/local frame.
    /// Triggers a navigation in the frame's WKWebView. Not used for image
    /// frames (they reuse `titleCommit` for label editing).
    case navigate(String)
    case dragStart(clientX: CGFloat, clientY: CGFloat)
    case dragMove(clientX: CGFloat, clientY: CGFloat)
    case dragEnd
    case resizeStart(mode: String, clientX: CGFloat, clientY: CGFloat)
    case resizeMove(clientX: CGFloat, clientY: CGFloat)
    case resizeEnd
    case linkDragStart(side: String, clientX: CGFloat, clientY: CGFloat)
    case linkDragMove(clientX: CGFloat, clientY: CGFloat)
    case linkDragEnd(clientX: CGFloat, clientY: CGFloat)
}

protocol FrameCardDelegate: AnyObject {
    func frameCard(_ card: FrameCardView, didEmit intent: FrameCardIntent)
}

// MARK: - Palette tokens
//
// Historically this file duplicated the CSS `:root` tokens. The canonical
// palette now lives in `WFDesign` (see StartWindowController.swift) — this
// type-alias-style shim keeps call sites (`Palette.blue`, `Palette.bg2`,
// etc.) readable while funnelling every token through the single source
// of truth. `blue` remains the legacy alias for the accent (orange #FE6337)
// to avoid churn in existing FrameCardView wiring. `red` / `redBg` keep
// their local definition because they use a distinct alpha recipe tuned
// for the card's danger states (e.g., unread-thread dots).

private enum Palette {
    static let bg2      = WFDesign.bg2
    static let bg3      = WFDesign.bg3
    static let bg5      = WFDesign.bg5
    static let border   = WFDesign.border
    static let border2  = WFDesign.border2
    static let border3  = WFDesign.border3
    static let text     = WFDesign.text
    static let text2    = WFDesign.text2
    static let text3    = WFDesign.text3
    static let blue     = WFDesign.accent
    static let blueBg   = WFDesign.accentBg
    static let blueBdr  = WFDesign.accentBdr
    static let red      = NSColor(red: 239/255.0, green:  68/255.0, blue: 68/255.0, alpha: 0.85)
    static let redBg    = NSColor(red: 239/255.0, green:  68/255.0, blue: 68/255.0, alpha: 0.15)
}

// MARK: - FrameCardView

/// Native replacement for the old HTML `.fc` card. Contains the header
/// (number badge, title, viewport controls, source badge, close), the
/// 4 link-handle dots, and the resize grip/bar. The frame's actual
/// WKWebView lives inside `container` which is parented here — earlier
/// phases migrated the WKWebView and pin overlay, so we're wrapping
/// that pre-existing FrameContainer.
///
/// Bounds: equal to the CARD visual rect (header + body + 1pt border).
/// Link handles and the bottom resize bar overflow visually by a few
/// points; `clipsToBounds` stays false so they remain visible. Hit
/// testing walks subviews regardless of parent bounds, so overflow
/// elements still receive clicks.
///
/// Phase 6c scope: visual + input dispatch. All mutations still go
/// through canvas JS — we emit high-level intents and let JS persist
/// / call `saveState`. Phase 6d pulls the state into Swift.
final class FrameCardView: NSView {

    // MARK: Geometry constants

    static let headerHeight: CGFloat = CardGeometry.header
    static let mobileBreakpoint: CGFloat = CardGeometry.mobileBreakpoint
    // Frame card body radius — one step down from the ambient .large (16pt)
    // tier used for top-level glass panels, so stacked surfaces read with a
    // clear parent → child curvature hierarchy. See `WFDesign.Radius`.
    static let cornerRadius: CGFloat = WFDesign.Radius.medium
    static let linkHandleSize: CGFloat = 12
    static let linkHandleOverhang: CGFloat = 6  // half outside frame edge
    static let resizeGripSize: CGFloat = 18
    static let resizeBarHeight: CGFloat = 12
    static let resizeBarWidth: CGFloat = 40
    static let resizeBarOverhang: CGFloat = 12  // hangs BELOW card bottom

    // MARK: Identity + wiring

    let id: String
    let container: FrameContainer
    weak var delegate: FrameCardDelegate?

    // MARK: State

    private var chrome: FrameCardState?
    /// True while the user is actively dragging the header. Used to
    /// gate mouseDown on other subviews (we drop intent emission during
    /// a drag so `dragMove` doesn't race a `select`).
    private var dragging = false
    private var resizing: String? = nil  // "corner" | "bottom" | nil
    private var linkDraggingFromSide: String? = nil

    // MARK: Subviews — chrome

    private let headerView = DragCapableView(frame: .zero)
    private let titleField = InlineTextField(string: "")
    /// Floating controls above the card — viewport preset toggles, width/
    /// height, source pill, close. Fades in on hover/selection, hides
    /// otherwise so the canvas reads as a grid of clean frame previews.
    private let toolbar = FrameToolbarView()
    /// Hover tracking area on the card's full bounds; separate area lives
    /// on the toolbar itself so dragging the mouse from card → toolbar
    /// doesn't drop `hovering` state. The two states OR together.
    private var cardTracking: NSTrackingArea?
    private var hoveringCard = false { didSet { syncToolbarVisibility() } }
    /// Debounces the hide — on mouseExit we wait this long before fading
    /// out so the user has time to travel from the card into the floating
    /// toolbar across the 8pt gap. Cancelled on any re-hover / selection.
    private var hideDebounceTimer: Timer?

    // Link handles — one per side. Each owns its own drag state machine.
    private let leftHandle   = LinkHandleView(side: "left")
    private let rightHandle  = LinkHandleView(side: "right")
    private let topHandle    = LinkHandleView(side: "top")
    private let bottomHandle = LinkHandleView(side: "bottom")

    // Resize chrome.
    private let resizeCorner = ResizeGripView(mode: "corner")
    private let resizeBar    = ResizeGripView(mode: "bottom")

    // MARK: Init

    init(id: String, container: FrameContainer) {
        self.id = id
        self.container = container
        super.init(frame: .zero)
        wantsLayer = true
        // Start invisible; fade in on the first chrome push (see setChrome).
        // This avoids the "slam into view" at creation that happens when
        // the card is added to the host but the WKWebView is still blank.
        alphaValue = 0
        layer?.cornerRadius = Self.cornerRadius
        layer?.backgroundColor = Palette.bg2.cgColor
        layer?.borderColor = Palette.border.cgColor
        layer?.borderWidth = 1
        // Rich drop-shadow matches the .fc box-shadow in CSS. NSView's
        // shadow is drawn by its layer's shadow* properties; we must keep
        // masksToBounds false for the shadow to escape the layer bounds.
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        buildHeader()

        // Container is parented here instead of directly in FrameLayerView.
        // The container keeps its own rounded clip (bottom corners of the
        // card) via a mask we'll install on layout. Added first so the
        // header stacks above any web content near the top edge.
        addSubview(container)
        addSubview(headerView, positioned: .above, relativeTo: container)

        addSubview(leftHandle)
        addSubview(rightHandle)
        addSubview(topHandle)
        addSubview(bottomHandle)
        addSubview(resizeCorner)
        addSubview(resizeBar)

        // Toolbar floats ABOVE the card (in flipped coords, negative y).
        // Start hidden — hover/selection drives visibility via
        // `syncToolbarVisibility`.
        toolbar.alphaValue = 0
        toolbar.onHoverChanged = { [weak self] in self?.syncToolbarVisibility() }
        addSubview(toolbar)

        // Wire delegate pass-through: each inner view emits via our shared
        // closure, which forwards up to the card's delegate.
        let forward: (FrameCardIntent) -> Void = { [weak self] intent in
            guard let self, let d = self.delegate else { return }
            d.frameCard(self, didEmit: intent)
        }
        titleField.onCommit = { [weak self] value in
            // Image frames keep the old semantics (custom label rename).
            // Web / local frames treat the field as an address bar —
            // commit navigates the webview.
            guard let s = self else { return }
            if s.chrome?.isImage == true {
                forward(.titleCommit(value))
            } else {
                forward(.navigate(value))
            }
        }
        toolbar.onClose = { forward(.close) }
        toolbar.onReload = { forward(.reload) }
        toolbar.onBack = { forward(.goBack) }
        toolbar.onFreezeSnapshot = { forward(.freezeSnapshot) }
        toolbar.onRestoreLive = { forward(.restoreLive) }
        toolbar.onPreset = { forward(.sizePreset($0)) }
        toolbar.onSizeCommit = { [weak self] w, h in
            guard let s = self?.chrome else { return }
            forward(.sizeCommit(w: w ?? s.w, h: h ?? s.h))
        }

        for handle in [leftHandle, rightHandle, topHandle, bottomHandle] {
            handle.onIntent = forward
        }
        resizeCorner.onIntent = forward
        resizeBar.onIntent = forward

        // Header drag — emitted by DragCapableView only when the hit
        // falls on empty header space (its children consume their own
        // clicks first).
        headerView.onIntent = forward
        headerView.onSelect = forward

        bodyDragView.onIntent = forward
        bodyDragView.onSelect = forward
        bodyDragView.autoresizingMask = [.width, .height]
    }

    private let bodyDragView = DragCapableView(frame: .zero)

    /// Image frames move by their body too. Without this layer the click
    /// reached the <img> in the web view and started a WebKit image drag: a
    /// ghost left the frame and, dropped on the canvas, became a duplicate.
    /// It sits under the pin overlay (pins stay clickable) and steps aside
    /// in comment mode so clicks place pins.
    private func updateBodyDrag(isImage: Bool, annotationMode: Bool) {
        let wanted = isImage && !annotationMode
        if wanted, bodyDragView.superview == nil {
            bodyDragView.frame = container.bounds
            container.addSubview(bodyDragView, positioned: .below, relativeTo: container.pinOverlay)
        } else if !wanted, bodyDragView.superview != nil {
            bodyDragView.removeFromSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Flipped coords + hit-test

    override var isFlipped: Bool { true }

    /// Several subviews sit visually OUTSIDE `self.frame`:
    ///   - `toolbar` floats above the card (negative y)
    ///   - `LinkHandleView` overhangs each edge by 6pt
    ///   - `resizeBar` hangs 12pt below the bottom
    /// Default NSView.hitTest rejects any point outside `self.frame`
    /// before descending into subviews, so clicks in those overhang
    /// regions would fall through to whatever lives behind the card.
    /// We override to also descend into subviews whose *own* frame
    /// contains the point, even when the parent's frame doesn't — so
    /// the floating toolbar (and link/resize affordances) are clickable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let standard = super.hitTest(point) { return standard }
        // `point` is in the parent's coord space; our subviews' frames
        // are in ours. Convert once.
        let local = convert(point, from: superview)
        // `sub.hitTest` expects a point in its superview's coords (= ours).
        for sub in subviews.reversed() where !sub.isHidden {
            if sub.frame.contains(local) {
                if let hit = sub.hitTest(local) { return hit }
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        // Pull first-responder status so keyDown (Delete / Escape / ⌘R)
        // lands on us. DragCapableView also bubbles clicks here, so
        // clicks on the header do the same thing.
        window?.makeFirstResponder(self)
        delegate?.frameCard(self, didEmit: .select)
        super.mouseDown(with: event)
    }

    // MARK: Keyboard

    /// The card becomes first responder when clicked (selection) so it
    /// can receive Delete / Escape / ⌘R. The responder chain on macOS
    /// routes key events up from the deepest first responder, so having
    /// the card accept first responder lets us swallow those keys.
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // Draw focus ring? The chrome already signals selection via the
        // blue border, so we skip the system focus ring to avoid double
        // emphasis.
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // delete / forward-delete
            delegate?.frameCard(self, didEmit: .close)
        case 53: // escape — cancel any in-flight drag / resize / link
            delegate?.frameCard(self, didEmit: .dragEnd)
            delegate?.frameCard(self, didEmit: .resizeEnd)
            delegate?.frameCard(self, didEmit: .linkDragEnd(clientX: 0, clientY: 0))
        case 15: // R — ⌘R reloads the frame (matches browser convention)
            if event.modifierFlags.contains(.command) {
                delegate?.frameCard(self, didEmit: .reload)
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: Layout

    /// Update the card's world-to-screen visual rect and internal
    /// layout. Called from the bridge on every `wfSyncFrameRects`.
    /// `visualRect` is in the coordinate system of the parent
    /// FrameLayerView — already in screen-space (scale applied).
    /// `logicalSize` is the WKWebView's un-scaled page viewport used
    /// by FrameContainer's scale transform.
    func updateVisualRect(_ visualRect: CGRect, logicalSize: CGSize, holes: [FrameManager.Hole]) {
        // Panning and dragging only move the card. Re-laying out its header,
        // toolbar, handles, web view scale and chrome mask for every card on
        // every tick is what made those gestures stutter on busy boards.
        if visualRect.size == frame.size, logicalSize == lastLogicalSize, holes.isEmpty, lastHolesEmpty {
            if frame.origin != visualRect.origin { setFrameOrigin(visualRect.origin) }
            return
        }
        self.frame = visualRect
        lastLogicalSize = logicalSize
        lastHolesEmpty = holes.isEmpty
        relayoutInterior(visualRect: visualRect, logicalSize: logicalSize, holes: holes)
    }
    private var lastLogicalSize: CGSize = .zero
    private var lastHolesEmpty = false
    /// Toolbar pill size; measuring the stack view is costly, so it is
    /// recomputed only when the chrome changes.
    private var cachedToolbarSize: NSSize?

    private func relayoutInterior(visualRect: CGRect, logicalSize: CGSize, holes: [FrameManager.Hole]) {
        // Card internal bounds: (0,0) to (w, h). Header spans full width,
        // body fills the remainder.
        let w = visualRect.width
        let h = visualRect.height
        let headerRect = NSRect(x: 0, y: 0, width: w, height: Self.headerHeight)

        headerView.frame = headerRect
        layoutHeader(width: w)

        // Floating toolbar above the card (flipped coords → negative y).
        // The toolbar's frame extends 8pt BELOW the glass pills into the
        // visual gap between toolbar and card so the tracking area covers
        // that gap. Without this, moving the cursor from card → pill
        // crosses a dead zone that fires `mouseExited` on the card and
        // never `mouseEntered` on the toolbar, hiding the pill mid-travel.
        let tbSize = cachedToolbarSize ?? toolbar.fittingSize
        cachedToolbarSize = tbSize
        let tbGap: CGFloat = 8
        toolbar.frame = NSRect(
            x: 0,
            y: -(tbSize.height + tbGap),
            width: tbSize.width,
            height: tbSize.height + tbGap
        )
        // Card's tracking rect is sized from toolbar.frame.height (see
        // updateTrackingAreas) — refresh it any time the toolbar resizes.
        updateTrackingAreas()

        let border = CardGeometry.border
        let bodyRect = NSRect(x: border, y: headerRect.maxY, width: max(0, w - 2 * border), height: max(0, h - headerRect.maxY - border))
        container.updateLayout(visualRect: bodyRect, logicalSize: logicalSize, holes: holes)

        // Link handles — 12pt circles centered on each edge midpoint,
        // overlapping half-inside/half-outside. Bounds overflow the
        // card's NSView rect; clipsToBounds is already false.
        let hs = Self.linkHandleSize
        let overhang = Self.linkHandleOverhang
        leftHandle.frame   = NSRect(x: -overhang, y: (h / 2) - hs / 2, width: hs, height: hs)
        rightHandle.frame  = NSRect(x: w - overhang, y: (h / 2) - hs / 2, width: hs, height: hs)
        topHandle.frame    = NSRect(x: (w / 2) - hs / 2, y: -overhang, width: hs, height: hs)
        bottomHandle.frame = NSRect(x: (w / 2) - hs / 2, y: h - overhang, width: hs, height: hs)

        // Resize grip (bottom-right corner, inside the card).
        let gs = Self.resizeGripSize
        resizeCorner.frame = NSRect(x: w - gs, y: h - gs, width: gs, height: gs)
        // Resize bar — hangs below the card.
        let bw = Self.resizeBarWidth
        resizeBar.frame = NSRect(x: (w / 2) - bw / 2, y: h, width: bw, height: Self.resizeBarHeight)
    }

    // MARK: Chrome state

    func setChrome(_ newChrome: FrameCardState) {
        let prev = chrome
        chrome = newChrome
        // Selection ring + drop-target highlight share the border color
        // slot; drop-target wins if both are set (mirrors old CSS
        // `.fc.link-drop-target` which overrode `.fc.sel`).
        let border: NSColor
        let shadowOpacity: Float
        let shadowRadius: CGFloat
        if newChrome.dropTarget {
            border = Palette.blue
            shadowOpacity = 0.55
            shadowRadius = 18
        } else if newChrome.selected {
            border = Palette.blue
            shadowOpacity = 0.5
            shadowRadius = 16
        } else {
            border = Palette.border
            shadowOpacity = 0.4
            shadowRadius = 12
        }
        let wantBorderWidth: CGFloat = (newChrome.selected || newChrome.dropTarget) ? 2 : 1

        // Animate the selection/drop-target transitions. CALayer
        // properties animate implicitly inside a CATransaction with
        // duration set; the previous code just slammed values which
        // produced a harsh "pop" when selection flipped between frames.
        // 180ms feels responsive (≈easing out) without dragging.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer?.borderColor = border.cgColor
        layer?.borderWidth = wantBorderWidth
        layer?.shadowOpacity = shadowOpacity
        layer?.shadowRadius  = shadowRadius
        CATransaction.commit()

        // Image frames keep a user-editable custom label. Web / local
        // frames use the field as a browser-style editable address bar.
        titleField.isLocked = false
        titleField.stringValue = newChrome.isImage ? newChrome.label : newChrome.url
        toolbar.apply(state: newChrome, mobileBreakpoint: Self.mobileBreakpoint)
        if prev?.isImage != newChrome.isImage || prev?.canRestoreLive != newChrome.canRestoreLive || prev?.w != newChrome.w || prev?.h != newChrome.h {
            // Toolbar contents changed size: re-measure and let the next
            // rect update run a full layout.
            cachedToolbarSize = nil
            lastHolesEmpty = false
        }

        // Annotation-mode: disable header drag (it'd conflict with the
        // pin-drop gesture going to the shield below); visually we leave
        // the chrome as-is so the user keeps the affordance.
        headerView.dragEnabled = !newChrome.annotationMode
        updateBodyDrag(isImage: newChrome.isImage, annotationMode: newChrome.annotationMode)
        (container as FrameContainer).updateAnnotationCursor(on: newChrome.annotationMode)

        syncToolbarVisibility()

        if prev?.w != newChrome.w {
            needsLayout = true
        }
    }

    // MARK: Header construction

    private func buildHeader() {
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = Palette.bg3.cgColor
        headerView.layer?.borderColor = Palette.border.cgColor
        let bottomHair = CALayer()
        bottomHair.backgroundColor = Palette.border2.cgColor
        bottomHair.name = "bottomHair"
        headerView.layer?.addSublayer(bottomHair)
        headerView.layer?.cornerRadius = Self.cornerRadius
        headerView.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]

        titleField.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        titleField.textColor = Palette.text
        titleField.drawsBackground = false
        titleField.isBordered = false
        titleField.isEditable = false  // toggled on by dblclick (unless locked)
        titleField.isSelectable = true
        titleField.cell?.usesSingleLineMode = true
        titleField.cell?.lineBreakMode = .byTruncatingTail

        headerView.addSubview(titleField)
    }

    /// Single-row header: just the URL/label field. Viewport controls,
    /// source pill, and the close × have all moved to the floating
    /// `toolbar` overlay above the card.
    private func layoutHeader(width W: CGFloat) {
        let pad: CGFloat = 10
        let titleH: CGFloat = 20
        let titleY = (Self.headerHeight - titleH) / 2
        titleField.frame = NSRect(
            x: pad, y: titleY,
            width: max(0, W - pad * 2), height: titleH
        )
        if let hair = headerView.layer?.sublayers?.first(where: { $0.name == "bottomHair" }) {
            hair.frame = CGRect(x: 0, y: headerView.bounds.height - 1, width: W, height: 1)
        }
    }

    // MARK: Hover → toolbar visibility

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = cardTracking { removeTrackingArea(t) }
        // Extend the tracking rect UPWARD past the card's top to cover the
        // floating toolbar + the 8pt gap between them. Without this, the
        // cursor crossing from card → pill triggers `mouseExited` on the
        // card before the pill's own tracking area fires `mouseEntered`,
        // and the grace timer loses a race against the fade-out. With the
        // rect extended, the card stays "hovered" continuously whenever
        // the cursor is anywhere in the card-plus-pill cluster, so the
        // pill never flickers off. Explicit rect (no `.inVisibleRect`)
        // because we need to grow outside the view's own bounds.
        let halo = toolbar.frame.height > 0 ? toolbar.frame.height + 4 : 60
        let rect = NSRect(
            x: 0, y: -halo,
            width: bounds.width, height: bounds.height + halo
        )
        let t = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil
        )
        addTrackingArea(t)
        cardTracking = t
    }

    override func mouseEntered(with event: NSEvent) { hoveringCard = true }
    override func mouseExited(with event: NSEvent)  { hoveringCard = false }

    private func syncToolbarVisibility() {
        let visible = (chrome?.selected == true) || hoveringCard || toolbar.isHovering
        hideDebounceTimer?.invalidate()
        hideDebounceTimer = nil
        if visible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                toolbar.animator().alphaValue = 1
            }
            return
        }
        // Grace period: give the cursor ~320ms to cross the 8pt gap into
        // the toolbar. If any hover flag flips back to true in that window,
        // `syncToolbarVisibility` runs again and cancels this timer.
        hideDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: false) { [weak self] _ in
            guard let self else { return }
            // Re-check state at fire time — the tracking areas may have
            // flipped back to hovering without triggering syncToolbar
            // (e.g., fast pointer through the gap into the pill).
            let stillHidden = !(self.chrome?.selected == true
                || self.hoveringCard
                || self.toolbar.isHovering)
            guard stillHidden else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.toolbar.animator().alphaValue = 0
            }
        }
    }
}

// MARK: - Header drag wrapper
//
// Header view that emits drag + select intents. Because we add children
// (number badge, title, viewport controls, source badge, close button)
// as subviews, AppKit's standard `hitTest` routes clicks on them to the
// subviews first — only clicks on empty header background reach our
// mouseDown override. That's exactly the gesture we want for "drag the
// frame" (the old HTML rule was `if(e.target===.fh && !button/badge)`).
final class DragCapableView: NSView {
    var dragEnabled = true
    var onIntent: ((FrameCardIntent) -> Void)?
    var onSelect: ((FrameCardIntent) -> Void)?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard dragEnabled else { super.mouseDown(with: event); return }
        let p = window?.mouseLocationOutsideOfEventStream ?? NSEvent.mouseLocation
        onSelect?(.select)
        onIntent?(.dragStart(clientX: p.x, clientY: p.y))
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragEnabled else { return }
        let p = window?.mouseLocationOutsideOfEventStream ?? NSEvent.mouseLocation
        onIntent?(.dragMove(clientX: p.x, clientY: p.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragEnabled else { return }
        onIntent?(.dragEnd)
    }
}

// MARK: - Floating toolbar (viewport + source + close)
//
// Pill-shaped overlay that floats above the frame card. Shown on hover
// or selection, hidden otherwise. Owns the desktop/mobile preset
// toggles, the width × height fields, the reload source pill, and the
// close ×. This replaces the old in-header chrome row so the frame
// itself reads as a clean preview surface.

private final class FrameToolbarView: NSView {
    var onClose: (() -> Void)?
    var onReload: (() -> Void)?
    var onBack: (() -> Void)?
    var onFreezeSnapshot: (() -> Void)?
    var onRestoreLive: (() -> Void)?
    var onPreset: ((String) -> Void)?
    /// Callback receives the committed width/height; nil for the axis
    /// that didn't change.
    var onSizeCommit: ((CGFloat?, CGFloat?) -> Void)?
    var onHoverChanged: (() -> Void)?

    private(set) var isHovering = false

    private let backButton    = IconActionButton(symbol: "chevron.backward")
    private let snapshotButton = IconActionButton(symbol: "camera")
    private let desktopButton = IconToggleButton(symbol: "desktopcomputer")
    private let mobileButton  = IconToggleButton(symbol: "iphone")
    private let widthField    = NumericField()
    private let heightField   = NumericField()
    private let aspectLock    = IconToggleButton(symbol: "lock.open")
    private let closeButton   = DeleteFrameButton()
    private var snapshotRestoresLive = false

    /// Last width / height pushed from `apply(state:...)` — used when the
    /// aspect lock is engaged to compute the paired dimension from a single
    /// axis commit.
    private var lastW: CGFloat = 0
    private var lastH: CGFloat = 0

    /// macOS 26 Tahoe Liquid Glass chrome. Matches `DockView`: a single
    /// `NSGlassEffectContainerView` wrapping three separate pills so the
    /// nav / size / close groups read as distinct capsules that share
    /// unified glass sampling. No text labels beyond the numeric fields —
    /// every other cell is an icon so the toolbar reads as pure chrome.
    private let container = WFGlassEffectContainerView()
    private let navPill   = WFGlassEffectView()   // [back]
    private let sizePill  = WFGlassEffectView()   // [desktop, mobile, W, H]
    private let closePill = WFGlassEffectView()   // [close]

    private var trackingArea: NSTrackingArea?

    // Geometry — every pill 30pt tall; cornerRadius = height/2 → full capsule.
    private let pillHeight: CGFloat = 30
    private let iconSize:   CGFloat = 22
    private let fieldW:     CGFloat = 46
    private let fieldH:     CGFloat = 22

    init() {
        super.init(frame: .zero)

        backButton.translatesAutoresizingMaskIntoConstraints = false
        snapshotButton.translatesAutoresizingMaskIntoConstraints = false
        desktopButton.translatesAutoresizingMaskIntoConstraints = false
        mobileButton.translatesAutoresizingMaskIntoConstraints = false
        widthField.translatesAutoresizingMaskIntoConstraints = false
        heightField.translatesAutoresizingMaskIntoConstraints = false
        aspectLock.translatesAutoresizingMaskIntoConstraints = false
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            backButton.widthAnchor.constraint(equalToConstant: iconSize),
            backButton.heightAnchor.constraint(equalToConstant: iconSize),
            snapshotButton.widthAnchor.constraint(equalToConstant: iconSize),
            snapshotButton.heightAnchor.constraint(equalToConstant: iconSize),
            desktopButton.widthAnchor.constraint(equalToConstant: iconSize),
            desktopButton.heightAnchor.constraint(equalToConstant: iconSize),
            mobileButton.widthAnchor.constraint(equalToConstant: iconSize),
            mobileButton.heightAnchor.constraint(equalToConstant: iconSize),
            widthField.widthAnchor.constraint(equalToConstant: fieldW),
            widthField.heightAnchor.constraint(equalToConstant: fieldH),
            heightField.widthAnchor.constraint(equalToConstant: fieldW),
            heightField.heightAnchor.constraint(equalToConstant: fieldH),
            aspectLock.widthAnchor.constraint(equalToConstant: iconSize),
            aspectLock.heightAnchor.constraint(equalToConstant: iconSize),
            closeButton.widthAnchor.constraint(equalToConstant: iconSize),
            closeButton.heightAnchor.constraint(equalToConstant: iconSize),
        ])

        for pill in [navPill, sizePill, closePill] {
            pill.cornerRadius = pillHeight / 2
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.heightAnchor.constraint(equalToConstant: pillHeight).isActive = true
        }

        navPill.contentView   = Self.pillContent([backButton, snapshotButton], insets: 4)
        sizePill.contentView  = Self.pillContent([desktopButton, mobileButton,
                                                  widthField, aspectLock, heightField],
                                                 insets: 6)
        closePill.contentView = Self.pillContent([closeButton], insets: 4)

        container.spacing = 0
        container.translatesAutoresizingMaskIntoConstraints = false
        let pillsStack = NSStackView(views: [navPill, sizePill, closePill])
        pillsStack.orientation = .horizontal
        pillsStack.alignment = .centerY
        pillsStack.spacing = 6
        pillsStack.translatesAutoresizingMaskIntoConstraints = false
        container.contentView = pillsStack

        addSubview(container)
        // Pin container to the TOP of our bounds, not all four edges — the
        // toolbar's outer frame is 8pt taller than the glass so the tracking
        // area bridges the visual gap between pill and card. See
        // `FrameCardView.relayoutInterior`.
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.heightAnchor.constraint(equalToConstant: pillHeight),
        ])

        backButton.onClick    = { [weak self] in self?.onBack?() }
        snapshotButton.onClick = { [weak self] in
            guard let self else { return }
            if self.snapshotRestoresLive { self.onRestoreLive?() }
            else { self.onFreezeSnapshot?() }
        }
        desktopButton.onClick = { [weak self] in self?.onPreset?("desktop") }
        mobileButton.onClick  = { [weak self] in self?.onPreset?("mobile") }
        widthField.onCommit   = { [weak self] in self?.commitSize(newW: $0, newH: nil) }
        heightField.onCommit  = { [weak self] in self?.commitSize(newW: nil, newH: $0) }
        aspectLock.onClick    = { [weak self] in self?.toggleAspectLock() }
        closeButton.onClick   = { [weak self] in self?.onClose?() }
    }

    private func toggleAspectLock() {
        aspectLock.isOn.toggle()
        aspectLock.symbolName = aspectLock.isOn ? "lock" : "lock.open"
    }

    /// Ship a size commit upward. When the aspect lock is engaged we scale
    /// the opposite axis so the frame keeps its aspect ratio — the user
    /// only types one number, both get updated in one intent.
    private func commitSize(newW: CGFloat?, newH: CGFloat?) {
        if aspectLock.isOn, lastW > 0, lastH > 0 {
            let ratio = lastW / lastH
            if let w = newW {
                onSizeCommit?(w, max(1, w / ratio))
                return
            }
            if let h = newH {
                onSizeCommit?(max(1, h * ratio), h)
                return
            }
        }
        onSizeCommit?(newW, newH)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(state: FrameCardState, mobileBreakpoint: CGFloat) {
        // Ordinary imported images have no web source. A frozen snapshot
        // keeps this capsule visible as a one-click route back to live.
        navPill.isHidden = state.isImage && !state.canRestoreLive
        backButton.isHidden = state.isImage
        snapshotRestoresLive = state.canRestoreLive
        snapshotButton.symbolName = state.canRestoreLive ? "globe" : "camera"
        snapshotButton.toolTip = state.canRestoreLive
            ? "Restore live website"
            : "Convert website to snapshot"
        widthField.doubleValue = Double(state.w)
        heightField.doubleValue = Double(state.h)
        lastW = state.w
        lastH = state.h
        desktopButton.isOn = state.w > mobileBreakpoint
        mobileButton.isOn = !desktopButton.isOn
        // Device presets only resize a live page's viewport; on an image they
        // would just distort the picture, so image frames keep W×H only.
        desktopButton.isHidden = state.isImage
        mobileButton.isHidden = state.isImage
        needsLayout = true
    }

    override var fittingSize: NSSize {
        let s = container.fittingSize
        return NSSize(width: ceil(s.width), height: max(s.height, pillHeight))
    }

    /// Builds the horizontal stack that lives inside a pill's `contentView`.
    /// Mirrors `DockView.pillContent` — the glass pill sizes itself from the
    /// stack's fitting size, so we set explicit edgeInsets for breathing
    /// room and let the glass hug it.
    private static func pillContent(_ views: [NSView], insets: CGFloat) -> NSView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 4
        s.edgeInsets = NSEdgeInsets(top: 0, left: insets, bottom: 0, right: insets)
        return s
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        onHoverChanged?()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        onHoverChanged?()
    }
}

// MARK: - Source badge (hover → "update")

/// Renders the pill-shaped source label (e.g. "github", "local:3000",
/// "finder"). On hover it switches text to "update" so clicking is
/// obviously a reload affordance.
private final class SourceBadgeButton: NSView {
    var onClick: (() -> Void)?
    var label: String = "" {
        didSet {
            labelField.stringValue = isHovering ? "update" : label
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    private var isHovering = false
    private let labelField = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 100
        layer?.borderWidth = 1
        labelField.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        labelField.drawsBackground = false
        labelField.isBordered = false
        labelField.isEditable = false
        labelField.isSelectable = false
        labelField.alignment = .center
        addSubview(labelField)
        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        labelField.sizeToFit()
        let w = max(labelField.fittingSize.width + 14, 40)
        return NSSize(width: w, height: 18)
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func layout() {
        super.layout()
        labelField.frame = NSRect(x: 6, y: 0, width: bounds.width - 12, height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        labelField.stringValue = "update"
        invalidateIntrinsicContentSize()
        needsLayout = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        labelField.stringValue = label
        invalidateIntrinsicContentSize()
        needsLayout = true
        applyStyle()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func applyStyle() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if isHovering {
            layer?.backgroundColor = Palette.blue.cgColor
            layer?.borderColor = Palette.blue.cgColor
            labelField.textColor = NSColor.white
        } else {
            layer?.backgroundColor = Palette.blue.withAlphaComponent(0.28).cgColor
            layer?.borderColor = Palette.blueBdr.cgColor
            labelField.textColor = Palette.blue
        }
        CATransaction.commit()
    }
}

// MARK: - Delete frame button

private final class DeleteFrameButton: NSView {
    var onClick: (() -> Void)?
    override var isFlipped: Bool { true }
    private var hovering = false { didSet { restyle() } }
    private var tracking: NSTrackingArea?
    private let imageView = NSImageView()

    init() {
        super.init(frame: .zero)
        // Layer-backed so the SF-symbol tint renders reliably.
        wantsLayer = true
        layer?.cornerRadius = WFDesign.Radius.small
        layer?.backgroundColor = NSColor.clear.cgColor

        toolTip = "Delete frame"
        let raw = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete frame")
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        imageView.image = raw?.withSymbolConfiguration(cfg)
        imageView.image?.isTemplate = true
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
        ])

        restyle()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent)  { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    private func restyle() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer?.backgroundColor = NSColor.clear.cgColor
        imageView.contentTintColor = hovering ? Palette.red : Palette.text2
        CATransaction.commit()
    }
}

// MARK: - Desktop / mobile toggle icon

private final class IconToggleButton: NSView {
    var onClick: (() -> Void)?
    var isOn = false { didSet { restyle() } }
    var symbolName: String { didSet { reloadSymbol() } }
    private let imageView = NSImageView()
    private var hovering = false { didSet { restyle() } }
    private var tracking: NSTrackingArea?

    init(symbol: String) {
        self.symbolName = symbol
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5

        imageView.image?.isTemplate = true
        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        reloadSymbol()

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 12),
            imageView.heightAnchor.constraint(equalToConstant: 12),
        ])

        restyle()
    }

    private func reloadSymbol() {
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        imageView.image = img?.withSymbolConfiguration(cfg)
        imageView.image?.isTemplate = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent)  { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    private func restyle() {
        // Flat chip — no background or border. State is conveyed entirely
        // through the glyph tint: accent orange when active, primary text
        // color on hover, muted otherwise. Matches the "only icons and
        // numbers, color signals state" constraint for the floating pill.
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        if isOn {
            imageView.contentTintColor = Palette.blue
        } else if hovering {
            imageView.contentTintColor = Palette.text
        } else {
            imageView.contentTintColor = Palette.text2
        }
    }
}

// MARK: - Icon action button (hover + click, no on/off state)

private final class IconActionButton: NSView {
    var onClick: (() -> Void)?
    var symbolName: String { didSet { reloadSymbol() } }
    private let imageView = NSImageView()
    private var hovering = false { didSet { restyle() } }
    private var tracking: NSTrackingArea?

    init(symbol: String) {
        self.symbolName = symbol
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5

        imageView.imageScaling = .scaleNone
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 12),
            imageView.heightAnchor.constraint(equalToConstant: 12),
        ])
        reloadSymbol()
        restyle()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent)  { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func reloadSymbol() {
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        imageView.image = img?.withSymbolConfiguration(cfg)
        imageView.image?.isTemplate = true
    }

    private func restyle() {
        layer?.backgroundColor = NSColor.clear.cgColor
        imageView.contentTintColor = hovering ? Palette.text : Palette.text2
    }
}

// MARK: - Numeric width/height field

private final class NumericField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((CGFloat) -> Void)?
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        // NSTextFieldCell draws text top-aligned — swap in our vertically
        // centered cell so the number sits on the field's middle axis.
        let vc = VCenteredTextFieldCell(textCell: "")
        vc.isEditable = true
        vc.isSelectable = true
        vc.isBordered = false
        vc.drawsBackground = false
        vc.alignment = .center
        vc.usesSingleLineMode = true
        vc.wraps = false
        cell = vc
        font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textColor = Palette.text
        drawsBackground = false
        isBordered = false
        isEditable = true
        alignment = .center
        delegate = self
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        focusRingType = .none
        formatter = {
            let f = NumberFormatter()
            f.minimumIntegerDigits = 1
            f.maximumFractionDigits = 0
            f.allowsFloats = false
            f.minimum = 200
            return f
        }()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        textColor = Palette.blue
        return ok
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        textColor = Palette.text
        onCommit?(CGFloat(doubleValue))
    }

    override func keyDown(with event: NSEvent) {
        // Return commits + resigns first responder; Escape cancels.
        if event.keyCode == 36 /* return */ || event.keyCode == 76 /* numpad */ {
            onCommit?(CGFloat(doubleValue))
            window?.makeFirstResponder(superview)
            return
        }
        if event.keyCode == 53 /* escape */ {
            window?.makeFirstResponder(superview)
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Inline title field (read-only → editable on double-click)

/// NSTextFieldCell draws text baseline-aligned to the top of its rect,
/// which makes a single-line title visibly drift upward in a tall cell.
/// `VCenteredTextFieldCell` shrinks `titleRect`/`editingRect` to the
/// intrinsic text height and re-centers them vertically so the glyphs
/// end up on the field's middle axis. Shared by `InlineTextField` below.
private final class VCenteredTextFieldCell: NSTextFieldCell {
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let size = cellSize(forBounds: rect)
        let h = min(size.height, rect.height)
        var r = super.titleRect(forBounds: rect)
        r.origin.y = rect.origin.y + (rect.height - h) / 2
        r.size.height = h
        return r
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(withFrame: titleRect(forBounds: cellFrame), in: controlView)
    }

    override func edit(withFrame rect: NSRect,
                       in controlView: NSView,
                       editor textObj: NSText,
                       delegate: Any?,
                       event: NSEvent?) {
        super.edit(withFrame: titleRect(forBounds: rect), in: controlView,
                   editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect,
                         in controlView: NSView,
                         editor textObj: NSText,
                         delegate: Any?,
                         start selStart: Int,
                         length selLength: Int) {
        super.select(withFrame: titleRect(forBounds: rect), in: controlView,
                     editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }
}

private final class InlineTextField: NSTextField {
    var onCommit: ((String) -> Void)?
    /// When true, double-click no longer switches to edit mode. Used for
    /// URL frames whose title mirrors navigation state (like a browser
    /// address bar) rather than a user-owned label.
    var isLocked: Bool = false
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let newCell = VCenteredTextFieldCell(textCell: stringValue)
        newCell.isEditable = false
        newCell.isSelectable = true
        newCell.isBordered = false
        newCell.drawsBackground = false
        newCell.usesSingleLineMode = true
        newCell.lineBreakMode = .byTruncatingTail
        cell = newCell
    }

    convenience init(string: String) {
        self.init(frame: .zero)
        stringValue = string
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 && !isLocked {
            isEditable = true
            window?.makeFirstResponder(self)
            currentEditor()?.selectAll(nil)
            discardCursorRects()
            window?.invalidateCursorRects(for: self)
            return
        }
        // Single click bubbles up for frame selection / drag.
        nextResponder?.mouseDown(with: event)
    }

    // The whole drag goes to the header, not just the first click;
    // otherwise a drag that starts on the title text stalls.
    override func mouseDragged(with event: NSEvent) {
        if currentEditor() == nil { nextResponder?.mouseDragged(with: event) } else { super.mouseDragged(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        if currentEditor() == nil { nextResponder?.mouseUp(with: event) } else { super.mouseUp(with: event) }
    }

    // A selectable text field installs an I-beam over itself, which made the
    // cursor flicker over the draggable header. Show the I-beam only while
    // the title is being edited.
    override func resetCursorRects() {
        if currentEditor() != nil { super.resetCursorRects() }
        else { addCursorRect(bounds, cursor: .arrow) }
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        isEditable = false
        window?.invalidateCursorRects(for: self)
        onCommit?(stringValue)
    }
}

// MARK: - Link handles

/// 12pt dot at a frame edge midpoint. Invisible until the card is
/// hovered or a link-drag is globally active (the "armed" state flag is
/// toggled from FrameCardView via its parent card-state). On mouseDown
/// it emits linkDragStart and captures tracking via follow-up
/// mouseDragged / mouseUp events.
private final class LinkHandleView: NSView {
    let side: String
    var onIntent: ((FrameCardIntent) -> Void)?
    override var isFlipped: Bool { true }
    private var hovering = false { didSet { applyHoverVisuals() } }
    private var tracking: NSTrackingArea?
    /// CAShapeLayer halo that grows in on hover. Kept as a sublayer so the
    /// animation is free (CALayer animates bounds/opacity implicitly);
    /// previously this was drawn *over* the main dot inside `draw(_:)`
    /// which meant the halo was actually hidden by the subsequent fill.
    private let haloLayer = CAShapeLayer()
    private let dotLayer  = CAShapeLayer()

    init(side: String) {
        self.side = side
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        // Halo paints below the dot — CALayer z order follows sublayer
        // array order (first = back), so add halo first.
        haloLayer.fillColor = Palette.blueBg.cgColor
        haloLayer.opacity = 0
        layer?.addSublayer(haloLayer)
        dotLayer.fillColor   = NSColor.white.cgColor
        dotLayer.strokeColor = NSColor.white.cgColor
        dotLayer.lineWidth   = 1
        layer?.addSublayer(dotLayer)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // Halo sits slightly outside the bounds; dot fits inside. Sublayer
        // frames use the parent's local coord space (origin at 0,0), so
        // we can use `bounds.size` directly rather than going through
        // `bounds.minX/.minY`.
        let w = bounds.width
        let h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        haloLayer.frame = CGRect(x: -3, y: -3, width: w + 6, height: h + 6)
        haloLayer.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: w + 6, height: h + 6), transform: nil)
        dotLayer.frame = CGRect(x: 0, y: 0, width: w, height: h)
        dotLayer.path = CGPath(ellipseIn: CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1), transform: nil)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent)  { hovering = false }

    private func applyHoverVisuals() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        if hovering {
            dotLayer.fillColor   = Palette.blue.cgColor
            dotLayer.strokeColor = Palette.blue.cgColor
            haloLayer.opacity = 1
        } else {
            dotLayer.fillColor   = NSColor.white.cgColor
            dotLayer.strokeColor = NSColor.white.cgColor
            haloLayer.opacity = 0
        }
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        let p = window?.mouseLocationOutsideOfEventStream ?? NSEvent.mouseLocation
        onIntent?(.linkDragStart(side: side, clientX: p.x, clientY: p.y))
    }
    override func mouseDragged(with event: NSEvent) {
        let p = window?.mouseLocationOutsideOfEventStream ?? NSEvent.mouseLocation
        onIntent?(.linkDragMove(clientX: p.x, clientY: p.y))
    }
    override func mouseUp(with event: NSEvent) {
        let p = window?.mouseLocationOutsideOfEventStream ?? NSEvent.mouseLocation
        onIntent?(.linkDragEnd(clientX: p.x, clientY: p.y))
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }
}

// MARK: - Resize grip / bar

private final class ResizeGripView: NSView {
    let mode: String   // "corner" | "bottom"
    var onIntent: ((FrameCardIntent) -> Void)?
    override var isFlipped: Bool { true }
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(mode: String) { self.mode = mode; super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent)  { hovering = false }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: mode == "corner" ? .crosshair : .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        let p = window?.mouseLocationOutsideOfEventStream ?? NSEvent.mouseLocation
        onIntent?(.resizeStart(mode: mode, clientX: p.x, clientY: p.y))
    }
    override func mouseDragged(with event: NSEvent) {
        let p = window?.mouseLocationOutsideOfEventStream ?? NSEvent.mouseLocation
        onIntent?(.resizeMove(clientX: p.x, clientY: p.y))
    }
    override func mouseUp(with event: NSEvent) {
        onIntent?(.resizeEnd)
    }

    override func draw(_ dirtyRect: NSRect) {
        let tint = hovering ? Palette.text2 : Palette.text3
        if mode == "corner" {
            // Try an SF Symbol for the diagonal resize affordance; fall
            // back to the hand-drawn L if the symbol isn't available
            // (older system) so this keeps rendering something.
            if let raw = NSImage(systemSymbolName: "arrow.down.right", accessibilityDescription: "Resize frame") {
                let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
                let img = raw.withSymbolConfiguration(cfg) ?? raw
                img.isTemplate = true
                let side: CGFloat = 10
                let rect = NSRect(x: bounds.maxX - side - 3,
                                  y: bounds.maxY - side - 3,
                                  width: side, height: side)
                tint.set()
                img.draw(in: rect, from: .zero, operation: .sourceIn,
                         fraction: 1.0, respectFlipped: true, hints: [:])
            } else {
                tint.setStroke()
                let path = NSBezierPath()
                path.lineWidth = 1.5
                let inset: CGFloat = 4
                let size: CGFloat = 8
                let x = bounds.maxX - inset
                let y = bounds.maxY - inset
                path.move(to: NSPoint(x: x, y: y - size))
                path.line(to: NSPoint(x: x, y: y))
                path.line(to: NSPoint(x: x - size, y: y))
                path.stroke()
            }
        } else {
            // Bottom resize bar — rounded pill. Slightly widens on hover
            // for an affordance cue (discoverable without moving the
            // cursor over the handle).
            let w: CGFloat = hovering ? 32 : 24
            let h: CGFloat = hovering ? 4 : 3
            tint.setFill()
            let p = NSBezierPath(
                roundedRect: NSRect(x: (bounds.width - w) / 2,
                                    y: (bounds.height - h) / 2,
                                    width: w, height: h),
                xRadius: h / 2, yRadius: h / 2
            )
            p.fill()
        }
    }
}
