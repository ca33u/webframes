import AppKit
import os
import WebKit

/// Message broker for per-frame WKWebViews.
///
/// Phase 6e Step 70e retired the canvas WKWebView, so this class now
/// owns exactly one WKWebView channel — `wfFrame`. A synthetic
/// `handleCanvasMessage(_:)` survives as a test entry point (the
/// Phase 6d workspace-envelope tests drive it directly without a real
/// WKWebView), but in production no WKWebView posts on a "canvas"
/// channel anymore.
final class NativeBridge: NSObject, WKScriptMessageHandler {

    static let frameChannelName = "wfFrame"

    /// Native renderer for frame cards. Setting this hands the layer to
    /// `FrameManager` so it can add/remove per-frame card views as the
    /// workspace changes.
    weak var frameLayer: FrameLayerView? {
        didSet { if let layer = frameLayer { frameManager.hostLayer = layer } }
    }

    /// Back-pointer to the document this bridge is bound to. Kept as a
    /// weak ref so the test-only `handleCanvasMessage(_:)` envelope
    /// dispatcher can reach `document.workspace` — no production path
    /// reads this anymore.
    weak var document: WebFramesDocument?

    /// Back-pointer to the view host. Used by `handleFrameMessage` to
    /// hand native-inspected DOM context + screenshots back to the
    /// host's pin-draft flow.
    weak var canvasHost: CanvasHost?

    private lazy var frameManager = FrameManager(bridge: self)

    func astraWebView(id: String) -> WKWebView? { frameManager.webView(for: id) }

    /// Releases every frame's WKWebView. Called from `CanvasHost.tearDown()`.
    func destroyAllFrames() { frameManager.destroyAllFrames() }

    /// Cache of the most recent raw `FrameCardState` pushed from JS
    /// (`frame-card-set` envelope) per frame id — with the `selected`
    /// bit always stripped to `false`. Selection is Swift-authoritative
    /// under Phase 6e Step 3 (see `CanvasHost.selectedFrameId`), so we
    /// can't trust whatever flag JS sends (which, under native, JS
    /// derives from a DOM `.fc.sel` class that's now unset). The cache
    /// lets us re-push chrome for a single frame when *only* the
    /// selection changes — `repaintFrameChrome(id:)` below — without a
    /// JS round-trip.
    ///
    /// Eviction: on `frame-destroy`. Keys not in a subsequent
    /// `frame-card-set` batch are kept until the frame is destroyed —
    /// JS always pushes every live frame on every `dots()` tick, so a
    /// missing id means either brand-new (no baseline yet, selection
    /// paint will race with the first JS push) or torn down.
    private var lastFrameCardState: [String: FrameCardState] = [:]

    /// Exposed to the host so it can bulk-hide/show frames around modal
    /// presentation. The frame layer sits above the canvas WKWebView, so
    /// without this the modal's darkening backdrop wouldn't cover frames.
    func setFrameOrder(_ ids: [String]) { frameManager.setFrameOrder(ids) }

    func setAllFramesVisible(_ visible: Bool) {
        frameManager.setAllVisible(visible)
    }

    /// Push a per-frame pin list into the frame's `PinOverlayView`.
    /// Used by the Phase 6e Step 0 workspace observer path on
    /// `CanvasHost` — that path iterates `workspace.frames` and calls
    /// this once per frame so pin dots stay in sync with the
    /// authoritative annotation array even when JS hasn't pushed yet.
    /// Wraps `FrameManager.setPins` so `frameManager` stays private.
    func setFramePins(frameId: String, pins: [PinModel]) {
        frameManager.setPins(frameId: frameId, pins: pins)
    }

