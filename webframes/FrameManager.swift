import AppKit
import os
import WebKit

/// Visual container for a frame WKWebView with independent logical/visual sizing.
final class FrameContainer: NSView, WKNavigationDelegate {
    let webView: WKWebView
    /// Native pin overlay sits above the WKWebView and renders annotation
    /// pins. Clicks on pins are captured here — clicks that miss fall
    /// through to the webview as before. See `PinOverlayView` for the
    /// coord-space / hit-test rules.
    let pinOverlay: PinOverlayView
    var annotationMode = false

    private var logicalSize: CGSize

    init(webView: WKWebView, frame: NSRect, logicalSize: CGSize) {
        self.webView = webView
        self.logicalSize = logicalSize
        self.pinOverlay = PinOverlayView(frame: NSRect(origin: .zero, size: frame.size))
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = FrameCardView.cornerRadius
        // Only the bottom corners curve — the top of the container abuts
        // the flat-bottom header, so rounding there would cut into that
        // junction and leak the card background through the corners.
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer?.masksToBounds = true

        webView.navigationDelegate = self
        webView.wantsLayer = true
        webView.layer?.anchorPoint = .zero
        webView.autoresizingMask = []
        webView.frame = NSRect(origin: .zero, size: logicalSize)
        addSubview(webView)
        // Overlay pinned to container bounds; order matters — added AFTER
        // webView so it wins hit tests on pin clicks.
        pinOverlay.autoresizingMask = [.width, .height]
        addSubview(pinOverlay)
        applyScale()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Pages can link or redirect anywhere; keep main-frame navigations on
    /// the same allowlist as the frame's own URL. Subresources and iframes
    /// are unaffected.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let isMain = navigationAction.targetFrame?.isMainFrame ?? true
        let url = navigationAction.request.url
        let scheme = url?.scheme?.lowercased() ?? ""
        if isMain, !scheme.isEmpty, scheme != "about",
           FrameURLPolicy.allowedURL(url?.absoluteString ?? "") == nil {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.layoutSubtreeIfNeeded()
        applyScale()
        DispatchQueue.main.async { [weak self] in self?.applyScale() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // AppKit reconfigures the WKWebView layer when attaching a restored card.
        DispatchQueue.main.async { [weak self] in
            self?.needsLayout = true
            self?.layoutSubtreeIfNeeded()
        }
    }

    override func layout() {
        super.layout()
        applyScale()
        // Re-apply the last mask against the new bounds so the outer
        // rounded-rect tracks resize / zoom; holes are unchanged.
        applyChromeMask(holes: chromeHoles)
    }

    func updateLayout(visualRect: NSRect, logicalSize: CGSize, holes: [FrameManager.Hole]) {
        self.frame = visualRect
        if self.logicalSize != logicalSize {
            self.logicalSize = logicalSize
            webView.frame = NSRect(origin: .zero, size: logicalSize)
        }
        applyScale()
        applyChromeMask(holes: holes)
        // Autoresizing keeps overlay.bounds in sync with container.bounds,
        // so `PinOverlayView.layout()` re-runs pin positioning on any
        // visual-rect change (window resize, zoom, add-frame expansion).
    }

    private func applyScale() {
        guard logicalSize.width > 0, logicalSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        let sx = bounds.width / logicalSize.width
        let sy = bounds.height / logicalSize.height
        webView.layer?.anchorPoint = .zero
        webView.layer?.position = .zero
        webView.layer?.setAffineTransform(CGAffineTransform(scaleX: sx, y: sy))
    }

    // MARK: - Chrome-overlay mask
    //
    // Canvas chrome (dock, annotation panel, help hint) lives in the canvas
    // WKWebView BELOW the frame layer in z-order. JS computes the rects of
    // those chrome elements relative to each frame and sends them here; we
    // apply a CAShapeLayer mask that fills the whole container *minus* the
    // hole rects (evenOdd fill rule). The net effect is that the frame
    // renders everywhere except those holes, through which the canvas — and
    // thus the chrome — is visible. So chrome appears to float on top of
    // frames without the frames actually shrinking.
    private var chromeHoles: [FrameManager.Hole] = []
    // Single source of truth for the outer rounded-rect — defers to the
    // frame card chrome so the mask never drifts from the card background.
    private static let cornerRadius: CGFloat = FrameCardView.cornerRadius

    /// `rect` with its bottom corners rounded, in this container's layer
    /// coordinates — AppKit's, y growing upward (see the hole flip below),
    /// so the bottom edge is `minY`.
    static func bottomRoundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.closeSubpath()
        return path
    }

    private func applyChromeMask(holes: [FrameManager.Hole]) {
        chromeHoles = holes
        guard let layer = layer else { return }
        if holes.isEmpty {
            // Plain rounded clip — cheaper than a mask layer.
            layer.mask = nil
            layer.cornerRadius = Self.cornerRadius
            layer.masksToBounds = true
            return
        }
        let mask = (layer.mask as? CAShapeLayer) ?? CAShapeLayer()
        let path = CGMutablePath()
        // Outer shape = the container with only its BOTTOM corners rounded,
        // like the plain clip above (`maskedCorners`). Rounding all four cut
        // the top corners away where the container meets the header's flat
        // bottom — two notches under every header the moment a chrome hole
        // (the dock over a tall frame) switched the clip to this mask.
        path.addPath(Self.bottomRoundedRect(bounds, radius: Self.cornerRadius))
        // Holes (in container-local coords) — even-odd fill punches them out.
        // Each hole may carry a corner radius so the cut-out matches the
        // chrome element's border-radius; without this, a square hole
        // exposes canvas background at the chrome's rounded corners and
        // reads as a "reflection" of the chrome silhouette into the frame.
        //
        // Y-flip: JS sends holes in web coords (origin at top-left, y
        // growing downward). FrameContainer is a plain (non-flipped) NSView,
        // so its backing layer uses AppKit coords (origin at bottom-left,
        // y growing upward). Parent FrameLayerView IS flipped, which is why
        // the container's visual position on the canvas is correct — but
        // the container's own bounds aren't flipped, so hole paths rendered
        // with a raw y from JS end up mirrored vertically (e.g. dock hole
        // at the bottom of the frame appears at the top). Flip here.
        for hole in holes {
            let rect = CGRect(
                x: hole.rect.origin.x,
                y: bounds.height - hole.rect.origin.y - hole.rect.height,
                width: hole.rect.width,
                height: hole.rect.height
            )
            if hole.radius > 0 {
                // Clamp to half the shorter side (UIKit/CA requirement) —
                // anything larger produces undefined behavior.
                let maxR = min(rect.width, rect.height) / 2
                let r = min(hole.radius, maxR)
                path.addPath(CGPath(
                    roundedRect: rect,
                    cornerWidth: r,
                    cornerHeight: r,
                    transform: nil
                ))
            } else {
                path.addRect(rect)
            }
        }
        // Disable the implicit animation on path so resizes don't visibly
        // smear the hole across frames.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.path = path
        mask.fillRule = .evenOdd
        mask.frame = bounds
        layer.mask = mask
        // The mask now owns clipping; cornerRadius + masksToBounds would
        // just be redundant (and masksToBounds on top of a mask sometimes
        // short-circuits the mask entirely depending on render path).
        layer.masksToBounds = false
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        annotationMode ? nil : super.hitTest(point)
    }

    // MARK: - Annotation cursor
    //
    // When annotation mode is on, hitTest returns nil so mouse *events*
    // fall through to the canvas shield — but the system's cursor-rect
    // machinery follows the view hierarchy and still picks up whatever
    // cursor the WKWebView advertises under the pointer (arrow over empty
    // space, iBeam over text, pointing hand over links). That produces
    // the flicker the user reported: cursor glyph changes as the pointer
    // crosses selectable content inside a frame, even though the clicks
    // go to annotation pin creation on the canvas.
    //
    // Fix: register an NSTrackingArea with `.cursorUpdate` over the full
    // container. When enabled, `cursorUpdate(with:)` fires on every
    // movement inside the area and we set NSCursor.crosshair explicitly —
    // this wins against whatever the WKWebView subview would advertise,
    // because cursor-update events bubble from the deepest view that
    // handles them, and WKWebView doesn't override cursorUpdate (it uses
    // `resetCursorRects` instead, which yields to an active tracking area
    // on an ancestor).

    private var annotationTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = annotationTracking {
            removeTrackingArea(old)
            annotationTracking = nil
        }
        guard annotationMode else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        annotationTracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if annotationMode { NSCursor.crosshair.set() }
        else { super.cursorUpdate(with: event) }
    }