    /// Push a frame's visual card rect + logical page viewport + chrome
    /// holes directly to the frame manager. Phase 6e Step 7 entry point —
    /// `CanvasHost.refreshNativeViewsFromWorkspace` computes the rect
    /// natively from the workspace + viewport instead of waiting for JS
    /// `wfSyncFrameRects` to post a `frame-set-rect` envelope. Wraps
    /// `FrameManager.setCardRect` so `frameManager` stays private.
    func setFrameCardRect(id: String, cardRect: CGRect,
                          logicalSize: CGSize, holes: [FrameManager.Hole]) {
        frameManager.setCardRect(id: id, cardRect: cardRect,
                                 logicalSize: logicalSize, holes: holes)
    }

    /// Phase 6e Step 70c: native frame-WKWebView lifecycle. The workspace
    /// observer in `CanvasHost` diffs `workspace.frames` against its own
    /// `liveFrameIds` set and funnels adds/removes through these wrappers
    /// — replacing the JS `renderFrame` → `NativeAPI.createFrame` and
    /// `applyDocState` → `NativeAPI.destroyFrame` hops. Id-guarded inside
    /// `FrameManager` so double-creation is a silent no-op; same for
    /// destroy-on-missing-id.
    func createFrameView(id: String, url: String,
                         cardRect: CGRect, logicalSize: CGSize) {
        frameManager.createFrame(id: id, url: url,
                                 cardRect: cardRect,
                                 logicalSize: logicalSize)
    }

    func destroyFrameView(id: String) {
        frameManager.destroyFrame(id: id)
        lastFrameCardState.removeValue(forKey: id)
    }

    /// Webview history back. Silently no-ops when nothing to go back to.
    func goBackInFrameView(id: String) {
        frameManager.goBack(id: id)
    }

    /// Load a new URL in the frame's webview. Called from the address-bar
    /// commit path on the frame's header.
    func loadURLInFrameView(id: String, url: String) {
        frameManager.load(id: id, url: url)
    }

    /// Update the live URL shown in the card's address-bar field, without
    /// touching `WorkspaceStore`. Navigation within a frame is runtime
    /// state, not persistent document content — the workspace keeps the
    /// *initial* URL it was created with. Pushes a new chrome baseline so
    /// the title reflects the current document.
    func setFrameLiveURL(id: String, url: String) {
        guard let prev = lastFrameCardState[id] else { return }
        guard prev.url != url else { return }
        let updated = FrameCardState(
            id: prev.id, num: prev.num, label: prev.label,
            sourceLabel: prev.sourceLabel, url: url,
            w: prev.w, h: prev.h,
            selected: prev.selected, dropTarget: prev.dropTarget,
            annotationMode: prev.annotationMode, isImage: prev.isImage,
            canRestoreLive: prev.canRestoreLive
        )
        lastFrameCardState[id] = updated
        frameManager.setCardChrome(id: id, state: renderCardState(for: id))
    }

    /// Phase 6e Step 70e polish #5b: native image-frame rendering. The
    /// pre-70e JS DOM `<img>` path went away with `index.html`; this
    /// pass-through lets `CanvasHost`'s observer feed the base64 data
    /// URL (from `FrameModel.extras["imgUrl"]`) into `FrameManager`,
    /// which in turn loads a minimal HTML shell wrapping the image in
    /// the per-frame WKWebView. Called right after `createFrameView`
    /// for any frame with `isImage == true`.
    func loadImageInFrame(id: String, dataURL: String) {
        frameManager.loadImageDataURL(id: id, dataURL: dataURL)
    }

    /// Phase 6e Step 6: native callers (currently `CanvasHost.beginAnnotationPress`)
    /// dispatch a typed message to a specific frame webview. Thin
    /// wrapper over `FrameManager.postToFrame` so the frame manager
    /// reference stays private.
    func postToFrame(id: String, payload: [String: Any]) {
        frameManager.postToFrame(id: id, payload: payload)
    }

    /// Phase 6e Step 70e: native dock annotation-mode toggle. Thin
    /// pass-through so `CanvasHost.performDockToggleAnnotation` can
    /// arm / disarm the per-frame inspect-on-hover highlight without
    /// reaching into the private `frameManager`. Previously the same
    /// flag flowed in through the `annotation-mode` canvas envelope;
    /// with dock actions Swift-owned the envelope path is dead.
    func setFramesAnnotationMode(_ on: Bool) {
        frameManager.setAnnotationMode(on)
    }

    /// Re-render a single frame's chrome from the cached JS baseline
    /// plus the current Swift-owned selection flag. Called by
    /// `CanvasHost.selectFrame(_:)` / `clearFrameSelectionIfNeeded()`
    /// (Phase 6e Step 3) to paint selection transitions immediately,
    /// without waiting for the next JS `dots()` tick.
    ///
    /// No-op if the id has no cached baseline — a brand-new frame
    /// hasn't gone through `frame-card-set` yet, and trying to paint a
    /// half-built FrameCardState here would clobber the card with
    /// zeros. The very next JS push will carry the full baseline and
    /// the selection overlay will kick in then.
    func repaintFrameChrome(id: String) {
        guard lastFrameCardState[id] != nil else { return }
        frameManager.setCardChrome(id: id, state: renderCardState(for: id))
    }

    /// Native replacement for the retired JS `pushFrameCardsToNative`
    /// envelope. `CanvasHost.refreshNativeViewsFromWorkspace` calls this
    /// once per workspace frame so the card's header (num, label, source
    /// pill, viewport fields, image/annotation flags) mirrors the
    /// authoritative workspace state. We store the baseline here so
    /// `repaintFrameChrome` can overlay selection/drop-target flips
    /// without a workspace round-trip, and immediately apply the merged
    /// state to the card.
    func setFrameCardBaseline(
        id: String,
        num: Int,
        label: String,
        sourceLabel: String,
        url: String,
        w: CGFloat,
        h: CGFloat,
        annotationMode: Bool,
        isImage: Bool,
        canRestoreLive: Bool
    ) {
        let baseline = FrameCardState(
            id: id, num: num, label: label, sourceLabel: sourceLabel,
            url: url, w: w, h: h, selected: false, dropTarget: false,
            annotationMode: annotationMode, isImage: isImage,
            canRestoreLive: canRestoreLive
        )
        lastFrameCardState[id] = baseline
        frameManager.setCardChrome(id: id, state: renderCardState(for: id))
    }

    /// Overlay Swift-owned ephemeral flags (selection, link-drag drop
    /// target) onto a frame's cached baseline chrome. The cache stores
    /// `selected: false` / `dropTarget: false` always — both flags are
    /// now owned by `CanvasHost` (Steps 3 and 5), so the overlay here
    /// is authoritative. Drop-target highlight wins over selection in
    /// `FrameCardView.setChrome` already — that precedence isn't
    /// touched by this overlay.
    private func renderCardState(for id: String) -> FrameCardState {
        let baseline = lastFrameCardState[id]
            ?? FrameCardState(id: id, num: 0, label: "", sourceLabel: "",
                              url: "", w: 0, h: 0, selected: false,
                              dropTarget: false, annotationMode: false,
                              isImage: false, canRestoreLive: false)
        let isSelected   = canvasHost?.selectedFrameIDs.contains(id) == true
        let isDropTarget = canvasHost?.linkDragTargetId   == id
        guard isSelected != baseline.selected
              || isDropTarget != baseline.dropTarget else { return baseline }
        return FrameCardState(
            id: baseline.id,
            num: baseline.num,
            label: baseline.label,
            sourceLabel: baseline.sourceLabel,
            url: baseline.url,
            w: baseline.w,
            h: baseline.h,
            selected: isSelected,
            dropTarget: isDropTarget,
            annotationMode: baseline.annotationMode,
            isImage: baseline.isImage,
            canRestoreLive: baseline.canRestoreLive
        )
    }

    // MARK: - WKScriptMessageHandler