    override func mouseEntered(with event: NSEvent) {
        // Belt-and-suspenders: a cursorUpdate may not fire right after the
        // mode toggle if the pointer is stationary, so nudge on entry too.
        if annotationMode { NSCursor.crosshair.set() }
    }

    func updateAnnotationCursor(on: Bool) {
        annotationMode = on
        updateTrackingAreas()
        // If the cursor is already inside us when mode flips, AppKit won't
        // deliver a fresh cursorUpdate until the next movement. Push the
        // cursor synchronously so there's no moment of "wrong glyph".
        if on { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
    }
}

/// Owns FrameCardViews — lifecycle, rect updates, annotation mode.
///
/// Phase 6c: we now wrap each frame's WKWebView in a FrameCardView that
/// paints the header, link-handles, and resize grips natively. The old
/// HTML `.fc` DOM is no longer rendered; canvas JS still owns frame
/// state (frames[]) and pushes chrome updates via `frame-card-set`.
final class FrameManager: PinOverlayDelegate, FrameCardDelegate {

    /// Punch-out for the chrome mask. The radius makes the cut-out track the
    /// chrome element's CSS `border-radius` — without it, a square hole
    /// exposes canvas background at the chrome's corners and reads as a
    /// "reflection" of the chrome silhouette into the frame.
    struct Hole {
        let rect: CGRect
        let radius: CGFloat
    }