    nonisolated func userContentController(
        _ uc: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated {
            switch message.name {
            case Self.frameChannelName:
                // Defence in depth: the script is main-frame only, but a page
                // could still expose the handler to a child frame.
                guard message.frameInfo.isMainFrame else {
                    Log.bridge.error("frame message from a child frame dropped")
                    return
                }
                handleFrameMessage(message.body, from: message.webView)
            default:
                Log.bridge.error("unknown script channel: \(message.name, privacy: .public)")
            }
        }
    }

    // MARK: - Workspace-envelope dispatch (test entry point)

    /// Dispatches a single typed envelope into the workspace store. The
    /// Phase 6d envelope tests (`BridgeAnnotationEnvelopeTests`,
    /// `BridgeLinkEnvelopeTests`, `BridgeFrameEnvelopeTests`) drive this
    /// directly without spinning up a real WKWebView — each test builds
    /// a dict and calls `bridge.handleCanvasMessage([...])`.
    ///
    /// In production nothing calls this anymore: Phase 6e Step 70e
    /// retired the canvas WKWebView, and every native UI caller mutates
    /// `workspace` directly. The remaining cases here are the subset of
    /// envelopes the tests cover — if a case is missing, the test would
    /// have failed with "unknown envelope" back when this was an
    /// end-to-end bridge; now it would just be a no-op.
    func handleCanvasMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String else {
            Log.bridge.error("canvas message dropped: missing type")
            return
        }