    weak var hostLayer: FrameLayerView?
    private weak var bridge: NativeBridge?
    private var cards: [String: FrameCardView] = [:]
    private var annotationMode = false

    init(bridge: NativeBridge) { self.bridge = bridge }

    /// Read-only access to the WKWebView of a given frame. Callers
    /// outside this module used to get at the container directly;
    /// keep the indirection narrow.
    func webView(for id: String) -> WKWebView? {
        cards[id]?.container.webView
    }

    // MARK: - Lifecycle

    func createFrame(id: String, url: String, cardRect: CGRect, logicalSize: CGSize) {
        guard let host = hostLayer, cards[id] == nil, let bridge else { return }

        let config = WKWebViewConfiguration()
        let uc = WKUserContentController()
        // `WKUserContentController` retains its handlers. Registering the
        // bridge directly formed a cycle (bridge → manager → card → webView →
        // configuration → bridge) that only `destroyFrame` broke, so closing a
        // document kept every WKWebView alive. The proxy holds the bridge weakly.
        uc.add(WeakScriptMessageHandler(bridge), name: NativeBridge.frameChannelName)
        uc.addUserScript(WKUserScript(
            source: InspectBridgeScript.source,
            injectionTime: .atDocumentStart,
            // Only the page itself talks to Web Frames; iframes it embeds
            // (ads, widgets, third-party content) get no bridge.
            forMainFrameOnly: true
        ))
        config.userContentController = uc

        if let sourceURL = URL(string: url), let source = GitHubFrameSource(url: sourceURL) {
            config.setURLSchemeHandler(GitHubFrameSchemeHandler(source: source), forURLScheme: GitHubFrameSource.scheme)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        #if DEBUG
        webView.isInspectable = true
        #endif

        let container = FrameContainer(webView: webView, frame: .zero, logicalSize: logicalSize)
        container.updateAnnotationCursor(on: annotationMode)
        container.pinOverlay.delegate = self

        let card = FrameCardView(id: id, container: container)
        card.delegate = self
        // `cardRect` as received from JS is the card (header + body) rect
        // in screen-space — the same thing `frame-set-rect` will keep
        // pushing on every `dots()`. Seed the initial frame so the
        // WKWebView has non-zero bounds before the first sync lands.
        card.updateVisualRect(cardRect, logicalSize: logicalSize, holes: [])
        host.addSubview(card)

        // Fade the card in from transparent — it starts at alphaValue = 0
        // (set in FrameCardView.init) so the first frame doesn't "slam"
        // onto the canvas before its WKWebView has loaded anything. A
        // tiny delay (one runloop tick) ensures the layout has flushed
        // before the animation begins so the card fades in at its final
        // position rather than sliding from 0,0.
        DispatchQueue.main.async {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                card.animator().alphaValue = 1
            }
        }

        // Image frames (`url == "image://<label>"`) carry their pixels in
        // `FrameModel.extras["imgUrl"]` as a base64 `data:` URL, not at the
        // frame's own URL — so we skip the normal load here and let the
        // caller push the data URL via `loadImageDataURL` once the card
        // exists. Pre-Phase-6e the JS DOM `<img>` path rendered these
        // frames; Step 70e deleted index.html and nothing caught the
        // image case natively, so image drops landed in the workspace
        // model but the canvas went blank. Branching on the scheme here
        // keeps the WKWebView constructor unified while letting image
        // frames short-circuit the load path.
        if FrameURLPolicy.isImageFrameURL(url) {
            // Caller owns the follow-up `loadImageDataURL` call.
        } else if let requestURL = FrameURLPolicy.allowedURL(url) {
            webView.load(URLRequest(url: requestURL))
        } else {
            Log.bridge.error("frame \(id, privacy: .public): unsupported source scheme")
            webView.loadHTMLString(FrameURLPolicy.unsupportedHTML(for: url), baseURL: nil)
        }
        cards[id] = card
    }

    /// Load a base64 image `data:` URL into the frame's WKWebView, wrapped
    /// in a minimal HTML shell (`<img>` filling the viewport, no margins,
    /// transparent background, `object-fit: contain` so aspect ratio is
    /// preserved when the logical size doesn't match the natural image
    /// size 1:1). Called by `CanvasHost` right after `createFrameView`
    /// for `isImage == true` frames — same slot the old JS DOM `<img>`
    /// path used to occupy. No-op on unknown ids. The HTML is inlined
    /// (no baseURL) and the image lives entirely in the data URL, so
    /// no external network requests or user-folder reads are involved.
    func loadImageDataURL(id: String, dataURL: String) {
        guard let c = cards[id] else { return }
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          html,body{margin:0;padding:0;background:transparent;width:100%;height:100%;overflow:hidden}
          img{display:block;width:100%;height:100%;object-fit:contain;-webkit-user-drag:none;user-select:none}
        </style></head>
        <body><img src="\(dataURL)" alt="" draggable="false"></body></html>
        """
        c.container.webView.loadHTMLString(html, baseURL: nil)
    }

    /// Document teardown: release every card and its WKWebView. Safe to
    /// call more than once.
    func destroyAllFrames() {
        for id in Array(cards.keys) { destroyFrame(id: id) }
    }

    func destroyFrame(id: String) {
        guard let card = cards.removeValue(forKey: id) else { return }
        card.container.webView.stopLoading()
        card.container.webView.configuration.userContentController
            .removeScriptMessageHandler(forName: NativeBridge.frameChannelName)
        card.removeFromSuperview()
    }

    /// Set the CARD visual rect (header + body). JS computes this in
    /// screen-space via `(f.x*scale+px, f.y*scale+py, (f.w+2)*scale, (f.h+35)*scale)`.
    func setCardRect(id: String, cardRect: CGRect, logicalSize: CGSize?, holes: [Hole] = []) {
        guard let c = cards[id] else { return }
        c.updateVisualRect(cardRect,
                           logicalSize: logicalSize ?? c.container.bounds.size,
                           holes: holes)
    }

    /// Apply a chrome-state snapshot (label, num, sourceLabel, selected,
    /// etc.) to a frame's card. Silently ignores unknown ids.
    func setCardChrome(id: String, state: FrameCardState) {
        cards[id]?.setChrome(state)
    }

    func load(id: String, url: String) {
        guard let c = cards[id] else { return }
        guard let u = FrameURLPolicy.allowedURL(url) else {
            c.container.webView.loadHTMLString(FrameURLPolicy.unsupportedHTML(for: url), baseURL: nil)
            return
        }
        c.container.webView.load(URLRequest(url: u))
    }

    /// Re-fetch the current URL of the frame's webview. Driven by the
    /// `.reload` intent on FrameCardView (Phase 6e Step 70d) — purely
    /// visual, no workspace mutation. No-op on unknown ids.
    func reload(id: String) {
        cards[id]?.container.webView.reload()
    }

    /// Navigate the frame's webview back in its history. No-op when
    /// `canGoBack` is false (webview ignores — silent by design).
    func goBack(id: String) {
        cards[id]?.container.webView.goBack()
    }

    func postToFrame(id: String, payload: Any) {
        guard let c = cards[id] else {
            Log.frame.error("postToFrame: unknown frameId \(id, privacy: .public)")
            return
        }
        // The inspector protocol uses a `[String: Any]` envelope (type + params).
        // Anything else is a programming error in the caller — log and bail
        // rather than fabricating a shape WebMessenger rejects.
        guard let dict = payload as? [String: Any] else {
            Log.frame.error("postToFrame: payload is not a dictionary (frameId \(id, privacy: .public))")
            return
        }
        WebMessenger.dispatch(dict, on: .frame, to: c.container.webView)
    }

    // MARK: - Annotation / visibility

    func setAnnotationMode(_ on: Bool) {
        annotationMode = on
        cards.values.forEach { $0.container.updateAnnotationCursor(on: on) }
    }

    func setVisible(id: String, visible: Bool) {
        cards[id]?.alphaValue = visible ? 1.0 : 0.08
    }

    private var lastOrder: [String] = []
    func setFrameOrder(_ ids: [String]) {
        guard ids != lastOrder, let host = hostLayer else { return }
        lastOrder = ids
        for id in ids.reversed() {
            if let card = cards[id] { host.addSubview(card, positioned: .above, relativeTo: nil) }
        }
    }

    func setAllVisible(_ visible: Bool) {
        let a: CGFloat = visible ? 1.0 : 0.0
        cards.values.forEach { $0.alphaValue = a }
    }

    func frameId(for webView: WKWebView?) -> String? {
        guard let webView else { return nil }
        return cards.first { $0.value.container.webView === webView }?.key
    }

    // MARK: - Pin overlay

    func setPins(frameId id: String, pins: [PinModel]) {
        cards[id]?.container.pinOverlay.setPins(pins)
    }

    func setPinScroll(frameId id: String, x: CGFloat, y: CGFloat) {
        cards[id]?.container.pinOverlay.setScroll(x: x, y: y)
    }

    private func frameId(for overlay: PinOverlayView) -> String? {
        cards.first { $0.value.container.pinOverlay === overlay }?.key
    }

    // MARK: - PinOverlayDelegate

    func pinOverlay(_ overlay: PinOverlayView, didClickPinId id: String) {
        // Phase 6e Step 70a: route the pin-click directly into the
        // host. Previously we round-tripped through canvas JS
        // (`pin-clicked` → `WFPins.onPinClicked` → `NativeAPI.pinEditorOpen`
        // → bridge `pin-editor-open` → `canvasHost.presentPinEditor`).
        // Swift now builds the pin-editor payload from the workspace
        // annotation + its extras and presents the modal inline.
        guard let host = bridge?.canvasHost else { return }
        host.openPinEditor(forAnnotationId: id)
    }

    // MARK: - FrameCardDelegate
    //
    // Cards emit high-level user intents (select, drag/resize/link-drag
    // gestures, close, reload, size preset/commit, title commit). Phase 6e
    // Step 70d made this dispatch 100% native: every intent either
    // mutates `WorkspaceStore` through a `CanvasHost` helper (the JS
    // `WFFrame.handleIntent` round-trip is gone) or hits a pure-visual
    // local (reload). Step 70e retired the canvas WKWebView and the
    // `frame-intent` / `bridge.js` surface outright.
    //
    // No-op on a missing `canvasHost` — in practice `CanvasHost.init`
    // sets `bridge.canvasHost = self` before any card is created, so this
    // guard only fires during teardown when the host has already torn
    // itself down. Silently dropping the intent is correct in that case.

    func frameCard(_ card: FrameCardView, didEmit intent: FrameCardIntent) {
        guard let host = bridge?.canvasHost else { return }
        switch intent {
        case .select:
            host.selectFrame(card.id)
        case .close:
            host.closeFrame(id: card.id)
        case .reload:
            host.reloadFrame(id: card.id)
        case .goBack:
            host.goBackFrame(id: card.id)
        case .freezeSnapshot:
            host.freezeFrameAsSnapshot(id: card.id)
        case .restoreLive:
            host.restoreSnapshotToLive(id: card.id)
        case .sizePreset(let preset):
            host.applyFrameSizePreset(id: card.id, preset: preset)
        case .sizeCommit(let w, let h):
            host.commitFrameSize(id: card.id, w: w, h: h)
        case .titleCommit(let label):
            host.commitFrameTitle(id: card.id, label: label)
        case .navigate(let url):
            host.navigateFrame(id: card.id, url: url)
        case .dragStart(let cx, let cy):
            host.beginFrameDrag(id: card.id, clientX: cx, clientY: cy)
        case .dragMove(let cx, let cy):
            host.updateFrameDrag(clientX: cx, clientY: cy)
        case .dragEnd:
            host.endFrameDrag()
        case .resizeStart(let mode, let cx, let cy):
            host.beginFrameResize(id: card.id, mode: mode, clientX: cx, clientY: cy)
        case .resizeMove(let cx, let cy):
            host.updateFrameResize(clientX: cx, clientY: cy)
        case .resizeEnd:
            host.endFrameResize()
        case .linkDragStart(let side, let cx, let cy):
            host.beginLinkDrag(fromId: card.id, side: side,
                               clientX: cx, clientY: cy)
        case .linkDragMove(let cx, let cy):
            host.updateLinkDrag(clientX: cx, clientY: cy)
        case .linkDragEnd(let cx, let cy):
            host.endLinkDrag(clientX: cx, clientY: cy)
        }
    }
}

/// Forwards script messages to a handler it does not retain, so a
/// `WKUserContentController` never keeps the bridge (and, through it, the
/// whole document view tree) alive.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?
    init(_ target: any WKScriptMessageHandler) { self.target = target }
    nonisolated func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { target?.userContentController(uc, didReceive: message) }
    }
}