        switch type {
        case "ann-create":
            guard let annDict = dict["ann"] as? [String: Any],
                  let model = AnnotationModel(jsonValue: JSONValue.from(annDict)) else {
                Log.bridge.error("ann-create: malformed payload")
                return
            }
            document?.workspace.createAnnotation(model)

        case "ann-update":
            guard let id = dict["id"] as? String else {
                Log.bridge.error("ann-update: missing id")
                return
            }
            let comment = dict["comment"] as? String
            let color   = dict["color"]   as? String
            let edits: [String: String]? = (dict["edits"] as? [String: Any]).map {
                var out: [String: String] = [:]
                for (k, v) in $0 {
                    if let s = v as? String { out[k] = s }
                    else if let n = v as? NSNumber { out[k] = "\(n)" }
                }
                return out
            }
            document?.workspace.updateAnnotation(
                id: id, comment: comment, color: color, edits: edits
            )

        case "ann-delete":
            guard let id = dict["id"] as? String else {
                Log.bridge.error("ann-delete: missing id")
                return
            }
            document?.workspace.deleteAnnotation(id: id)

        case "link-create":
            guard let linkDict = dict["link"] as? [String: Any],
                  let model = LinkModel(jsonValue: JSONValue.from(linkDict)) else {
                Log.bridge.error("link-create: malformed payload")
                return
            }
            document?.workspace.createLink(model)

        case "link-delete":
            guard let id = dict["id"] as? String else {
                Log.bridge.error("link-delete: missing id")
                return
            }
            document?.workspace.deleteLink(id: id)

        case "frame-model-create":
            guard let frameDict = dict["frame"] as? [String: Any],
                  let model = FrameModel(jsonValue: JSONValue.from(frameDict)) else {
                Log.bridge.error("frame-model-create: malformed payload")
                return
            }
            document?.workspace.createFrame(model)

        case "frame-move":
            guard let id = dict["id"] as? String else {
                Log.bridge.error("frame-move: missing id"); return
            }
            let x = (dict["x"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            let y = (dict["y"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            document?.workspace.moveFrame(id: id, to: CGPoint(x: x, y: y))

        case "frame-resize":
            guard let id = dict["id"] as? String else {
                Log.bridge.error("frame-resize: missing id"); return
            }
            let w = (dict["w"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            let h = (dict["h"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            document?.workspace.resizeFrame(id: id, size: CGSize(width: w, height: h))

        case "frame-rename":
            guard let id = dict["id"] as? String else {
                Log.bridge.error("frame-rename: missing id"); return
            }
            let label = (dict["label"] as? String) ?? ""
            document?.workspace.renameFrame(id: id, label: label)

        case "frame-delete":
            guard let id = dict["id"] as? String else {
                Log.bridge.error("frame-delete: missing id"); return
            }
            document?.workspace.deleteFrame(id: id)

        default:
            Log.bridge.error("unknown envelope type: \(type, privacy: .public)")
        }
    }

    // MARK: - Frame → Native

    /// Handles a message posted from a per-frame WKWebView on the
    /// `wfFrame` channel. Phase 6e Step 70e: with the canvas WKWebView
    /// gone, every surviving message type is resolved natively here —
    /// nothing is forwarded to JS.
    ///
    /// Recognized types:
    ///
    ///   - `wf-scroll`: the injected per-frame bridge posts the page's
    ///     scroll offset on every `scroll` event. We feed it straight
    ///     into `FrameManager.setPinScroll`, which translates the
    ///     overlay's pin positions. Used to round-trip through JS via
    ///     `NativeAPI.setFramePinScroll`; same sink, one fewer hop.
    ///
    ///   - `wf-dom-context` / `wf-dom-screenshot`: replies to a
    ///     native-originated `wf-inspect` click (see
    ///     `CanvasHost.beginAnnotationPress`). Keyed by `annId`. If the
    ///     id matches a pin draft on `canvasHost`, we route the reply
    ///     directly to the host. Anything else (stray replies from
    ///     reloaded frames, unrecognized annIds) is dropped — there is
    ///     no browser-fallback preview path anymore.
    ///
    /// Unknown types are logged and dropped.
    /// Element context and screenshots are saved into the document and sent
    /// to Codex, so a page cannot push arbitrary amounts of data through them.
    static let maxContextBytes = 64 * 1024
    static let maxScreenshotBytes = 2 * 1024 * 1024
    static let screenshotPrefix = "data:image/png;base64,"

    static func contextFitsLimit(_ context: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(context),
              let data = try? JSONSerialization.data(withJSONObject: context) else { return false }
        return data.count <= maxContextBytes
    }

    static func acceptsScreenshot(_ dataURL: String) -> Bool {
        dataURL.hasPrefix(screenshotPrefix) && dataURL.utf8.count <= maxScreenshotBytes
    }

    private func handleFrameMessage(_ body: Any, from webView: WKWebView?) {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String,
              let frameId = frameManager.frameId(for: webView) else { return }

        switch type {
        case "wf-scroll":
            let x = (dict["scrollX"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            let y = (dict["scrollY"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
            frameManager.setPinScroll(frameId: frameId, x: x, y: y)

        case "wf-nav":
            // The message only signals an SPA navigation; the URL shown on the
            // card comes from WebKit, never from page-supplied text.
            guard let url = webView?.url?.absoluteString, !url.isEmpty else { return }
            setFrameLiveURL(id: frameId, url: url)

        case "wf-dom-context":
            guard let annId = dict["annId"] as? String,
                  let host = canvasHost,
                  host.pinDrafts[annId] != nil else { return }
            let ctxValue: JSONValue
            if let ctxDict = dict["context"] as? [String: Any], Self.contextFitsLimit(ctxDict) {
                ctxValue = JSONValue.from(ctxDict)
            } else {
                ctxValue = .null
            }
            host.handleInspectContext(annId: annId, contextJSON: ctxValue)

        case "wf-dom-screenshot":
            guard let annId = dict["annId"] as? String,
                  let host = canvasHost,
                  host.pinDrafts[annId] != nil,
                  let url = dict["screenshot"] as? String,
                  Self.acceptsScreenshot(url) else { return }
            host.handleInspectScreenshot(annId: annId, dataURL: url)

        default:
            Log.bridge.error("frame(\(frameId, privacy: .public)): unknown type \(type, privacy: .public)")
        }
    }
}
