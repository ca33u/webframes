import AppKit
import os
import UniformTypeIdentifiers

/// Root NSView hosting the native canvas backdrop, frame layer, link layer,
/// dock, annotation panel, and a native titlebar drag strip.
///
/// Each `WebFramesDocument` owns exactly one `CanvasHost`. The host
/// subscribes to the document's `WorkspaceStore` and rebuilds its native
/// views on every mutation. Phase 6e Step 70e retired the canvas
/// WKWebView + `doc-load-state` / `doc-state-changed` round-trip; the
/// workspace store is now the sole source of truth.
final class CanvasHost: NSView, AddFrameModalDelegate,
                         AnnotationPanelDelegate, PinEditorDelegate,
                         LinkLayerViewDelegate, DockViewDelegate,
                         FramesSidebarDelegate {

    override var acceptsFirstResponder: Bool { true }

    /// Native dot-grid renderer. Paints the whole canvas backdrop; the
    /// per-frame WKWebViews and the native link layer sit above it. This
    /// used to live below a transparent canvas WKWebView running JS — that
    /// webview is gone as of Phase 6e Step 70e, so the backdrop is now the
    /// bottom of the z-order.
    let canvasBackdrop: CanvasBackdropView
    let frameLayer: FrameLayerView
    /// Native bezier renderer for the established links between frames.
    /// Sits ABOVE `frameLayer` so arrows appear on top of frames — this
    /// matches the old CSS behavior where the `.dc` 2D canvas was painted
    /// on top of `.cv`. `LinkLayerView` is a passive painter (hitTest
    /// returns nil): clicks, hover, delete are still owned by JS through
    /// Phase 6b. See `LinkLayerView` for the narrowing rationale.
    let linkLayer: LinkLayerView
    // `titlebarDragView` was removed in sidebar-refactor Step 3 follow-up
    // (2026-05-03): the `NSToolbar` configured by `DocumentWindowController`
    // with `.unified` style + `.flexibleSpace` makes the entire title band
    // draggable for free, plus `fullSizeContentView` + transparent titlebar
    // — no need for a host-owned 38pt drag strip across the canvas top.
    let dock: DockView
    // Phase 6e sidebar-refactor Step 3 (2026-04-21 evening): the top-left
    // brand mark (`logo.svg` + "web frames" wordmark) used to live on the
    // host as `logoView` / `logoLabel` / `logoStack`, pinned 92pt from the
    // leading edge just past the traffic lights. After Step 3 that stack
    // is centered at the top of the window instead (owned by
    // `DocumentWindowController`) so the brand reads as a window-level
    // mark rather than a host-local corner label. The `loadRendererLogo()`
    // helper below stayed public so the window controller can reuse the
    // same image-load path without re-probing the bundle.
    //
    // Step 3 follow-up (2026-05-03): the `titlebarDragView` (a 38pt
    // transparent strip pinned to the top of canvasHost so users could
    // drag the window from above the canvas) is also gone. NSToolbar in
    // `.unified` style with `.flexibleSpace` makes the entire title band
    // window-draggable for free.
    let bridge: NativeBridge
    /// Native annotation panel. Always in the view hierarchy — slides/fades
    /// off to the right when not visible. Sits above `frameLayer`, so
    /// per-frame WKWebViews are naturally occluded by the panel without any
    /// chrome-hole mask round-trip.
    let annotationPanel: AnnotationPanel
    /// Native left-side project navigator (Phase 6e polish #6). Lists every
    /// frame in the workspace with a type badge. Passive — rows emit
    /// `didSelectFrameID:` through `FramesSidebarDelegate`, which we map to
    /// `selectFrame(_:)` + a viewport pan so the selected frame lands at the
    /// visible canvas center. Net-new affordance on top of the all-native
    /// canvas; no JS analogue existed pre-migration.
    ///
    /// Phase 6e sidebar-refactor Step 1
    /// --------------------------------
    /// The sidebar used to be a child view of `CanvasHost` with its own
    /// slide-in animation. It now lives inside an `NSSplitViewItem(.sidebar)`
    /// owned by `DocumentSplitViewController` — this reference is therefore
    /// `weak var` and optional: the split VC wires it in during its own init
    /// via `canvasVC.canvasHost.sidebar = sidebarVC.sidebar`. The host uses
    /// it only to push selection changes that happen outside the workspace
    /// store (see `selectFrame(_:)` / `clearFrameSelectionIfNeeded`).
    weak var sidebar: FramesSidebar? {
        didSet {
            sidebar?.setSelectedFrameID(selectedFrameId)
            if let source = monitoredWebSource {
                sidebar?.setSourceStatus(webSourceStatus, sourceID: source.id)
            }
        }
    }
    weak var document: WebFramesDocument?

    /// Native add-frame modal. Built lazily on first invocation — the
    /// modal is large enough that we don't want to pay for it in every
    /// document-open. Reset and reused across opens.
    private var addFrameModal: AddFrameModal?

    /// Native pin-editor modal. Lazily constructed — same reasoning as the
    /// add-frame modal. Re-added/removed from the view hierarchy on every
    /// open/close so when hidden it doesn't darken frames.
    private var pinEditorModal: PinEditorModal?

    /// Handle to the workspace-store observer installed by
    /// `installWorkspaceObserver()`. Holding it keeps the registration
    /// alive; on host tear-down the `Subscription`'s `deinit` unregisters
    /// the callback (see `WorkspaceStore.Subscription`). Phase 6e Step 0
    /// lands this path additively — the JS push paths still run in
    /// parallel until Step C strips the JS round-trip.
    private var workspaceSubscription: WorkspaceStore.Subscription?
    private var webSourceMonitorTask: Task<Void, Never>?
    private var monitoredWebSource: ProjectWebSource?
    private var webSourceStatus: FramesSidebar.SourceStatus = .checking
    private var lastWebSourceOnline: Bool?
    let serverDiscovery = LocalServerDiscovery()
    private var importServerStartPending = false
    private var managedServerProcess: Process?
    private var managedServerPipe: Pipe?
    private var managedServerScopedURL: URL?
    private var managedServerOutput = ""
    private var managedServerSourceID: String?
    private var stoppingManagedServer = false
    private var pendingServerRestart: ProjectMapSnapshot?

    /// Phase 6e Step 70c: set of frame ids currently alive inside
    /// `FrameManager`. The workspace observer diffs this against
    /// `workspace.frames` on every mutation to drive native
    /// `createFrameView` / `destroyFrameView` — superseding the JS
    /// `renderFrame` → `NativeAPI.createFrame` hop. Seeded empty;
    /// the first `observe(_:)` callback populates it with whatever
    /// the on-disk payload carries.
    private var liveFrameIds: Set<String> = []
    /// Tracks renderer kind as well as identity. Freezing/restoring keeps
    /// the same frame id, so a kind change must rebuild its inner WKWebView.
    private var liveFrameImageKinds: [String: Bool] = [:]
    private let snapshotCaptureService = AstraCaptureService()
    private var snapshotCapturesInProgress = Set<String>()

    // MARK: - Link ephemeral state (Phase 6e Step 2)
    //
    // Native-owned selection + hover for link curves. These are UI-only
    // (not persisted, not undoable) so they live here rather than in
    // `WorkspaceStore`. `LinkLayerView` emits click/hover deltas through
    // the delegate callbacks below; we record the new id and trigger a
    // link-only repaint so the selected ring / hover color updates
    // without rebuilding every annotation and pin overlay.
    //
    // Both the workspace observer path and the legacy `links-set`
    // envelope handler in `NativeBridge` read these via `linkFlags(for:)`
    // when constructing `NativeLink` structs, so whichever path fires
    // last produces the same flags and there's no race.
    private(set) var selectedLinkId: String?
    private(set) var hoveredLinkId: String?

    // MARK: - Frame ephemeral state (Phase 6e Step 3)
    //
    // Native-owned frame selection (what used to be the JS `.fc.sel`
    // class on the DOM frame shell). UI-only, not persisted, not
    // undoable — lives here, not in `WorkspaceStore`. `FrameCardView`
    // emits `.select` intents through the `FrameCardDelegate` chain in
    // `FrameManager`, which forwards to `selectFrame(_:)` below.
    //
    // Authority: Swift owns the flag under `NativeAPI.available`. The JS
    // `pushFrameCardsToNative` still fires (for label / sourceLabel /
    // drop-target state), but its `selected` bit is ignored at the
    // bridge handler — `NativeBridge.applySelectionFlag(to:)` overlays
    // `canvasHost.selectedFrameId` so Swift's selection always wins
    // regardless of what JS says. Avoids a race between the JS DOM
    // `.fc.sel` class (which is unset under native) and the Swift
    // property.
    //
    // Frame selection and link selection are mutually exclusive: a
    // fresh frame click clears the link selection and vice-versa, so
    // Delete/Backspace has an unambiguous target.
    private(set) var selectedFrameId: String?
    private(set) var selectedFrameIDs: [String] = []
    var onFrameSelectionChanged: (() -> Void)?

    // MARK: - Frame drag/resize ephemeral state (Phase 6e Step 4)
    //
    // Native ownership of the intermediate drag/resize preview. Before
    // Step 4 we forwarded `.dragMove`/`.resizeMove` to JS, which mutated
    // JS-local `f.x/y/w/h` and redrew — Swift's workspace only saw the
    // final commit at gesture end. Now we track a transient overlay
    // here; `frameWithLivePreview(_:)` applies it during every
    // observer-driven refresh so the card rect, link anchors, and pin
    // overlays stay pinned to the dragging/resizing frame without any
    // round-trip to the workspace. The workspace only sees the final
    // position/size at `.dragEnd` / `.resizeEnd`, same commit-boundary
    // policy as Phase 6d item #5.
    //
    // UI-only, not persisted: matches the `panDragState` / `selectedFrameId`
    // pattern — gesture state lives on the host, not in the store.
    struct FrameDragState {
        let id: String
        let startClient: NSPoint
        let origins: [String: CGPoint]
        let anchorX: CGFloat
        let anchorY: CGFloat
        var currentX: CGFloat
        var currentY: CGFloat
        /// Shift/⌘-press on an already selected frame: removed from the
        /// selection only if the gesture ends as a click, not a drag.
        var deselectOnClick = false
    }
    struct FrameResizeState {
        let id: String
        /// `"bottom"` (height-only handle on the card's bottom edge) or
        /// `"corner"` (both-axis handle on the bottom-right). Matches the
        /// string FrameCardView emits — keeping the shape identical to
        /// what JS consumed avoids having to teach either side a new
        /// vocabulary for what's fundamentally one gesture with two
        /// flavors.
        let mode: String
        let startClient: NSPoint
        let anchorW: CGFloat
        let anchorH: CGFloat
        var currentW: CGFloat
        var currentH: CGFloat
    }
    private(set) var frameDragState: FrameDragState?
    private(set) var frameResizeState: FrameResizeState?

    /// Minimum frame size in world-space points. Matches the JS
    /// `wfFrameApplySize` clamp (`Math.max(200, nextW/H)`) — resizing
    /// below this leaves the user without enough card chrome to grip a
    /// re-resize, so it's clamped at the gesture layer rather than only
    /// at the workspace commit boundary.
    private static let minFrameDim: CGFloat = 200

    /// Flip a `clientY` emitted by `FrameCardView` (window / contentView
    /// coords, bottom-left origin because `CanvasHost.isFlipped` is
    /// false) into the top-left coordinate system used by
    /// `FrameModel.x/y`, `workspace.viewport.panX/panY`, and every
    /// `frameAnchor` / `worldPoint` call downstream. `FrameCardView`
    /// sources the coord from `window?.mouseLocationOutsideOfEventStream`
    /// which is the window's base (bottom-left) coord space — and since
    /// `window.contentView === canvasHost`, flipping against
    /// `canvasHost.bounds.height` is the exact transform.
    ///
    /// Same rationale as `DocumentWindowController.handleCanvasGesture`
    /// flipping `locInHost.y` to `anchorY = canvasHost.bounds.height -
    /// locInHost.y` for the zoom-around-cursor math. Applied at the
    /// entry of every gesture-dispatch method below so internal state
    /// (`startClient`, `currentWorld`, …) is always in top-left.
    private func flipClientY(_ clientY: CGFloat) -> CGFloat {
        bounds.height - clientY
    }

    /// Start a frame drag. Called by `FrameManager.frameCard(_:didEmit:)`
    /// on `.dragStart` — intercepted before the forward-to-canvas path.
    /// Seeds selection so `frameDragState?.id` matches what the user
    /// sees highlighted on the card chrome.
    func beginFrameDrag(id: String, clientX: CGFloat, clientY: CGFloat) {
        guard let f = document?.workspace.frame(id: id) else { return }
        // The same press may have Shift/⌘-toggled this frame out of a group
        // selection. Like Figma, a drag moves the whole group; the frame
        // leaves the selection only if the press ends without moving.
        var deselectOnClick = false
        if !selectedFrameIDs.contains(id), let pending = pendingAdditiveDeselect, pending.id == id,
           pending.event == NSApp.currentEvent?.eventNumber {
            setFrameSelection(selectedFrameIDs + [id])
            deselectOnClick = true
        }
        pendingAdditiveDeselect = nil
        guard selectedFrameIDs.contains(id) else { return }
        let cy = flipClientY(clientY)
        frameDragState = FrameDragState(
            id: id,
            startClient: NSPoint(x: clientX, y: cy),
            origins: Dictionary(uniqueKeysWithValues: (document?.workspace.frames ?? []).filter { selectedFrameIDs.contains($0.id) }.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) }),
            anchorX: f.x, anchorY: f.y,
            currentX: f.x, currentY: f.y,
            deselectOnClick: deselectOnClick
        )

    }

    /// Per-tick drag update. Computes new world-space origin from the
    /// anchor so dropped events / coarse sampling don't drift. Pushes a
    /// full refresh so link anchors and pin overlays track the card.
    func updateFrameDrag(clientX: CGFloat, clientY: CGFloat) {
        guard var state = frameDragState,
              let workspace = document?.workspace else { return }
        let scale = workspace.viewport.scale
        guard scale > 0 else { return }
        let cy = flipClientY(clientY)
        state.currentX = state.anchorX + (clientX - state.startClient.x) / scale
        state.currentY = state.anchorY + (cy - state.startClient.y) / scale
        frameDragState = state
        scheduleGesturePreview()
    }

    /// Finish a frame drag. Commits the final position to the workspace
    /// if it moved; otherwise just clears the overlay and repaints to
    /// drop any residual preview geometry. `moveFrame` is itself a
    /// no-op for zero deltas, so a click-without-drag costs a single
    /// cheap store call and no mutation.
    func endFrameDrag() {
        guard let state = frameDragState else { return }
        frameDragState = nil
        endGesturePreview()
        let moved = (state.currentX != state.anchorX) || (state.currentY != state.anchorY)
        if moved {
            moveSelection(to: state.origins.mapValues {
                CGPoint(x: $0.x + state.currentX - state.anchorX, y: $0.y + state.currentY - state.anchorY)
            }, action: "Move Frames")
        } else if state.deselectOnClick {
            // A Shift/⌘-click (no drag) on a selected frame deselects it.
            setFrameSelection(selectedFrameIDs.filter { $0 != state.id })
            refreshNativeViewsFromWorkspace()
        } else {
            // No workspace mutation → no observer fire → manually
            // refresh so the card rect reverts from the (no-op) overlay
            // back to the baseline `f.x/f.y` path.
            refreshNativeViewsFromWorkspace()
        }
    }

    /// Start a frame resize. `mode` is `"bottom"` or `"corner"` —
    /// matches the string `FrameCardView` emits on the corresponding
    /// handle mousedown.
    func beginFrameResize(id: String, mode: String,
                          clientX: CGFloat, clientY: CGFloat) {
        guard let f = document?.workspace.frame(id: id) else { return }
        let cy = flipClientY(clientY)
        frameResizeState = FrameResizeState(
            id: id,
            mode: mode,
            startClient: NSPoint(x: clientX, y: cy),
            anchorW: f.w, anchorH: f.h,
            currentW: f.w, currentH: f.h
        )
    }

    /// Per-tick resize update. `bottom` mode constrains width; `corner`
    /// moves both axes. Clamps to `minFrameDim` on both axes so the
    /// live preview matches what the commit boundary will persist.
    func updateFrameResize(clientX: CGFloat, clientY: CGFloat) {
        guard var state = frameResizeState,
              let workspace = document?.workspace else { return }
        let scale = workspace.viewport.scale
        guard scale > 0 else { return }
        let cy = flipClientY(clientY)
        let dx = (clientX - state.startClient.x) / scale
        let dy = (cy - state.startClient.y) / scale
        let rawW: CGFloat = state.mode == "bottom" ? state.anchorW : state.anchorW + dx
        let rawH: CGFloat = state.anchorH + dy
        state.currentW = max(Self.minFrameDim, rawW).rounded()
        state.currentH = max(Self.minFrameDim, rawH).rounded()
        frameResizeState = state
        scheduleGesturePreview()
    }

    /// Finish a frame resize. Commits to the workspace if the size
    /// actually changed; otherwise refreshes to drop the overlay.
    func endFrameResize() {
        guard let state = frameResizeState else { return }
        frameResizeState = nil
        endGesturePreview()
        let changed = (state.currentW != state.anchorW) || (state.currentH != state.anchorH)
        if changed {
            document?.workspace.resizeFrame(
                id: state.id,
                size: CGSize(width: state.currentW, height: state.currentH)
            )
        } else {
            refreshNativeViewsFromWorkspace()
        }
    }

    /// Apply any in-flight drag/resize transient to a FrameModel. All
    /// native rendering paths (card rect, link anchors, pin overlay
    /// bounds) route through this so the visual stays pinned to the
    /// dragging/resizing frame between gesture start and commit.
    // MARK: - Gesture preview (drag / resize)
    //
    // A full refresh rebuilds the comments panel (decoding every comment
    // screenshot), pins, card chrome and every link route. Running it on
    // each mouse-move made dragging stutter on busy boards. While a frame is
    // dragged or resized only the affected cards and links are updated, at
    // most once per display frame; the commit on mouse-up refreshes the rest.
    private var gesturePreviewLink: CADisplayLink?
    private var gesturePreviewPending = false

    private func scheduleGesturePreview() {
        gesturePreviewPending = true
        guard gesturePreviewLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(flushGesturePreview(_:)))
        link.add(to: .main, forMode: .common)
        gesturePreviewLink = link
    }

    @objc private func flushGesturePreview(_ link: CADisplayLink) {
        guard gesturePreviewPending else { return }
        gesturePreviewPending = false
        refreshGesturePreview()
    }

    private func endGesturePreview() {
        gesturePreviewLink?.invalidate()
        gesturePreviewLink = nil
        gesturePreviewPending = false
        linkLayer.liveRouteIDs = nil
    }

    private func refreshGesturePreview() {
        guard let workspace = document?.workspace else { return }
        var moving = Set<String>()
        if let d = frameDragState { moving.formUnion(d.origins.keys) }
        if let r = frameResizeState { moving.insert(r.id) }
        guard !moving.isEmpty else { return }
        let scale = workspace.viewport.scale, px = workspace.viewport.panX, py = workspace.viewport.panY
        for base in workspace.frames where moving.contains(base.id) {
            let f = frameWithLivePreview(base)
            bridge.setFrameCardRect(
                id: f.id,
                cardRect: CGRect(x: f.x * scale + px, y: f.y * scale + py,
                                 width: (f.w + CardGeometry.chromeWidth) * scale,
                                 height: (f.h + CardGeometry.chromeHeight) * scale),
                logicalSize: CGSize(width: base.w, height: base.h),
                holes: [])
        }
        // Only links attached to a moving frame are re-routed per frame.
        linkLayer.liveRouteIDs = Set(workspace.links.filter { moving.contains($0.fromId) || moving.contains($0.toId) }.map(\.id))
        pushLinksFromWorkspace()
    }

    private func frameWithLivePreview(_ f: FrameModel) -> FrameModel {
        var copy = f
        if let d = frameDragState, let origin = d.origins[f.id] {
            copy.x = origin.x + d.currentX - d.anchorX
            copy.y = origin.y + d.currentY - d.anchorY
        }
        if let r = frameResizeState, r.id == f.id {
            copy.w = r.currentW
            copy.h = r.currentH
        }
        return copy
    }

    // MARK: - Link-drag ephemeral state (Phase 6e Step 5)
    //
    // In-flight link-drag gesture: the ghost bezier that follows the
    // cursor while the user drags out of a frame edge handle toward a
    // drop target. Mirrors the JS `linkDrag` object at index.html:340.
    // All coordinates kept in world-space — `LinkLayerView` applies the
    // scale/pan transform at paint time, identical to the established
    // link path.
    //
    // Commit-on-gesture-boundary: only `.linkDragEnd` touches
    // `workspace.createLink`. `.linkDragMove` ticks just repaint the
    // preview; the workspace never sees the transient. Matches the
    // policy used by Step 4 (frame drag/resize), Step 8 (pan), and
    // Phase 6d item #5 (commit-on-end).
    struct LinkDragState {
        let fromId: String
        let fromSide: LinkSide
        var currentWorld: CGPoint
        var targetId: String?
        var targetSide: LinkSide?
    }
    private(set) var linkDragState: LinkDragState?

    /// Drop-target highlight for the card under the link-drag cursor.
    /// `NativeBridge.renderCardState` overlays this onto the per-frame
    /// chrome so only Swift decides which card glows — JS no longer
    /// pushes `dropTarget` under native because the link-drag gesture
    /// itself is Swift-owned. Nil means no frame is currently a
    /// candidate target.
    var linkDragTargetId: String? { linkDragState?.targetId }

    /// Start a link-drag. Called from `FrameManager.frameCard(_:didEmit:)`
    /// on `.linkDragStart` — intercepted before the forward-to-canvas
    /// path. Clears any prior link selection so the ghost doesn't race
    /// with a selected-link highlight visually. Mirrors
    /// `case'link-drag-start'` at index.html:1348.
    func beginLinkDrag(fromId: String, side: String,
                       clientX: CGFloat, clientY: CGFloat) {
        guard document?.workspace.frame(id: fromId) != nil else { return }
        let fromSide = LinkSide(rawValue: side) ?? .defaultFrom
        let cy = flipClientY(clientY)
        let world = worldPoint(clientX: clientX, clientY: cy)
        linkDragState = LinkDragState(
            fromId: fromId,
            fromSide: fromSide,
            currentWorld: world,
            targetId: nil,
            targetSide: nil
        )
        // Clearing link selection mirrors the JS side-effect at
        // index.html:1353 — otherwise a previously-selected link would
        // stay stroked in sky-blue underneath the orange ghost, which
        // reads as two highlights competing at once.
        if selectedLinkId != nil { selectedLinkId = nil }
        if hoveredLinkId != nil  { hoveredLinkId  = nil }
        refreshPreview()
    }

    /// Per-tick link-drag update. Walks frames in reverse (z-order) to
    /// find a drop target whose card rect contains the cursor (in
    /// world-space, including border + titlebar so hover over the whole
    /// card reads as a target). Snaps to the nearest edge via
    /// `nearestFrameSide`, identical to JS. If no target, the ghost's
    /// far endpoint floats freely at the cursor.
    func updateLinkDrag(clientX: CGFloat, clientY: CGFloat) {
        guard var state = linkDragState,
              let workspace = document?.workspace else { return }
        let cy = flipClientY(clientY)
        let world = worldPoint(clientX: clientX, clientY: cy)
        if let target = frameAtWorldPoint(world, in: workspace.frames),
           target.id != state.fromId {
            let side = nearestFrameSide(of: target, toWorldPoint: world)
            state.currentWorld = frameAnchor(target, side: side)
            state.targetId = target.id
            state.targetSide = side
        } else {
            state.currentWorld = world
            state.targetId = nil
            state.targetSide = nil
        }
        let prevTargetId = linkDragState?.targetId
        linkDragState = state
        refreshPreview()
        // Drop-target chrome flip — only when the id actually changed,
        // so a normal float-over-empty-canvas tick doesn't thrash the
        // bridge. `renderCardState` reads `linkDragTargetId` lazily, so
        // a repaint on each side of the transition is all we need.
        if prevTargetId != state.targetId {
            if let prev = prevTargetId { bridge.repaintFrameChrome(id: prev) }
            if let next = state.targetId { bridge.repaintFrameChrome(id: next) }
        }
    }

    /// Finish a link-drag. Commits `workspace.createLink` iff a target
    /// was locked in at release; otherwise just clears the preview. No
    /// need to tear down selected/hovered state — Step 2's hit-testing
    /// will pick up the new link naturally on the next render pass.
    func endLinkDrag(clientX: CGFloat, clientY: CGFloat) {
        guard let state = linkDragState else { return }
        // Refresh once more so the drop target reflects the *up*
        // position — catches the case where the user releases between
        // two `.linkDragMove` ticks.
        updateLinkDrag(clientX: clientX, clientY: clientY)
        let final = linkDragState ?? state
        let prevTargetId = final.targetId
        linkDragState = nil
        linkLayer.setPreviewLink(nil)
        if let prev = prevTargetId {
            // Clear the drop-target glow on the previously-highlighted
            // card — regardless of whether the link committed, the
            // chrome flag has to release.
            bridge.repaintFrameChrome(id: prev)
        }
        guard let toId = final.targetId,
              let toSide = final.targetSide,
              toId != final.fromId,
              let workspace = document?.workspace else { return }
        let id = "ln\(Int(Date().timeIntervalSince1970 * 1000))\(UUID().uuidString.prefix(8))"
        let link = LinkModel(
            id: id,
            fromId: final.fromId,
            fromSide: final.fromSide,
            toId: toId,
            toSide: toSide
        )
        // `WorkspaceStore.createLink` re-validates (self-link,
        // duplicate endpoint, dangling frame) and no-ops on reject —
        // same defense-in-depth as the JS `addLink` pre-guard kept for
        // browser fallback.
        workspace.createLink(link)
    }

    /// Rebuild the `LinkLayerView` preview from the current
    /// `linkDragState`. Called after every start/update tick.
    private func refreshPreview() {
        guard let state = linkDragState,
              let workspace = document?.workspace,
              let fromFrame = workspace.frame(id: state.fromId) else {
            linkLayer.setPreviewLink(nil)
            return
        }
        // Live-preview overlay (Step 4) applies here too — if the user
        // is somehow dragging a link handle *while* another gesture
        // moves the anchor frame, the ghost should track the live
        // position. `frameWithLivePreview` is a no-op when no drag is
        // in flight for this id, so production cost is zero.
        let fromFramePreview = frameWithLivePreview(fromFrame)
        let fromAnchor = frameAnchor(fromFramePreview, side: state.fromSide)
        linkLayer.setPreviewLink(LinkPreview(
            from: fromAnchor,
            fromSide: state.fromSide,
            to: state.currentWorld,
            toSide: state.targetSide,
            isOverTarget: state.targetId != nil
        ))
    }

    /// Translate a client-space point (already in host-view top-left
    /// coords — callers flip via `flipClientY` at gesture entry) to
    /// world space. Mirrors JS `clientToWorld(cx, cy) →
    /// {(cx-px)/scale, (cy-py)/scale}`. `panX`/`panY` are stored in
    /// top-left space, so the math and the inputs match directly.
    private func worldPoint(clientX: CGFloat, clientY: CGFloat) -> CGPoint {
        guard let workspace = document?.workspace else {
            return CGPoint(x: clientX, y: clientY)
        }
        let scale = workspace.viewport.scale
        let px    = workspace.viewport.panX
        let py    = workspace.viewport.panY
        guard scale > 0 else { return CGPoint(x: clientX, y: clientY) }
        return CGPoint(x: (clientX - px) / scale,
                       y: (clientY - py) / scale)
    }

    /// First frame whose card rect (including border + titlebar)
    /// contains the given world-space point. Walks in reverse so the
    /// topmost card wins — matches JS `_wfDropTargetFromPoint` which
    /// relied on `elementFromPoint` returning the topmost DOM node.
    /// Uses the `frameWithLivePreview` overlay so an in-flight drag
    /// anchor is read from the transient, not the stale workspace.
    private func frameAtWorldPoint(_ p: CGPoint,
                                   in frames: [FrameModel]) -> FrameModel? {
        // `frames[0]` is drawn on top (FrameManager.setFrameOrder), like the
        // top row of a layers panel, so the first match is the visible one.
        for base in frames {
            let f = frameWithLivePreview(base)
            let totalW = f.w + CardGeometry.chromeWidth
            let totalH = f.h + CardGeometry.chromeHeight
            if p.x >= f.x, p.x <= f.x + totalW,
               p.y >= f.y, p.y <= f.y + totalH {
                return f
            }
        }
        return nil
    }

    /// Nearest edge (left / right / top / bottom) of a frame to a
    /// world-space point. Direct port of JS `nearestFrameSide` at
    /// index.html:373 — same geometry constants (f.w+2 / f.h+35) so
    /// snap behavior matches pixel-for-pixel.
    private func nearestFrameSide(of f: FrameModel,
                                  toWorldPoint p: CGPoint) -> LinkSide {
        let totalW = f.w + CardGeometry.chromeWidth
        let totalH = f.h + CardGeometry.chromeHeight
        let dLeft   = abs(p.x - f.x)
        let dRight  = abs(p.x - (f.x + totalW))
        let dTop    = abs(p.y - f.y)
        let dBottom = abs(p.y - (f.y + totalH))
        let distances: [(LinkSide, CGFloat)] = [
            (.left, dLeft), (.right, dRight),
            (.top, dTop),   (.bottom, dBottom),
        ]
        // JS uses Object.keys-order as the tiebreaker: left > right > top > bottom.
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .left
    }

    // MARK: - Pan-mode ephemeral state (Phase 6e Step 8)
    //
    // Space-held transient pan-cursor, V-locked persistent pan-cursor,
    // and the in-flight click-drag pan gesture. All UI-only, live here
    // rather than in `WorkspaceStore` — the persistent `panLocked` flag
    // is intentionally not on disk (matches JS: `let panLocked=false` is
    // runtime-initialized on every canvas load).
    //
    // Both `spaceHeld` and `panLocked` gate the click-drag pan: if
    // either is true, a leftMouseDown on empty canvas starts a pan.
    // V-toggle (`setPanLocked`) also pushes the new state into the dock
    // so the pan button's `on` visual stays accurate.
    private(set) var spaceHeld: Bool = false
    private(set) var panLocked: Bool = false

    /// Anchor point for an in-flight click-drag pan. `anchorPan` records
    /// the viewport at gesture start so every subsequent `.leftMouseDragged`
    /// absolute-sets the viewport (`newPan = anchor + (curClient - startClient)`)
    /// rather than accumulating per-tick deltas. Matches JS's
    /// `ps={x:e.clientX-px,y:e.clientY-py}` + `px=e.clientX-ps.x` math,
    /// which is drift-free because each tick derives from the starting
    /// anchor, not the previous tick.
    struct PanDragState {
        let startClient: NSPoint
        let anchorPanX: CGFloat
        let anchorPanY: CGFloat
    }
    private var panDragState: PanDragState?

    var isPanDragging: Bool { panDragState != nil }

    /// Flip the V-lock pan cursor. Called from
    /// `NativeBridge.dock(_:didPerform:)` when the user clicks the pan
    /// button in the dock, and from the keyboard V key handler in
    /// `DocumentWindowController`. Pushes the new state into the dock
    /// visual so the pan button's `on` highlight tracks reality.
    ///
    /// If we toggle OFF while a click-drag pan is in flight, the drag
    /// still finishes cleanly on its own `.leftMouseUp` — we only clear
    /// the "allow pan-start" flag, not the in-progress gesture.
    func setPanLocked(_ on: Bool) {
        // Annotation mode owns the cursor and click semantics — pan lock
        // is a no-op while it's armed so the two modes can't fight.
        if annotationMode && on { return }
        guard panLocked != on else { return }
        panLocked = on
        dock.setPanMode(on)
        cursorNeedsUpdate()
    }

    /// Called from `DocumentWindowController`'s keyboard monitor when
    /// the user presses or releases space. Doesn't push to the dock —
    /// space is transient, the dock only visualizes the V-lock.
    func setSpaceHeld(_ on: Bool) {
        // Ignore Space while annotation mode is armed — same reason as
        // `setPanLocked`. Releases (on=false) always go through so any
        // lingering flag from before annotation-mode armed gets cleared.
        if annotationMode && on { return }
        guard spaceHeld != on else { return }
        spaceHeld = on
        cursorNeedsUpdate()
    }

    // MARK: - Dock state (Phase 6e Step 70e)
    //
    // Annotation-panel visibility and screenshot-thumb rendering used to
    // previously lived in canvas JS. With the
    // canvas WKWebView gone, the flags are Swift-owned here. The dock
    // the dock reflects the active comment mode;
    // the annotation panel reads them on mode toggles. Initial values
    // match JS: panel closed, screenshots off.
    private(set) var annPanelOpen: Bool = false
    var onToggleComments: (() -> Void)?
    var onCloseComments: (() -> Void)?
    var onFixCommentsWithCodex: (() -> Void)?
    var makeProjectImportView: ((@escaping () -> Void) -> AddFrameTabPanel?)?
    var onBeforeAddFrame: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    func setCommentsInspectorOpen(_ open: Bool) { annPanelOpen = open }
    func framesSidebar(_ sidebar: FramesSidebar, didReorderFrameIDs ids: [String]) { document?.workspace.reorderFrames(ids) }

    func framesSidebar(_ sidebar: FramesSidebar, didRequest action: FramesSidebar.SourceAction, forSourceID sourceID: String) {
        guard let map = document?.workspace.projectMap,
              map.effectiveWebSource.id == sourceID else { return }
        switch action {
        case .retry:
            startWebSourceMonitor(map: map, force: true)
        case .startServer:
            prepareManagedServerStart(map: map)
        case .stopServer:
            stopManagedServer()
        case .restartServer:
            restartManagedServer(map: map)
        case .reloadFrames:
            reloadFrames(for: map)
        case .changeAddress:
            presentChangeWebSourceAddress(map: map)
        case .openInBrowser:
            // The address comes from the document: only hand web pages to
            // the browser, never file:// or app URL schemes.
            guard let url = FrameURLPolicy.browserURL(map.effectiveWebSource.address) else { return }
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - DockViewDelegate (Phase 6e Step 70e)
    //
    // The dock was routing clicks back through JS via `dock-action`
    // envelopes until this step. With the canvas WKWebView gone the
    // dock's delegate is this host, and each action runs entirely in
    // Swift against `WorkspaceStore` and the native panels. Bodies
    // mirror the corresponding JS handlers (`dockZoomIn/Out/Fit`,
    // `dockAddFrame`, `dockToggleAnnotation`, …) one-for-one so the
    // visible behaviour is unchanged.

    func dock(_ dock: DockView, didPerform action: DockView.Action) {
        performDockAction(action)
    }

    /// Keyboard-shortcut entry point mirroring `dock(_:didPerform:)` so
    /// bare-key shortcuts (`a`, `0`, `+`, `-`) route through the same
    /// performers the dock buttons use.
    func performDockAction(_ action: DockView.Action) {
        switch action {
        case .addFrame:         performDockAddFrame()
        case .refreshAll:       performDockRefreshAll()
        case .togglePan:        setPanLocked(!panLocked)
        case .selectCursor:
            if annotationMode { performDockToggleAnnotation() }
            setPanLocked(false)
        case .selectPan:
            if annotationMode { performDockToggleAnnotation() }
            setPanLocked(true)
        case .zoomIn:           performDockZoom(multiplier: 1.2)
        case .zoomOut:          performDockZoom(multiplier: 1.0 / 1.2)
        case .zoomFit:          performDockZoomFit()
        case .toggleAnnotation: performDockToggleAnnotation()
        case .toggleNotes:      performDockToggleNotes()
        }
    }

    // MARK: - Frames sidebar (Phase 6e polish #6)
    //
    // `toggleFramesSidebar()` and `setDockSidebarOpen(_:)` used to live
    // here — the first forwarded the dock's sidebar-button tap through
    // the responder chain to `NSSplitViewController.toggleSidebar(_:)`,
    // the second was called back from the split VC's KVO so the dock
    // button's accent wash mirrored the split-item's collapse state.
    // Both were deleted on 2026-04-21 when the dock's sidebar button
    // itself was removed (see DockView.swift). The window toolbar's
    // `.toggleSidebar` item and ⌘⌥S are now the only paths for toggling;
    // both reach the split VC directly without needing a bounce through
    // CanvasHost.

    // MARK: - FramesSidebarDelegate

    /// Clicking a row in the sidebar selects the frame AND pans the
    /// viewport so the frame's center lands at the visible canvas
    /// center. Scale is untouched — same rationale as the "click a pin
    /// in the annotation panel" UX, where the zoom stays put.
    ///
    /// Formula: for a frame at `(f.x, f.y)` with size `(f.w+2, f.h+35)`
    /// (the card's visual extents including border + header), the
    /// screen-space center is `(f.x + (f.w+2)/2) * scale + panX`. Setting
    /// that equal to `bounds.width/2` and solving for `panX` yields:
    ///     panX = bounds.width/2 − (f.x + (f.w+2)/2) * scale
    /// Same for the Y axis. Pan is saved back through `setViewport`, so
    /// the workspace observer re-paints the backdrop, links, and frame
    /// rects at the new transform.
    func framesSidebar(_ sidebar: FramesSidebar, didSelectFrameID id: String) {
        guard let workspace = document?.workspace,
              let frame = workspace.frame(id: id) else { return }
        window?.makeFirstResponder(self)
        selectFrame(id)
        let vp = workspace.viewport
        let cx = frame.x + (frame.w + CardGeometry.chromeWidth)  / 2
        let cy = frame.y + (frame.h + CardGeometry.chromeHeight) / 2
        let newPanX = bounds.width  / 2 - cx * vp.scale
        let newPanY = bounds.height / 2 - cy * vp.scale
        workspace.setViewport(vp.withPan(x: newPanX, y: newPanY))
    }

    // MARK: Web source health

    private func updateWebSourceMonitor(for map: ProjectMapSnapshot?) {
        guard let map else {
            webSourceMonitorTask?.cancel()
            webSourceMonitorTask = nil
            monitoredWebSource = nil
            lastWebSourceOnline = nil
            return
        }
        let source = map.effectiveWebSource
        if managedServerProcess != nil, managedServerSourceID != source.id {
            pendingServerRestart = nil
            stopManagedServer()
        }
        guard monitoredWebSource?.id != source.id || monitoredWebSource?.address != source.address else { return }
        startWebSourceMonitor(map: map, force: true)
    }

    private func startWebSourceMonitor(map: ProjectMapSnapshot, force: Bool) {
        let source = map.effectiveWebSource
        if !force, monitoredWebSource?.id == source.id, monitoredWebSource?.address == source.address { return }
        webSourceMonitorTask?.cancel()
        monitoredWebSource = source
        lastWebSourceOnline = nil
        let managesThisSource = managedServerProcess != nil && managedServerSourceID == source.id
        webSourceStatus = managesThisSource ? .starting : .checking
        sidebar?.setSourceStatus(webSourceStatus, sourceID: source.id)

        // Only localhost addresses are polled. A remote address comes from
        // the document and polling it would ping someone else's server from
        // this Mac every few seconds; treat it as online and let the frames
        // report their own load errors.
        guard LocalServerDiscovery.isLocal(source.address) else {
            applyWebSourceProbe(true, sourceID: source.id)
            return
        }
        webSourceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                let online = await Self.probeWebSource(source.address)
                guard !Task.isCancelled, let self,
                      self.monitoredWebSource?.id == source.id,
                      self.monitoredWebSource?.address == source.address else { return }
                self.applyWebSourceProbe(online, sourceID: source.id)
                let managesThisSource = self.managedServerProcess != nil && self.managedServerSourceID == source.id
                let delay: UInt64 = online ? 10_000_000_000 : (managesThisSource ? 1_000_000_000 : 20_000_000_000)
                do { try await Task.sleep(nanoseconds: delay) }
                catch { return }
            }
        }
    }

    private static func probeWebSource(_ address: String) async -> Bool {
        guard let url = try? ProjectMapBuilder.pageURL(base: address, path: "/") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 4
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    private func applyWebSourceProbe(_ online: Bool, sourceID: String) {
        let wasOnline = lastWebSourceOnline
        lastWebSourceOnline = online
        let managesThisSource = managedServerProcess != nil && managedServerSourceID == sourceID
        if online { webSourceStatus = managesThisSource ? .managedOnline : .online }
        else { webSourceStatus = managesThisSource ? .starting : .offline }
        sidebar?.setSourceStatus(webSourceStatus, sourceID: sourceID)
        if online, wasOnline != true, let map = document?.workspace.projectMap {
            reloadFrames(for: map)
        }
    }

    private func sourceFrameIDs(for map: ProjectMapSnapshot) -> [String] {
        guard let workspace = document?.workspace else { return [] }
        let sourceID = map.effectiveWebSource.id
        var ids = Set(map.routes.compactMap(\.frameID))
        for frame in workspace.frames {
            if case .string(let id) = frame.extras["webSourceID"], id == sourceID { ids.insert(frame.id) }
        }
        return workspace.frames.map(\.id).filter(ids.contains)
    }

    private func reloadFrames(for map: ProjectMapSnapshot) {
        for id in sourceFrameIDs(for: map) { reloadFrame(id: id) }
    }

    private struct DevServerLaunch {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let displayCommand: String
        let notice: String?
    }

    private struct MissingDevTool: LocalizedError {
        let name: String
        let installationURL: URL
        var errorDescription: String? { "\(name) is required to run this project." }
    }

    private struct PackageManifest: Decodable {
        var scripts: [String: String]?
        var packageManager: String?
    }

    /// Import toggle is the explicit run action; reuse the sidebar runner.
    func canStartImportedServer(_ map: ProjectMapSnapshot) -> Bool {
        guard LocalServerDiscovery.isLocal(map.baseURL), URLComponents(string: map.baseURL)?.scheme == "http" else { return false }
        if map.framework == "Static HTML" { return true }
        let root = URL(fileURLWithPath: map.rootPath, isDirectory: true)
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: root.appendingPathComponent("package.json")),
              let manifest = try? JSONDecoder().decode(PackageManifest.self, from: data) else { return false }
        return manifest.scripts?["dev"]?.isEmpty == false
    }

    func startImportedServer(_ map: ProjectMapSnapshot) {
        guard canStartImportedServer(map), !importServerStartPending else { return }
        importServerStartPending = true
        Task { [weak self] in
            guard let self else { return }
            defer { importServerStartPending = false }
            guard window != nil, document?.workspace.projectMap?.id == map.id else { return }
            if await LocalServerDiscovery.responds(map.baseURL) {
                guard window != nil, document?.workspace.projectMap?.id == map.id, document?.workspace.projectMap?.baseURL == map.baseURL else { return }
                startWebSourceMonitor(map: map, force: true)
                return
            }
            guard document?.workspace.projectMap?.id == map.id,
                  document?.workspace.projectMap?.baseURL == map.baseURL else { return }
            if managedServerProcess != nil {
                if managedServerSourceID != map.effectiveWebSource.id {
                    presentWebSourceError("Another project server is still running. Stop it before starting this project.")
                }
                return
            }
            let port = URLComponents(string: map.baseURL)?.port ?? (map.baseURL.hasPrefix("https:") ? 443 : 80)
            if await WebPageTabPanel.probePort(port, timeout: 0.6) {
                presentWebSourceError("Port \(port) is already in use but did not return a web response. Wait for that server or choose another address.")
                return
            }
            guard window != nil, document?.workspace.projectMap?.id == map.id, document?.workspace.projectMap?.baseURL == map.baseURL else { return }
            prepareManagedServerStart(map: map)
        }
    }

    /// Runs the project's dev script after a one-time, per-machine approval
    /// (`ProjectTrust`). The import path used to skip the prompt; it no
    /// longer does — importing a folder is not consent to execute it.
    private func prepareManagedServerStart(map: ProjectMapSnapshot) {
        guard managedServerProcess == nil else { return }
        let root = URL(fileURLWithPath: map.rootPath, isDirectory: true).standardizedFileURL
        let launch: DevServerLaunch
        do { launch = try devServerLaunch(for: root, address: map.effectiveWebSource.address, framework: map.framework) }
        catch let error as MissingDevTool { presentMissingDevTool(error); return }
        catch { presentWebSourceError(error.localizedDescription); return }

        ProjectTrust.confirm(root, purpose: .devServer(command: launch.displayCommand, notice: launch.notice),
                             in: window) { [weak self] approved in
            guard approved, let self, self.managedServerProcess == nil,
                  self.document?.workspace.projectMap?.id == map.id else { return }
            self.launchManagedServer(launch, root: root, map: map)
        }
    }

    private func devServerLaunch(for root: URL, address: String, framework: String) throws -> DevServerLaunch {
        let packageURL = root.appendingPathComponent("package.json")
        let fm = FileManager.default
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let nvmRoot = URL(fileURLWithPath: home).appendingPathComponent(".nvm/versions/node", isDirectory: true)
        let nvmDirectories = ((try? fm.contentsOfDirectory(at: nvmRoot, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map { $0.appendingPathComponent("bin", isDirectory: true).path }
        let directories = nvmDirectories + [
            "\(home)/.volta/bin",
            "\(home)/.local/share/pnpm",
            "\(home)/Library/pnpm",
            "\(home)/.bun/bin",
            "\(home)/.asdf/shims",
            "\(home)/.mise/shims",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let currentPath = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let path = Array(NSOrderedSet(array: directories + currentPath)) as? [String] ?? directories + currentPath
        environment["PATH"] = path.joined(separator: ":")
        let executable: (String) -> String? = { name in
            path.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
                .first(where: fm.isExecutableFile(atPath:))
        }
        let port = URLComponents(string: address)?.port ?? 80

        let manifest = (try? Data(contentsOf: packageURL))
            .flatMap { try? JSONDecoder().decode(PackageManifest.self, from: $0) }
        if let manifest, manifest.scripts?["dev"] != nil {
            let declared = manifest.packageManager?.split(separator: "@").first.map(String.init)
            let manager: String
            if let declared, ["npm", "pnpm", "yarn", "bun"].contains(declared) { manager = declared }
            else if fm.fileExists(atPath: root.appendingPathComponent("bun.lock").path) || fm.fileExists(atPath: root.appendingPathComponent("bun.lockb").path) { manager = "bun" }
            else if fm.fileExists(atPath: root.appendingPathComponent("pnpm-lock.yaml").path) { manager = "pnpm" }
            else if fm.fileExists(atPath: root.appendingPathComponent("yarn.lock").path) { manager = "yarn" }
            else { manager = "npm" }

            var arguments = ["run", "dev"]
            if manager == "npm" { arguments += ["--", "--port", String(port)] }
            else { arguments += ["--port", String(port)] }
            let executablePath: String
            let processArguments: [String]
            let displayCommand: String
            let notice: String?
            if let direct = executable(manager) {
                executablePath = direct
                processArguments = arguments
                displayCommand = ([manager] + arguments).joined(separator: " ")
                notice = nil
            } else if ["pnpm", "yarn"].contains(manager), let corepack = executable("corepack") {
                executablePath = corepack
                processArguments = [manager] + arguments
                displayCommand = (["corepack", manager] + arguments).joined(separator: " ")
                notice = "Corepack may download the project’s \(manager) version before starting the server."
            } else {
                throw missingTool(manager)
            }
            return DevServerLaunch(
                executable: URL(fileURLWithPath: executablePath),
                arguments: processArguments,
                environment: environment,
                displayCommand: displayCommand,
                notice: notice
            )
        }

        // A plain HTML folder is still a project, but it has no package
        // script. Serve it through Python's standard local HTTP server so
        // the unified Project flow keeps the former Folder capability.
        if framework == "Static HTML" {
            guard let executablePath = executable("python3") else {
                throw missingTool("Python 3")
            }
            let arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
            return DevServerLaunch(
                executable: URL(fileURLWithPath: executablePath),
                arguments: arguments,
                environment: environment,
                displayCommand: (["python3"] + arguments).joined(separator: " "),
                notice: nil
            )
        }

        guard manifest != nil else {
            throw NSError(domain: "WebSource", code: 10, userInfo: [NSLocalizedDescriptionKey: "No readable package.json was found in \(root.path)."])
        }
        throw NSError(domain: "WebSource", code: 11, userInfo: [NSLocalizedDescriptionKey: "package.json does not define a dev script."])
    }

    private func missingTool(_ name: String) -> MissingDevTool {
        let address: String
        switch name {
        case "pnpm": address = "https://pnpm.io/installation"
        case "yarn": address = "https://yarnpkg.com/getting-started/install"
        case "bun": address = "https://bun.sh/docs/installation"
        case "Python 3": address = "https://www.python.org/downloads/macos/"
        default: address = "https://nodejs.org/en/download"
        }
        return MissingDevTool(name: name, installationURL: URL(string: address)!)
    }

    private func presentMissingDevTool(_ error: MissingDevTool) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Install \(error.name) to Start This Project"
        alert.informativeText = "This project uses \(error.name), but Web Frames could not find it. Install it from the official guide, then choose Start Server again."
        alert.addButton(withTitle: "Open Installation Guide")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(error.installationURL)
        }
    }

    private func launchManagedServer(_ launch: DevServerLaunch, root: URL, map: ProjectMapSnapshot) {
        guard managedServerProcess == nil else { return }
        let scoped = root.startAccessingSecurityScopedResource()
        let pipe = Pipe()
        let process = Process()
        let supervised = ChildProcessWatchdog.wrap(executable: launch.executable, arguments: launch.arguments)
        process.executableURL = supervised.executable
        process.arguments = supervised.arguments
        process.environment = launch.environment
        process.currentDirectoryURL = root
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        managedServerOutput = ""
        managedServerPipe = pipe
        managedServerScopedURL = scoped ? root : nil
        managedServerSourceID = map.effectiveWebSource.id
        stoppingManagedServer = false

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.managedServerOutput = String((self.managedServerOutput + text).suffix(16_000))
            }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            guard let process else { return }
            Task { @MainActor [weak self] in self?.managedServerDidExit(process, map: map) }
        }
        do {
            try process.run()
            managedServerProcess = process
            ToastView.show(message: "Starting server…", in: self)
            webSourceStatus = .starting
            sidebar?.setSourceStatus(.starting, sourceID: map.effectiveWebSource.id)
            startWebSourceMonitor(map: map, force: true)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            if scoped { root.stopAccessingSecurityScopedResource() }
            managedServerPipe = nil
            managedServerScopedURL = nil
            managedServerSourceID = nil
            presentWebSourceError("Could not start \(launch.displayCommand). \(error.localizedDescription)")
        }
    }

    private func stopManagedServer() {
        guard let process = managedServerProcess else { return }
        stoppingManagedServer = true
        process.interrupt()
        Task { @MainActor [weak process] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if process?.isRunning == true { process?.terminate() }
        }
    }

    private func restartManagedServer(map: ProjectMapSnapshot) {
        guard managedServerProcess != nil else { prepareManagedServerStart(map: map); return }
        pendingServerRestart = map
        stopManagedServer()
    }

    private func managedServerDidExit(_ process: Process, map: ProjectMapSnapshot) {
        guard managedServerProcess === process else { return }
        managedServerPipe?.fileHandleForReading.readabilityHandler = nil
        managedServerPipe = nil
        if let scoped = managedServerScopedURL { scoped.stopAccessingSecurityScopedResource() }
        managedServerScopedURL = nil
        managedServerProcess = nil
        managedServerSourceID = nil
        let expected = stoppingManagedServer
        stoppingManagedServer = false
        webSourceStatus = .offline
        sidebar?.setSourceStatus(.offline, sourceID: map.effectiveWebSource.id)

        if let restart = pendingServerRestart {
            pendingServerRestart = nil
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self?.prepareManagedServerStart(map: restart)
            }
        } else if !expected && process.terminationStatus != 0 {
            let detail = managedServerOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            presentWebSourceError(detail.isEmpty ? "The dev server exited with status \(process.terminationStatus)." : "The dev server stopped:\n\n\(String(detail.suffix(1800)))")
        }
        if document?.workspace.projectMap?.effectiveWebSource.id == map.effectiveWebSource.id {
            startWebSourceMonitor(map: map, force: true)
        }
    }

    private func presentChangeWebSourceAddress(map: ProjectMapSnapshot) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Change Server Address"
        alert.informativeText = "All pages in this server group will keep their paths and use the new address."
        alert.addButton(withTitle: "Change")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: map.effectiveWebSource.address)
        field.placeholderString = "http://localhost:3000"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.changeWebSourceAddress(field.stringValue, map: map)
        }
    }

    private func changeWebSourceAddress(_ rawAddress: String, map original: ProjectMapSnapshot) {
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        do {
            _ = try ProjectMapBuilder.pageURL(base: address, path: "/")
            var updates: [(String, String)] = []
            for route in original.routes {
                guard let id = route.frameID, let path = route.concretePath,
                      document?.workspace.frame(id: id) != nil else { continue }
                updates.append((id, try ProjectMapBuilder.pageURL(base: address, path: path).absoluteString))
            }
            var map = original
            var source = map.effectiveWebSource
            source.address = address
            map.baseURL = address
            map.webSource = source
            for (id, url) in updates { document?.workspace.setFrameSource(id: id, url: url) }
            document?.workspace.setProjectMap(map)
            if managedServerProcess != nil {
                pendingServerRestart = map
                stopManagedServer()
            }
        } catch {
            presentWebSourceError(error.localizedDescription)
        }
    }

    private func presentWebSourceError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Server Error"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    /// Dock "+" → native add-frame modal. Was `dockAddFrame()` in JS,
    /// which just called `NativeAPI.openAddFrameModal()` — the modal
    /// has been native since Phase 2 so this is a direct call now.
    private func performDockAddFrame() {
        presentAddFrameModal()
    }

    /// Dock refresh button → reload every non-image frame's WKWebView.
    /// Mirrors JS `dockRefreshAll`: `frames.forEach(f=>NativeAPI.load(f.id,f.url))`.
    /// Image frames have `image://…` urls that WKWebView can't load, so
    /// they're filtered out same as in the workspace-observer lifecycle
    /// diff (`refreshNativeViewsFromWorkspace`).
    private func performDockRefreshAll() {
        guard let workspace = document?.workspace else { return }
        for frame in workspace.frames where !frame.isImage {
            reloadFrame(id: frame.id)
        }
    }

    /// Zoom in / out. Mirrors JS `dockZoomIn`/`dockZoomOut`: multiply
    /// scale by 1.2 (or 1/1.2), clamp to `[minScale, maxScale]`, leave
    /// pan untouched. The workspace observer will re-paint the backdrop
    /// and link layer at the new scale, and push `setZoomPercent` below
    /// keeps the dock label in sync without waiting for a round-trip.
    private func performDockZoom(multiplier: CGFloat) {
        guard let workspace = document?.workspace else { return }
        let vp = workspace.viewport
        let newScale = ViewportModel.clampScale(vp.scale * multiplier)
        guard newScale != vp.scale else { return }
        workspace.setViewport(ViewportModel(scale: newScale, panX: vp.panX, panY: vp.panY))
        dock.setZoomPercent(Int((newScale * 100).rounded()))
    }

    /// Zoom-fit. Mirrors JS `dockZoomFit` at index.html:855–865:
    ///   - Empty frames → reset to identity viewport (scale 1, pan (80,80)).
    ///   - Otherwise → compute the world-space bounding box (including
    ///     the +2 card border and +35 header baked into the visual rect
    ///     formula), divide the visible area minus 2×pad by the box
    ///     dimensions, pick the smaller ratio, clamp to the scale range.
    ///     Pan anchors the bounding-box top-left at (pad, pad) in client
    ///     space: `panX = pad - minX*scale`.
    /// Zoom/pan the viewport so the currently-selected frame fills the
     /// canvas with the same 80pt padding the "fit all" path uses. No-op
     /// when nothing is selected. Bound to `P` by the shortcut monitor.
    func zoomToSelectedFrame() {
        guard let id = selectedFrameId,
              let workspace = document?.workspace,
              let frame = workspace.frames.first(where: { $0.id == id }) else { return }
        let pad: CGFloat = 80
        let boxW = max(1, frame.w + CardGeometry.chromeWidth)
        let boxH = max(1, frame.h + CardGeometry.chromeHeight)
        let availW = max(1, bounds.width  - pad * 2)
        let availH = max(1, bounds.height - pad * 2)
        let scale = ViewportModel.clampScale(min(availW / boxW, availH / boxH))
        let next = ViewportModel(
            scale: scale,
            panX: pad - frame.x * scale,
            panY: pad - frame.y * scale
        )
        workspace.setViewport(next)
        dock.setZoomPercent(Int((next.scale * 100).rounded()))
    }

    private func performDockZoomFit() {
        guard let workspace = document?.workspace else { return }
        let frames = workspace.frames
        let pad: CGFloat = 80
        let next: ViewportModel
        if frames.isEmpty {
            next = .identity
        } else {
            let minX = frames.map(\.x).min() ?? 0
            let minY = frames.map(\.y).min() ?? 0
            let maxX = frames.map { $0.x + $0.w + CardGeometry.chromeWidth  }.max() ?? 0
            let maxY = frames.map { $0.y + $0.h + CardGeometry.chromeHeight }.max() ?? 0
            let availW = max(1, bounds.width  - pad * 2)
            let availH = max(1, bounds.height - pad * 2)
            let boxW   = max(1, maxX - minX)
            let boxH   = max(1, maxY - minY)
            let scale = ViewportModel.clampScale(min(availW / boxW, availH / boxH))
            next = ViewportModel(
                scale: scale,
                panX:  pad - minX * scale,
                panY:  pad - minY * scale
            )
        }
        workspace.setViewport(next)
        dock.setZoomPercent(Int((next.scale * 100).rounded()))
    }

    /// Annotation-mode toggle. Mirrors JS `dockToggleAnnotation`:
    /// flips the flag, tints the dock button, propagates to FrameManager
    /// (for the per-frame hover highlight arming), and — when turning
    /// OFF — posts `wf-highlight-off` to every frame so the last-painted
    /// outline clears immediately instead of lingering until the next
    /// mouse move.
    private func performDockToggleAnnotation() {
        let on = !annotationMode
        setAnnotationMode(on)
        bridge.setFramesAnnotationMode(on)
        dock.setAnnotationMode(on)
        if !on, let workspace = document?.workspace {
            for frame in workspace.frames where !frame.isImage {
                bridge.postToFrame(id: frame.id, payload: ["type": "wf-highlight-off"])
            }
        }
    }

    /// Notes/annotation panel toggle. Mirrors JS `dockToggleNotes`:
    /// flips `annPanelOpen`, slides the native panel in/out, tints the
    /// dock button. The panel's own `annotationPanelDidRequestClose`
    /// delegate path also flips this flag + button tint (close button
    /// inside the panel) so the two entry points stay in sync.
    private func performDockToggleNotes() {
        onToggleComments?()
    }

    /// Record the anchor for a click-drag pan. Called from the window
    /// leftMouseDown monitor after it has confirmed the gesture is
    /// eligible (spaceHeld/panLocked active, click on empty canvas,
    /// no modal). Returns `true` if the drag started.
    func beginPanDrag(at clientPoint: NSPoint) -> Bool {
        guard panDragState == nil, let workspace = document?.workspace else {
            return false
        }
        panDragState = PanDragState(
            startClient: clientPoint,
            anchorPanX: workspace.viewport.panX,
            anchorPanY: workspace.viewport.panY
        )
        cursorNeedsUpdate()
        return true
    }

    /// Apply an in-flight click-drag pan tick. The new panX/Y are
    /// absolute-set against the anchor recorded at `beginPanDrag`, not
    /// accumulated — so dropped events or coarse `leftMouseDragged`
    /// sampling don't drift. No-op if no drag is in flight.
    func updatePanDrag(at clientPoint: NSPoint) {
        guard let state = panDragState,
              let workspace = document?.workspace else { return }
        let dx = clientPoint.x - state.startClient.x
        let dy = clientPoint.y - state.startClient.y
        // Window coords are flipped relative to AppKit view coords — Y
        // increases UP in `locationInWindow` but our pan is stored in
        // top-left view-space. Subtract `dy` so dragging down moves the
        // content down (natural "grab-and-push" feel).
        let next = workspace.viewport.withPan(
            x: state.anchorPanX + dx,
            y: state.anchorPanY - dy
        )
        workspace.setViewport(next)
        // Cursor rects are not consulted while a drag is in flight — the
        // cursor is latched to whatever was set at `mouseDown`. WKWebView's
        // WebContent process can also slam an arrow cursor via IPC mid-drag
        // once `setViewport` repaints its frame. Re-assert closedHand on
        // every tick so the grab cursor sticks for the whole drag.
        NSCursor.closedHand.set()
    }

    /// End an in-flight click-drag pan. No-op if no drag was active.
    func endPanDrag() {
        guard panDragState != nil else { return }
        panDragState = nil
        cursorNeedsUpdate()
    }

    /// Poke the NSCursor state after any pan-related property changes
    /// (spaceHeld, panLocked, panDragState). We don't use tracking
    /// areas for pan — the cursor is uniform across the whole canvas
    /// while either flag is on, so manually setting `NSCursor.current`
    /// when state flips is enough. `resetCursorRects` on the window
    /// reasserts the right arrow when the flags all clear.
    private func cursorNeedsUpdate() {
        let wantGrab = spaceHeld || panLocked
        // Same WKWebView-IPC problem as annotation mode: NSCursor.set()
        // gets stomped by the WebContent process as soon as mouseMoved
        // reaches a frame's WKWebView. `PanCursorShield` sits above the
        // frame layer, owns hitTest during pan mode, and installs a
        // cursor rect. While `spaceHeld || panLocked`, frames are not
        // mouse-interactive — pan is the whole point.
        panCursorShield.cursor = (panDragState != nil) ? .closedHand : .openHand
        panCursorShield.isHidden = !wantGrab
        window?.invalidateCursorRects(for: panCursorShield)
        if panDragState != nil {
            NSCursor.closedHand.set()
        } else if wantGrab {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
            window?.resetCursorRects()
        }
    }

    // MARK: - Annotation-mode click (Phase 6e Step 6)
    //
    // Native owner of the "armed annotation mode → click on a frame body
    // → open the pin editor with a draft" flow. The JS counterpart in
    // `attachAnnListener` (index.html:1659) still exists for the
    // browser-fallback preview, but in the app the window-level
    // annotation-click monitor (`DocumentWindowController`) consumes
    // the leftMouseDown before it reaches the canvas WKWebView, so the
    // JS path is dead code at runtime.
    //
    // `FrameContainer.hitTest` already returns nil in annotation mode
    // (FrameManager.swift:155), so per-frame WKWebViews are transparent
    // to clicks — and the window monitor consumes the event, so the
    // canvas WKWebView's JS `.shld` handler is also skipped. Net effect:
    // exactly one path fires for an in-mode click, and it's this one.
    //
    // Draft lifecycle: a click allocates an annId + num, records a
    // `PinDraft` in `pinDrafts`, and fires a `wf-inspect` envelope at
    // the target frame. The async reply (`wf-dom-context` ± a follow-up
    // `wf-dom-screenshot`) is intercepted in `NativeBridge.handleFrameMessage`
    // and routed here via `handleInspectContext` / `handleInspectScreenshot`.
    // On context we open the pin editor (screenshot nil is fine —
    // PinEditorModal hides the thumb row until we call
    // `updateScreenshot`); on save we commit the draft through
    // `workspace.createAnnotation`; on cancel we drop it.
    private(set) var annotationMode: Bool = false

    /// Snapshot held for an in-flight "brand-new pin" between the
    /// click-in-annotation-mode and the pin editor's save/cancel. The
    /// workspace never sees the annotation until `pinEditorDidSave` —
    /// cancel just drops the draft without touching the store. Keyed on
    /// annotation id so the async inspect replies can resolve back to
    /// the right draft even if the user rapid-clicks two pins.
    struct PinDraft {
        var ann: AnnotationModel
        var elementLabel: String
        var computedStyles: [String: String]
        var screenshotImage: NSImage?
        /// Captured context dict from the `wf-dom-context` reply. Stored
        /// as a JSON value so we can re-inject it into
        /// `AnnotationModel.extras["element"]` at save time without a
        /// second recursive Foundation→JSONValue conversion pass.
        var elementJSON: JSONValue
    }

    /// In-flight pin drafts. Populated on annotation-mode click, drained
    /// by `pinEditorDidSave` (commits) or `pinEditorDidCancel` (discards).
    /// `NativeBridge` peeks at this map to decide whether `wf-dom-context`
    /// / `wf-dom-screenshot` replies belong to a Swift-owned draft or
    /// should flow through to JS (backwards-compat for any legacy JS
    /// inspect originator — there are no remaining JS originators in
    /// Phase 6e, but the pass-through keeps Step 6 additive).
    private(set) var pinDrafts: [String: PinDraft] = [:]

    /// Sync the annotation-mode flag into the host. Called from the
    /// `annotation-mode` envelope handler in `NativeBridge` so the
    /// window-level click monitor can gate on it. `FrameManager` also
    /// sees the flag via its own `setAnnotationMode` — the two tracks
    /// stay in lockstep because both are called from the same handler.
    func setAnnotationMode(_ on: Bool) {
        guard annotationMode != on else { return }
        annotationMode = on
        // Arming annotation drops any active pan state — the two modes
        // are mutually exclusive. `cursorNeedsUpdate` hides panCursorShield
        // and flips NSCursor back to arrow so the crosshair shield can
        // take over below.
        if on {
            if spaceHeld || panLocked {
                spaceHeld = false
                panLocked = false
                dock.setPanMode(false)
            }
            cursorNeedsUpdate()
        }
        // The crosshair is enforced by `AnnotationCursorShield` — a
        // transparent overlay pinned above every other subview whose
        // `resetCursorRects` installs a single crosshair rect covering
        // its full bounds. AppKit's cursor-rect resolution picks the
        // topmost (last-added-sibling) rect at the pointer, which wins
        // over any rects WKWebView registers deeper in the tree. We
        // can't rely on `NSCursor.set()` / an event monitor because
        // cursor changes requested from WebContent arrive out-of-band
        // after our monitor runs and flip the cursor back.
        annotationCursorShield.isHidden = !on
        annotationCursorShield.window?.invalidateCursorRects(for: annotationCursorShield)
        if !on { clearAnnotationHighlight(); cancelAnnotationPress() }
    }

    let annotationCursorShield = AnnotationCursorShield()
    let panCursorShield = PanCursorShield()

    /// Frame id that currently owns the JS picker outline, if any. Tracked
    /// so we can send `wf-highlight-off` to the previous frame when the
    /// crosshair crosses into a new one (otherwise the outline would
    /// stack / orphan on the old frame).
    private var annotationHighlightFrameId: String?

    /// A mouse press in comment mode on a frame body. A click drops a point
    /// pin; dragging past `areaDragThreshold` selects an area instead (the
    /// Figma behaviour). Coordinates are world points, clamped to the body.
    private struct AnnotationPress {
        let frameId: String
        let body: CGRect
        let start: CGPoint
        var current: CGPoint
        var isArea = false
    }
    private var annotationPress: AnnotationPress?
    /// Screen points the pointer must travel before a press becomes an area.
    private static let areaDragThreshold: CGFloat = 4
    private lazy var areaSelectionLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.strokeColor = WFDesign.accent.cgColor
        l.fillColor = WFDesign.accent.withAlphaComponent(0.1).cgColor
        l.lineWidth = 1.5
        l.lineDashPattern = [5, 3]
        l.actions = ["path": NSNull(), "hidden": NSNull()]
        l.zPosition = 1000
        return l
    }()

    /// Called from `DocumentWindowController`'s annotation mouse monitor
    /// when a leftMouseDown in annotation mode lands on empty canvas
    /// (not dock / panel / modal). Hit-tests the frames' body rects and
    /// starts a press on the topmost body under the pointer; the pin (or
    /// area) is created on mouse-up by `endAnnotationPress`.
    ///
    /// No-op (returns false) when the click misses every frame body —
    /// an annotation-mode click on the gap between frames simply does
    /// nothing, matching the JS behaviour (the `.shld` element only
    /// overlays the body, not the surrounding canvas).
    @discardableResult
    func beginAnnotationPress(atWindowPoint windowPoint: NSPoint) -> Bool {
        guard annotationMode, let workspace = document?.workspace else { return false }
        let world = worldPoint(atWindowPoint: windowPoint)
        // First match is the topmost card for overlapping frames —
        // same rationale as `frameAtWorldPoint`.
        for baseFrame in workspace.frames {
            let f = frameWithLivePreview(baseFrame)
            // Body world rect: the card minus its header and border, which
            // FrameCardView.relayoutInterior keeps constant in screen points.
            let body = CardGeometry.bodyRect(x: f.x, y: f.y, width: f.w, height: f.h, scale: workspace.viewport.scale)
            guard body.width > 0, body.height > 0,
                  world.x >= body.minX, world.x <= body.maxX,
                  world.y >= body.minY, world.y <= body.maxY else { continue }
            annotationPress = AnnotationPress(frameId: f.id, body: body, start: world, current: world)
            return true
        }
        return false
    }

    /// Mouse dragged during a comment-mode press: grows the area outline.
    /// Returns false when no press is active so the event flows on.
    @discardableResult
    func dragAnnotationPress(toWindowPoint windowPoint: NSPoint) -> Bool {
        guard var press = annotationPress, let workspace = document?.workspace else { return false }
        let world = worldPoint(atWindowPoint: windowPoint)
        press.current = CGPoint(x: min(max(world.x, press.body.minX), press.body.maxX),
                                y: min(max(world.y, press.body.minY), press.body.maxY))
        let travel = hypot(press.current.x - press.start.x, press.current.y - press.start.y) * workspace.viewport.scale
        if !press.isArea, travel >= Self.areaDragThreshold {
            press.isArea = true
            clearAnnotationHighlight()
        }
        annotationPress = press
        if press.isArea { showAreaSelection(worldRect: Self.rect(press.start, press.current)) }
        return true
    }

    /// Mouse up: creates the point or area draft and opens the pin editor
    /// once the frame replies with its DOM context.
    @discardableResult
    func endAnnotationPress(atWindowPoint windowPoint: NSPoint) -> Bool {
        guard annotationPress != nil else { return false }
        dragAnnotationPress(toWindowPoint: windowPoint)
        guard let press = annotationPress else { return false }
        annotationPress = nil
        areaSelectionLayer.isHidden = true
        guard let workspace = document?.workspace,
              let baseFrame = workspace.frames.first(where: { $0.id == press.frameId }) else { return true }
        let f = frameWithLivePreview(baseFrame)
        let body = press.body
        func pct(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - body.minX) / body.width * 100, y: (p.y - body.minY) / body.height * 100)
        }
        if press.isArea {
            let r = Self.rect(press.start, press.current)
            let origin = pct(r.origin)
            let size = CGSize(width: r.width / body.width * 100, height: r.height / body.height * 100)
            startPinDraft(frame: f, xPct: origin.x, yPct: origin.y, areaPct: size)
        } else {
            let p = pct(press.start)
            startPinDraft(frame: f, xPct: p.x, yPct: p.y, areaPct: nil)
        }
        return true
    }

    /// Drops an in-flight press (Escape, mode switch, window change).
    func cancelAnnotationPress() {
        annotationPress = nil
        areaSelectionLayer.isHidden = true
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func worldPoint(atWindowPoint windowPoint: NSPoint) -> CGPoint {
        let hostPoint = self.convert(windowPoint, from: nil)
        return worldPoint(clientX: hostPoint.x, clientY: flipClientY(hostPoint.y))
    }

    private func showAreaSelection(worldRect r: CGRect) {
        guard let workspace = document?.workspace else { return }
        let v = workspace.viewport
        // World → client (top-left origin) → host (bottom-left origin).
        let minX = r.minX * v.scale + v.panX
        let maxY = flipClientY(r.minY * v.scale + v.panY)
        let hostRect = CGRect(x: minX, y: maxY - r.height * v.scale, width: r.width * v.scale, height: r.height * v.scale)
        // The shield is flipped (top-left origin); convert so the outline
        // lands under the pointer.
        let shieldRect = annotationCursorShield.convert(hostRect, from: self)
        annotationCursorShield.wantsLayer = true
        if areaSelectionLayer.superlayer == nil { annotationCursorShield.layer?.addSublayer(areaSelectionLayer) }
        areaSelectionLayer.frame = annotationCursorShield.bounds
        areaSelectionLayer.path = CGPath(rect: shieldRect, transform: nil)
        areaSelectionLayer.isHidden = false
    }

    /// Allocates an annId + num, records a `PinDraft`, and fires
    /// `wf-inspect` at the frame. The async reply opens the editor (via
    /// `handleInspectContext` below). Area comments carry no screenshot:
    /// the outline on the frame shows the region.
    private func startPinDraft(frame f: FrameModel, xPct: CGFloat, yPct: CGFloat, areaPct: CGSize?) {
        guard let workspace = document?.workspace else { return }
        let annId = "a" + UUID().uuidString
        let num = workspace.allocateAnnotationNum()
        // Seed a bare annotation model — element/initialScroll fill
        // in from the `wf-dom-context` reply before the editor
        // opens. Kept in `pinDrafts` so cancel can discard it
        // without a round-trip through `workspace`.
        var ann = AnnotationModel(
            id: annId,
            num: num,
            frameId: f.id,
            xPct: xPct,
            yPct: yPct,
            color: "blue",
            comment: "",
            resolved: false,
            edits: [:],
            frameUrl: f.url,
            frameLabel: f.label,
            extras: [:]
        )
        ann.areaSizePct = areaPct
        pinDrafts[annId] = PinDraft(
            ann: ann,
            elementLabel: "element",
            computedStyles: [:],
            screenshotImage: nil,
            elementJSON: .null
        )
        // Clear any residual picker highlight, then request the DOM
        // context. Matches the JS flow's order at index.html:1684-1685.
        bridge.postToFrame(id: f.id, payload: ["type": "wf-highlight-off"])
        var inspect: [String: Any] = ["type": "wf-inspect", "xPct": xPct, "yPct": yPct, "annId": annId]
        if let areaPct {
            inspect["area"] = ["xPct": xPct, "yPct": yPct, "wPct": areaPct.width, "hPct": areaPct.height]
        }
        bridge.postToFrame(id: f.id, payload: inspect)
    }

    /// Drive the per-frame JS `wf-highlight` picker from a native pointer
    /// coordinate. The cursor shield eats mouseMoved before WKWebView can
    /// see it, so without this mirror the DOM outline never appears.
    /// Walks frames top-down (same order as the click hit-test), finds
    /// the one under the pointer, converts to xPct/yPct, and posts. When
    /// the pointer straddles a gap between frames we clear the previous
    /// highlight so the outline doesn't ghost on the last frame.
    func updateAnnotationHighlight(atWindowPoint windowPoint: NSPoint) {
        guard annotationMode, let workspace = document?.workspace else { return }
        let hostPoint = self.convert(windowPoint, from: nil)
        let world = worldPoint(clientX: hostPoint.x,
                               clientY: flipClientY(hostPoint.y))
        for baseFrame in workspace.frames {
            let f = frameWithLivePreview(baseFrame)
            let body = CardGeometry.bodyRect(x: f.x, y: f.y, width: f.w, height: f.h, scale: workspace.viewport.scale)
            let bodyX = body.minX, bodyY = body.minY, bodyW = body.width, bodyH = body.height
            guard bodyW > 0, bodyH > 0 else { continue }
            guard world.x >= bodyX, world.x <= bodyX + bodyW,
                  world.y >= bodyY, world.y <= bodyY + bodyH else { continue }
            let xPct = (world.x - bodyX) / bodyW * 100
            let yPct = (world.y - bodyY) / bodyH * 100
            if let prev = annotationHighlightFrameId, prev != f.id {
                bridge.postToFrame(id: prev, payload: ["type": "wf-highlight-off"])
            }
            annotationHighlightFrameId = f.id
            bridge.postToFrame(id: f.id, payload: [
                "type": "wf-highlight",
                "xPct": xPct,
                "yPct": yPct,
                // Lets the page match the frame's rounded bottom corners
                // (FrameCardView.cornerRadius screen points) in CSS pixels.
                "bodyScreenWidth": bodyW * workspace.viewport.scale,
                "cornerRadius": FrameCardView.cornerRadius,
            ])
            return
        }
        clearAnnotationHighlight()
    }

    /// Clears any lingering picker outline in the last-highlighted frame.
    /// Called when the pointer leaves the shield (mouseExited) or crosses
    /// into the gap between frames, and when annotation mode is disarmed.
    func clearAnnotationHighlight() {
        guard let id = annotationHighlightFrameId else { return }
        annotationHighlightFrameId = nil
        bridge.postToFrame(id: id, payload: ["type": "wf-highlight-off"])
    }

    /// `NativeBridge` routes `wf-dom-context` replies here when the
    /// `annId` belongs to one of our `pinDrafts`. Populates the draft's
    /// element snapshot + computedStyles + label, stamps scroll
    /// offsets on the annotation's `extras`, then presents the pin
    /// editor. A `nil` context still opens the editor — matches JS,
    /// where a null `domCtx` flows through `createAnnotation` without
    /// losing the xPct/yPct click position.
    func handleInspectContext(annId: String, contextJSON: JSONValue) {
        guard var draft = pinDrafts[annId] else { return }
        draft.elementJSON = contextJSON
        var label = "element"
        var styles: [String: String] = [:]
        var scrollX: Double = 0
        var scrollY: Double = 0
        if case .object(let ctx) = contextJSON {
            if case .string(let s) = ctx["componentName"] ?? .null, !s.isEmpty {
                label = s
            } else if case .string(let s) = ctx["tagName"] ?? .null, !s.isEmpty {
                label = s
            }
            if case .object(let csDict) = ctx["computedStyles"] ?? .null {
                for (k, v) in csDict {
                    if case .string(let s) = v { styles[k] = s }
                }
            }
            if case .number(let n) = ctx["scrollX"] ?? .null { scrollX = n }
            if case .number(let n) = ctx["scrollY"] ?? .null { scrollY = n }
        }
        if draft.ann.areaSizePct != nil {
            // The page reports the area in CSS pixels.
            if case .object(let ctx) = contextJSON, case .object(let area) = ctx["area"] ?? .null,
               case .number(let w) = area["width"] ?? .null, case .number(let h) = area["height"] ?? .null {
                label = "Area \(Int(w))×\(Int(h)) · " + label
            } else {
                label = "Area"
            }
        }
        draft.elementLabel = label
        draft.computedStyles = styles
        // Stamp scroll offsets + element snapshot on the annotation's
        // extras bag so PinOverlayView's pin-follow-scroll math keeps
        // working after the user saves (PinModel.from reads extras for
        // `initialScrollX/Y`).
        var extras = draft.ann.extras
        extras["element"] = contextJSON
        extras["initialScrollX"] = .number(scrollX)
        extras["initialScrollY"] = .number(scrollY)
        draft.ann.extras = extras
        pinDrafts[annId] = draft

        let payload = PinEditPayload(
            id: draft.ann.id,
            num: draft.ann.num,
            color: draft.ann.color,
            comment: draft.ann.comment,
            elementLabel: draft.elementLabel,
            screenshot: draft.screenshotImage,
            computedStyles: draft.computedStyles,
            edits: draft.ann.edits,
            isNew: true
        )
        presentPinEditor(payload)
    }

    /// `NativeBridge` routes `wf-dom-screenshot` follow-ups here when
    /// the `annId` belongs to a `pinDraft`. Decodes the data-URL into
    /// an `NSImage`, stores it on the draft (so a save commits the
    /// image into `extras["element"].screenshot`), and pokes the open
    /// modal to render the thumb. Silent no-op if the draft has been
    /// discarded (user canceled) or the URL is malformed.
    func handleInspectScreenshot(annId: String, dataURL rawDataURL: String) {
        guard var draft = pinDrafts[annId] else { return }
        let dataURL = ImageOptimizer.optimize(dataURL: rawDataURL, use: .commentScreenshot)
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let image = NSImage(data: data) else { return }
        draft.screenshotImage = image
        // Also fold the dataURL string into `extras["element"].screenshot`
        // so the committed annotation round-trips byte-for-byte through
        // the JS `ann.element.screenshot` path that the annotation panel
        // renders thumbs from. The image object on the draft is what
        // the pin editor's thumb uses at present time.
        if case .object(var elDict) = draft.elementJSON {
            elDict["screenshot"] = .string(dataURL)
            draft.elementJSON = .object(elDict)
            draft.ann.extras["element"] = .object(elDict)
        }
        pinDrafts[annId] = draft
        pinEditorModal?.updateScreenshot(image, forId: annId)
    }

    init(document: WebFramesDocument) {
        self.document = document
        self.bridge = NativeBridge()
        self.canvasBackdrop = CanvasBackdropView(frame: .zero)
        self.frameLayer = FrameLayerView()
        self.linkLayer = LinkLayerView(frame: .zero)
        self.dock = DockView()
        self.annotationPanel = AnnotationPanel()
        // Brand-row ivars (logoView / logoLabel / logoStack) were removed
        // in Step 3 — the wordmark is now a window-level centerX-top stack
        // owned by `DocumentWindowController`, which reuses this file's
        // `loadRendererLogo()` helper to load the same `logo.svg` asset.
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = WFDesign.bg.cgColor

        // Backdrop first (bottom of z-order) — the dot grid paints onto
        // the bare host. Phase 6e Step 70e deleted the canvas WKWebView
        // that used to sit above it (with a transparent body for the
        // dots to show through); per-frame WKWebViews + the native link
        // layer are the only painters above this now.
        addSubview(canvasBackdrop)
        addSubview(frameLayer)
        // Link layer sits ABOVE frames so bezier arrows render on top of
        // frame chrome — matches the pre-migration layering where `.dc`
        // (2D link canvas) was stacked above `.cv` (frames) in the
        // canvas WKWebView. `hitTest` returns nil so pointer events fall
        // through to frames / the canvas WKWebView untouched.
        addSubview(linkLayer)
        // Annotation cursor shield — transparent, hit-test pass-through,
        // registers a crosshair cursor rect when annotation mode is on.
        // Added right after linkLayer so it sits above frames; the dock,
        // annotation panel, sidebar (and anything added later) are still
        // above it in z-order, which is what we want: crosshair only over
        // canvas/frames, default cursor over UI chrome.
        annotationCursorShield.translatesAutoresizingMaskIntoConstraints = true
        annotationCursorShield.autoresizingMask = [.width, .height]
        annotationCursorShield.frame = bounds
        annotationCursorShield.isHidden = true
        annotationCursorShield.onPointerMove = { [weak self] windowPoint in
            self?.updateAnnotationHighlight(atWindowPoint: windowPoint)
        }
        annotationCursorShield.onPointerExit = { [weak self] in
            self?.clearAnnotationHighlight()
        }
        addSubview(annotationCursorShield)
        panCursorShield.translatesAutoresizingMaskIntoConstraints = true
        panCursorShield.autoresizingMask = [.width, .height]
        panCursorShield.frame = bounds
        panCursorShield.isHidden = true
        addSubview(panCursorShield)
        installEmptyState()
        // Dock placement moved out of `CanvasHost` on 2026-04-21 evening
        // (sidebar-refactor Step 3 follow-up). Egor flagged that the
        // dock "rode" the main pane — because it was pinned to
        // `canvasHost.centerXAnchor`, opening/closing the sidebar
        // shifted the dock horizontally along with the main pane. The
        // dock is now placed by `DocumentWindowController.configureDockPlacement()`
        // and pinned to `window.contentView.centerXAnchor` /
        // `bottomAnchor - 16`, so it stays strictly window-centered
        // regardless of sidebar state.
        //
        // Ownership remains here: `let dock: DockView` is still a
        // stored property on the host and `dock.delegate = self` is still
        // assigned below — only the VIEW-TREE parent changed. The dock
        // is added as a non-arranged subview of the `NSSplitView` (the
        // window's content view), which naturally sits above both the
        // sidebar pane and the canvas pane in z-order, preserving the
        // "dock occludes frames where they overlap" property that was
        // the whole point of the native-dock migration.
        // (The dock's sidebar-toggle button was removed later the same
        // day, so there's no longer any back-channel between the split
        // VC's KVO and a dock-side `setSidebarOpen`.)
        // Annotation panel: still above the per-frame layer so it occludes
        // frames naturally, but since 2026-04-21 it matches the left
        // `FramesSidebar`'s native `NSVisualEffectView(.sidebar)` style
        // (Egor: "правый сайд бар с анотациями сделай таким же нативным
        // по стилю как левый"). The panel is now flush to the trailing /
        // top / bottom edges of the canvas pane — no 16pt inset, no
        // rounded chrome. The window's own corner rounding clips the
        // outer top-right / bottom-right corners visually, same as
        // Mail / Notes sidebars. Width stays 280 to match the original
        // Liquid-Glass version so existing annotation rows don't reflow.
        // Hosted by the document's native inspector split item.
        annotationPanel.delegate = self
        // Phase 6e sidebar-refactor Step 1: the Frames sidebar used to be
        // a child of this host (a floating glass panel with a slide-in
        // animation from the leading edge). It now lives in a native
        // `NSSplitViewItem(.sidebar)` owned by `DocumentSplitViewController`,
        // so there's no `addSubview(sidebar)` / constraints / delegate
        // wiring here anymore — the split VC creates the sidebar VC and
        // back-wires `canvasHost.sidebar` (weak) + the row-click delegate
        // itself. We still conform to `FramesSidebarDelegate` below so
        // row-click → `selectFrame` + viewport pan keeps working.
        //
        // Sidebar-refactor Step 3 (2026-04-21 evening): the host used to
        // also own `logoStack` — a 26×17 `logo.svg` + "web frames"
        // wordmark pinned 92pt from the leading edge, just past the
        // traffic lights. The wordmark is now a window-level overlay
        // centered at the top, built by `DocumentWindowController`
        // using the `loadRendererLogo()` helper below. Nothing replaces
        // the setup block here — the host no longer carries a brand row.
        //
        // Step 3 follow-up (2026-05-03): `addSubview(titlebarDragView)`
        // used to live here too — a 38pt transparent strip pinned to the
        // top of canvasHost so users could drag the window from above the
        // canvas. Removed because `NSToolbar` in `.unified` style with a
        // trailing `.flexibleSpace` already makes the whole title band
        // window-draggable. See `DocumentWindowController` toolbar setup.

        bridge.frameLayer = frameLayer
        bridge.document = document
        bridge.canvasHost = self
        // Phase 6e Step 70e: dock actions are Swift-native now. See the
        // `DockViewDelegate` conformance above — previously the delegate
        // was `bridge`, which serialized clicks back to JS as
        // `dock-action` envelopes.
        dock.delegate = self

        // Phase 6e Step 2: native click/hover on link bezier curves.
        // See `linkLayer(_:didClickLink:)` / `linkLayer(_:didHoverLink:)`
        // below — CanvasHost owns the ephemeral selection state.
        linkLayer.delegate = self

        // Phase 6e Step 70e: the workspace observer is the sole sink
        // for native UI updates now that the canvas WKWebView is gone.
        // The three push paths that used to run in parallel
        // (`pushAnnotationsToNative`, `pushPinsToAllFrames`,
        // `pushLinksToNative`) were JS-originated through the canvas
        // channel; with the canvas channel deleted, this observer is
        // the only way native UI hears about mutations.
        installWorkspaceObserver()

        // Phase 6e Step 70e polish #4: accept image-file drops onto the
        // canvas. The old JS path (`cw.addEventListener('drop',...)` in
        // `index.html` around line 1097) went away with Step 70e's bulk
        // delete; without a native replacement, dragging an image onto
        // the window was silently eaten. Registering here turns
        // `CanvasHost` into the drop target for the whole document
        // surface; `performDragOperation` below routes each image
        // through `AddFrameSpecApplier` and into `workspace.createFrame`.
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, managedServerProcess != nil {
            pendingServerRestart = nil
            stopManagedServer()
        }
    }

    /// Explicit end of life for the document view. `CanvasHost` has no
    /// `deinit` work of its own: the observers, the web-source probe loop
    /// and the child process all keep running until told otherwise, and the
    /// WKWebViews are only released through `FrameManager.destroyFrame`.
    /// Called from `DocumentWindowController.windowWillClose` and from
    /// `applicationWillTerminate`. Idempotent.
    func tearDown() {
        workspaceSubscription = nil
        webSourceMonitorTask?.cancel()
        webSourceMonitorTask = nil
        monitoredWebSource = nil
        pendingServerRestart = nil
        stopManagedServer()
        bridge.destroyAllFrames()
        liveFrameIds.removeAll()
        liveFrameImageKinds.removeAll()
    }

    // MARK: - Workspace observer (Phase 6e Step 0)

    /// Subscribe to the document's `WorkspaceStore` so every mutation
    /// (create / move / resize / delete, annotation save, link drag, …)
    /// fans out into the three native UI feeds. `observe(_:)` also fires
    /// the callback once synchronously on registration, so the initial
    /// workspace state (even if just empty arrays) reaches the
    /// reconcilers immediately.
    ///
    /// Capture is `[weak self]` to avoid a retain cycle: the store is
    /// owned by the document, which outlives the host when the window
    /// closes but the document stays open (unlikely today, but cheap
    /// insurance). `Subscription.deinit` unregisters when the ivar
    /// drops, so tear-down is automatic.
    // MARK: - Empty state
    //
    // Shown while the project has no frames. (The sample project stays in
    // Help › Open Sample Project.)
    private let emptyState = NSStackView()

    private func installEmptyState() {
        let title = NSTextField(labelWithString: "Start with a frame")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = WFDesign.text
        let subtitle = NSTextField(wrappingLabelWithString: "Add a live localhost page, a GitHub page or a screenshot.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = WFDesign.text2
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = 360
        let add = NSButton(title: "Add Frame…", target: self, action: #selector(emptyStateAddFrame))
        add.bezelStyle = .rounded
        add.controlSize = .large
        add.keyEquivalent = ""
        add.setAccessibilityIdentifier("canvas.empty.addFrame")
        let buttons = NSStackView(views: [add])
        buttons.spacing = 10
        emptyState.setViews([title, subtitle, buttons], in: .center)
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 12
        emptyState.setCustomSpacing(20, after: subtitle)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -40),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    @objc private func emptyStateAddFrame() { presentAddFrameModal() }

    private func installWorkspaceObserver() {
        guard let document else { return }
        workspaceSubscription = document.workspace.observe { [weak self] in
            self?.refreshNativeViewsFromWorkspace()
        }
    }

    /// Rebuild the three native UI feeds from the current
    /// `WorkspaceStore` snapshot:
    ///
    ///   * `[AnnotationInfo]`          → `AnnotationPanel.setAnnotations`
    ///   * `[String: [PinModel]]`      → `bridge.setFramePins(frameId:pins:)`
    ///   * `[NativeLink]`              → `linkLayer.setLinks`
    ///
    /// Conversion logic lives on the model types themselves
    /// (`WorkspaceStoreViewModel.swift`) — ported verbatim from the JS
    /// serializers so outputs match the JS path byte-for-byte through
    /// Step 0's parallel phase.
    ///
    /// Link selection / hover flags come from this host's own
    /// `selectedLinkId`/`hoveredLinkId` (Phase 6e Step 2). Both the JS
    /// `links-set` envelope and this path query the same source, so
    /// whichever fires last produces consistent flags — no cache to
    /// stale out of sync.
    private var mappedSourceURLs: [String: String] = [:]

    private func refreshNativeViewsFromWorkspace() {
        guard let workspace = document?.workspace else { return }

        updateWebSourceMonitor(for: workspace.projectMap)

        // Viewport → native painters (Phase 6e Step 1). Both views have
        // their own `guard` against no-op pushes, so firing on every
        // mutation (not just `.viewportChanged`) is free when panY/scale
        // stayed put. Running this before the annotation/pin rebuilds
        // means any arrows we paint in step three have the right
        // transform already locked in — avoids a one-frame drift when
        // a mutation both moves a frame *and* nudges the viewport.
        canvasBackdrop.setView(
            scale: workspace.viewport.scale,
            px:    workspace.viewport.panX,
            py:    workspace.viewport.panY
        )
        linkLayer.setView(
            scale: workspace.viewport.scale,
            px:    workspace.viewport.panX,
            py:    workspace.viewport.panY
        )

        // Pan / zoom only moves the frame cards; comments, pins and the
        // sidebar selection are unaffected. Skipping their rebuild here is
        // what keeps scrolling smooth on boards with many comments — each
        // rebuild decoded every comment screenshot and recreated the
        // panel's rows.
        var viewportOnly = false
        if case .viewportChanged = workspace.mutationInFlight { viewportOnly = true }

        if !viewportOnly {
        emptyState.isHidden = !workspace.frames.isEmpty
        // Annotations → AnnotationPanel. Resolve the current frame for
        // each annotation so the panel shows the user-renamed label +
        // current viewport, not a stale snapshot from drop time.
        let infos: [AnnotationInfo] = workspace.annotations.map { ann in
            AnnotationInfo.from(annotation: ann,
                                frame: workspace.frame(id: ann.frameId))
        }
        annotationPanel.setAnnotations(infos)

        // Frames → sidebar is now driven by `FramesSidebarViewController`'s
        // own workspace observer (Phase 6e sidebar-refactor Step 1). The
        // selection highlight still flows through the host's weak sidebar
        // ref on `selectFrame` / `clearFrameSelectionIfNeeded` — stamp it
        // here too so the initial-open path (observer fires once with the
        // current state on register) seeds the selection ring correctly
        // even when the sidebar loaded its rows before the host did.
        sidebar?.setSelectedFrameID(selectedFrameId)

        // Pins → per-frame overlays. Seed the bucket map with every
        // live frame id so frames with zero annotations get an explicit
        // empty push — otherwise a delete-all-pins-in-one-frame
        // wouldn't clear the overlay.
        var byFrame: [String: [PinModel]] = [:]
        for f in workspace.frames { byFrame[f.id] = [] }
        for ann in workspace.annotations where byFrame[ann.frameId] != nil {
            byFrame[ann.frameId, default: []].append(PinModel.from(ann))
        }
        for (frameId, pins) in byFrame {
            bridge.setFramePins(frameId: frameId, pins: pins)
        }
        } // !viewportOnly

        // Phase 6e Step 7: frame card visual rects from the workspace.
        // Formula matches JS `wfSyncFrameRects`:
        //     x_screen = f.x * scale + panX
        //     y_screen = f.y * scale + panY
        //     w_screen = (f.w + CardGeometry.chromeWidth)  * scale   (+2 for the card border)
        //     h_screen = (f.h + CardGeometry.chromeHeight) * scale   (+35 for header + border)
        // Logical size is the page viewport the WKWebView renders at;
        // FrameContainer's CALayer transform scales that to the visual
        // rect so media queries don't flip to mobile when zoomed out.
        // Holes stay empty under native — chrome that used to punch
        // through (dock, annotation panel, pin editor, add-frame modal)
        // is all native now and sits above the frame layer in z-order.
        // (Phase 6e Step 70e eliminated the last canvas-WKWebView DOM
        // holdouts — the old `.hd-help` tooltip + `.pill-bar` quick-add
        // were part of `index.html`, now deleted.)
        //
        // Step 4 overlay: `frameWithLivePreview` swaps in the in-flight
        // drag position / resize size for the frame currently being
        // manipulated. This is the piece that keeps the card pinned to
        // the pointer between gesture start and the `moveFrame` /
        // `resizeFrame` commit — the workspace itself hasn't changed yet,
        // but the visual rect needs to reflect the drag-in-progress so
        // the user isn't dragging a stationary ghost.
        //
        // `logicalSize` intentionally comes from the *baseline* workspace
        // frame, not the live preview. `FrameContainer.updateLayout`
        // relayouts the WKWebView whenever `logicalSize` changes — at
        // mousemove rate that's a bad bargain. Keeping it pinned to the
        // anchor size means only the CALayer visual transform stretches
        // during a resize preview (cheap), and the WKWebView relayouts
        // exactly once when `.resizeEnd` commits and the observer fires
        // with the new workspace size. Matches the JS path's
        // `wfFrameApplySize(f,...,false)` where the third-arg-false
        // suppresses the page relayout during the drag.
        let scale = workspace.viewport.scale
        let px    = workspace.viewport.panX
        let py    = workspace.viewport.panY
        dock.setZoomPercent(Int((scale * 100).rounded()))

        // Phase 6e Step 70c: native frame WKWebView lifecycle. Before
        // this step, JS `renderFrame` called `NativeAPI.createFrame` to
        // spawn the per-frame webview and `applyDocState` called
        // `NativeAPI.destroyFrame` for frames removed by the document
        // round-trip. Now we diff the workspace frame IDs against
        // `liveFrameIds` and drive the same FrameManager entry points
        // directly — the JS calls are gone (see renderFrame /
        // applyDocState in index.html).
        //
        // Phase 6e Step 70e polish #5b: image frames are now native too.
        // Before this step, image frames were excluded from the diff —
        // the JS DOM `<img>` path in `index.html` rendered them. Step 70e
        // deleted index.html, so the old exclusion silently orphaned every
        // image frame: the workspace model got a new entry but nothing
        // appeared on screen. We now include image frames in the set and
        // branch on `isImage` below: after `createFrameView` instantiates
        // a normal WKWebView-backed card, `loadImageInFrame` feeds the
        // base64 `data:` URL from `FrameModel.extras["imgUrl"]` through
        // `FrameManager.loadImageDataURL`, which wraps it in a minimal
        // HTML shell. The `image://<label>` URL is still the frame's
        // canonical URL (so persistence / identity are unchanged), but
        // `FrameManager.createFrame` skips `webView.load` for that
        // scheme — the HTML load happens via the follow-up call here.
        //
        // Destroy must run before create in case of a swap (same id
        // replaced), but `WorkspaceStore.createFrame` rejects duplicate
        // IDs so in practice there is never both a remove and an add
        // on the same id in one tick. Still, process removes first —
        // if a future undo path reinstates a removed frame inside the
        // same observer tick, the destroy ahead of the create keeps
        // FrameManager's cache clean.
        let allFrameIds = Set(workspace.frames.map(\.id))
        let removedIds = liveFrameIds.subtracting(allFrameIds)
        let kindChangedIds = Set(workspace.frames.compactMap { frame -> String? in
            guard let oldKind = liveFrameImageKinds[frame.id], oldKind != frame.isImage else { return nil }
            return frame.id
        })
        for removedId in removedIds.union(kindChangedIds) {
            bridge.destroyFrameView(id: removedId)
        }
        let retainedIds = liveFrameIds.intersection(allFrameIds).subtracting(kindChangedIds)
        for frame in workspace.frames {
            if let old = mappedSourceURLs[frame.id], old != frame.url, retainedIds.contains(frame.id) {
                bridge.loadURLInFrameView(id: frame.id, url: frame.url)
            }
        }
        mappedSourceURLs = Dictionary(uniqueKeysWithValues: workspace.frames.map { ($0.id, $0.url) })
        liveFrameImageKinds = Dictionary(uniqueKeysWithValues: workspace.frames.map { ($0.id, $0.isImage) })
        let additions = allFrameIds.subtracting(retainedIds)
        if !additions.isEmpty {
            // Seed the new card's visual rect directly from the
            // workspace + viewport — same formula the rect push below
            // uses, so the WKWebView boots with its final card size
            // and doesn't flash at `0,0` for one runloop turn. We use
            // the baseline (no live preview) since a newly-created
            // frame can't also be mid-drag.
            for frame in workspace.frames where additions.contains(frame.id) {
                let cardRect = CGRect(
                    x: frame.x * scale + px,
                    y: frame.y * scale + py,
                    width:  (frame.w + CardGeometry.chromeWidth)  * scale,
                    height: (frame.h + CardGeometry.chromeHeight) * scale
                )
                bridge.createFrameView(
                    id: frame.id, url: frame.url,
                    cardRect: cardRect,
                    logicalSize: CGSize(width: frame.w, height: frame.h)
                )
                if frame.isImage,
                   case .string(let dataURL) = frame.extras["imgUrl"] ?? .null,
                   !dataURL.isEmpty {
                    bridge.loadImageInFrame(id: frame.id, dataURL: dataURL)
                }
            }
        }
        liveFrameIds = allFrameIds
        bridge.setFrameOrder(workspace.frames.map(\.id))

        for baseFrame in workspace.frames {
            let f = frameWithLivePreview(baseFrame)
            let cardRect = CGRect(
                x: f.x * scale + px,
                y: f.y * scale + py,
                width:  (f.w + CardGeometry.chromeWidth)  * scale,
                height: (f.h + CardGeometry.chromeHeight) * scale
            )
            bridge.setFrameCardRect(
                id: f.id,
                cardRect: cardRect,
                logicalSize: CGSize(width: baseFrame.w, height: baseFrame.h),
                holes: []
            )
            // Phase 6e follow-up: native chrome push. Previously JS
            // `pushFrameCardsToNative` filled the header num/label/source
            // pill; that path was retired along with the canvas webview,
            // and without a replacement every card showed `num: 0` / empty
            // title. Derive the baseline directly from the workspace and
            // hand it to the bridge — selection/drop-target overlays sit
            // on top of this in `renderCardState`.
            if viewportOnly { continue }   // chrome text/size does not depend on the viewport
            bridge.setFrameCardBaseline(
                id: baseFrame.id,
                num: baseFrame.num,
                label: baseFrame.label,
                sourceLabel: sourceLabel(for: baseFrame),
                url: baseFrame.url,
                w: f.w,
                h: f.h,
                annotationMode: annotationMode,
                isImage: baseFrame.isImage,
                canRestoreLive: {
                    if case .string(let url) = baseFrame.extras["snapshotSourceURL"] ?? .null {
                        return !url.isEmpty
                    }
                    return false
                }()
            )
        }

        pushLinksFromWorkspace()
    }

    /// Derive the short source-pill label shown in the frame header
    /// (e.g. "github.com", "local:3000", "finder"). Replaces the JS
    /// `badgeFor` helper that lived in index.html pre-Phase 6e.
    private func sourceLabel(for frame: FrameModel) -> String {
        if frame.isImage { return "finder" }
        guard let url = URL(string: frame.url) else { return "" }
        if url.scheme == "file" { return "finder" }
        guard let host = url.host, !host.isEmpty else { return frame.url }
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if trimmed == "localhost" || trimmed == "127.0.0.1" {
            if let port = url.port { return "local:\(port)" }
            return "local"
        }
        return trimmed
    }

    /// Rebuilds just the `LinkLayerView` feed from the current
    /// workspace snapshot. Called from the full refresh above AND from
    /// the `LinkLayerView` delegate methods when only the ephemeral
    /// selection/hover flipped — in that case rebuilding annotations
    /// and pin overlays would be pure waste.
    ///
    /// Skip links whose endpoints have been deleted — matches the JS
    /// guard in `pushLinksToNative` and avoids painting ghost arrows in
    /// the gap between a frame delete cascade and the link cleanup
    /// sweep.
    private func pushLinksFromWorkspace() {
        guard let workspace = document?.workspace else { return }
        // Step 4: endpoints resolve through `frameWithLivePreview` so a
        // dragging / resizing frame carries its live preview position
        // and size into `frameAnchor(_:side:)`. Without this, arrows
        // visibly tear away from the card during a drag — the workspace
        // value is still the pre-drag origin until `.dragEnd` commits.
        let frameById = Dictionary(
            uniqueKeysWithValues: workspace.frames.map { ($0.id, frameWithLivePreview($0)) }
        )
        let nativeLinks: [NativeLink] = workspace.links.compactMap { link in
            guard let from = frameById[link.fromId],
                  let to   = frameById[link.toId] else { return nil }
            return NativeLink.from(
                link: link,
                fromFrame: from,
                toFrame: to,
                selected: link.id == selectedLinkId,
                hovered:  link.id == hoveredLinkId
            )
        }
        let linkObstacles = Array(frameById.values).map { frame in
            CGRect(x: frame.x, y: frame.y,
                   width: frame.w + CardGeometry.chromeWidth, height: frame.h + CardGeometry.chromeHeight)
        }
        linkLayer.setLinks(nativeLinks, obstacles: linkObstacles)
    }

    // MARK: - LinkLayerViewDelegate (Phase 6e Step 2)

    /// User clicked on a link curve. Make it the selection (drops any
    /// prior link selection). Also sweeps `hoveredLinkId` to nil so a
    /// stray `.selected + .hovered` doesn't happen mid-state. Under
    /// Phase 6e Step 3 we also clear any frame selection so
    /// Delete/Backspace targets the link unambiguously (mirrors JS
    /// `selF`'s reverse sweep: "Frame and link selection are mutually
    /// exclusive").
    func linkLayer(_ layer: LinkLayerView, didSetBends bends: [CGFloat]?, forLink id: String) {
        document?.workspace.setLinkBends(id: id, bends: bends)
    }

    func linkLayer(_ layer: LinkLayerView, didClickLink id: String) {
        clearFrameSelectionIfNeeded()
        guard selectedLinkId != id else { return }
        selectedLinkId = id
        hoveredLinkId = nil
        pushLinksFromWorkspace()
    }

    /// Pointer moved onto / off a curve. `id == nil` means the cursor is
    /// not near any curve. We never flag a link as both `selected` and
    /// `hovered` — a selected link keeps its selection ring even while
    /// the cursor lingers on it. Mirrors JS `pushLinksToNative`'s
    /// `hovered:!isSelected && l.id===hoveredLinkId`.
    func linkLayer(_ layer: LinkLayerView, didHoverLink id: String?) {
        let next = (id == selectedLinkId) ? nil : id
        guard hoveredLinkId != next else { return }
        hoveredLinkId = next
        pushLinksFromWorkspace()
    }

    /// Called from the window-level mouseDown monitor when the user
    /// clicks somewhere that isn't a link curve. If we had a link
    /// selected, clear it and repaint. No-op otherwise so we don't churn
    /// the shape layer tree on every background click.
    func clearLinkSelectionIfNeeded() {
        guard selectedLinkId != nil else { return }
        selectedLinkId = nil
        pushLinksFromWorkspace()
    }

    /// Called from the window-level keyDown monitor when the user hits
    /// Delete/Backspace with a link selected. Routes through
    /// `WorkspaceStore.deleteLink` so the delete is undoable (the
    /// store's `.linkDeleted` mutation case triggers the
    /// `registerUndo(for:)` path in `WebFramesDocument`).
    func deleteSelectedLink() -> Bool {
        guard let id = selectedLinkId else { return false }
        selectedLinkId = nil
        hoveredLinkId = nil
        document?.workspace.deleteLink(id: id)
        return true
    }

    // MARK: - Frame selection (Phase 6e Step 3)

    /// Make `id` the selected frame. Mutually exclusive with link
    /// selection — any prior link selection/hover is cleared so
    /// Delete/Backspace has an unambiguous target.
    ///
    /// Repaints affected cards (prior selection off, new selection on)
    /// through `FrameManager.setCardChrome` instead of rebuilding the
    /// entire chrome state from JS. That keeps the Swift-owned bit
    /// authoritative even while the JS `pushFrameCardsToNative` still
    /// fires in parallel with `selected: false` for every frame.
    ///
    /// Also repaints links — selection transitions don't change link
    /// geometry, but `pushLinksFromWorkspace` is cheap (a single
    /// CAShapeLayer reconcile) and keeps any stale ring state clean.
    func setFrameSelection(_ ids:[String]) {
        let previous = selectedFrameIDs
        var seen = Set<String>()
        selectedFrameIDs = ids.filter { document?.workspace.frame(id: $0) != nil && seen.insert($0).inserted }
        selectedFrameId = selectedFrameIDs.last
        updateArrangementBar()
        selectedLinkId = nil;hoveredLinkId = nil
        for id in Set(previous + selectedFrameIDs) {bridge.repaintFrameChrome(id:id)}
        sidebar?.setSelectedFrameID(selectedFrameId);pushLinksFromWorkspace();onFrameSelectionChanged?()
    }
    private var lastSelectionEvent: Int?
    /// Frame a Shift/⌘-press just removed from the selection, so a drag
    /// starting from the same press can put it back (see beginFrameDrag).
    private var pendingAdditiveDeselect: (id: String, event: Int)?
    func selectFrame(_ id: String) {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown {
            guard lastSelectionEvent != event.eventNumber else { return }
            lastSelectionEvent = event.eventNumber
        }
        let additive = NSApp.currentEvent?.modifierFlags.intersection([.shift,.command]).isEmpty == false
        if additive, selectedFrameIDs.contains(id), let event = NSApp.currentEvent {
            pendingAdditiveDeselect = (id, event.eventNumber)
        }
        selectFrame(id,additive:additive)
    }
    func selectFrame(_ id:String,additive:Bool) {
        if additive {
            setFrameSelection(selectedFrameIDs.contains(id) ? selectedFrameIDs.filter { $0 != id } : selectedFrameIDs + [id])
        } else if !selectedFrameIDs.contains(id) {setFrameSelection([id])}
    }

    private let arrangementBar = NSStackView()
    private var arrangementButtons: [FrameArrangement: NSButton] = [:]
    private func updateArrangementBar() {
        if arrangementBar.superview == nil {
            for (index, action) in FrameArrangement.allCases.enumerated() {
                if index == 3 || index == 8 { arrangementBar.addArrangedSubview(Self.arrangementSeparator()) }
                if index == 6 { arrangementBar.addArrangedSubview(distributeSeparator) }
                let image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: action.rawValue)
                    ?? NSImage(systemSymbolName: "square.dashed", accessibilityDescription: action.rawValue)!
                let button = NSButton(image: image, target: self, action: #selector(arrangeFromToolbar(_:)))
                button.tag = index
                button.isBordered = false
                button.bezelStyle = .regularSquare
                button.imagePosition = .imageOnly
                button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                button.contentTintColor = WFDesign.text
                button.toolTip = "\(action.rawValue)  \(action.shortcutLabel)"
                button.setAccessibilityLabel(action.rawValue)
                button.setAccessibilityIdentifier("canvas.arrange.\(index)")
                button.widthAnchor.constraint(equalToConstant: 30).isActive = true
                button.heightAnchor.constraint(equalToConstant: 28).isActive = true
                arrangementButtons[action] = button
                arrangementBar.addArrangedSubview(button)
            }
            arrangementBar.spacing = 2
            arrangementBar.wantsLayer = true
            arrangementBar.layer?.backgroundColor = WFDesign.bg2.cgColor
            arrangementBar.layer?.cornerRadius = 10
            arrangementBar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
            arrangementBar.setAccessibilityLabel("Align and distribute")
            arrangementBar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(arrangementBar)
            NSLayoutConstraint.activate([arrangementBar.topAnchor.constraint(equalTo: topAnchor, constant: 58),
                                         arrangementBar.centerXAnchor.constraint(equalTo: centerXAnchor)])
        }
        arrangementBar.isHidden = selectedFrameIDs.count < 2
        // Distributing needs three frames; with two the buttons are hidden
        // rather than shown greyed out, which read as broken.
        for (action, button) in arrangementButtons { button.isHidden = !canArrange(action) }
        distributeSeparator.isHidden = !canArrange(.horizontalSpacing)
    }
    private let distributeSeparator = CanvasHost.arrangementSeparator()
    private static func arrangementSeparator() -> NSView {
        let line = NSBox(); line.boxType = .separator
        line.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return line
    }
    func isArrangementBarRegion(_ point: CGPoint) -> Bool { !arrangementBar.isHidden && arrangementBar.superview != nil && arrangementBar.frame.contains(point) }
    func canArrange(_ action: FrameArrangement) -> Bool { arrangementTargets(action).count >= action.minimumSelection }
    /// Frames an action applies to: the selection, or for Tidy Up with
    /// fewer than two selected, the whole board.
    private func arrangementTargets(_ action: FrameArrangement) -> [FrameModel] {
        guard let frames = document?.workspace.frames else { return [] }
        let selected = frames.filter { selectedFrameIDs.contains($0.id) }
        return action == .tidyUp && selected.count < 2 ? frames : selected
    }
    @objc private func arrangeFromToolbar(_ sender: NSButton) {
        guard FrameArrangement.allCases.indices.contains(sender.tag) else { return }
        arrangeSelection(FrameArrangement.allCases[sender.tag])
    }
    func canRestack(_ move: FrameStacking) -> Bool {
        guard let ids = document?.workspace.frames.map(\.id), !selectedFrameIDs.isEmpty else { return false }
        return move.reordered(ids, selected: Set(selectedFrameIDs)) != ids
    }
    /// Figma-style layer order for the selection; one undo step ("Reorder Frames").
    func restackSelection(_ move: FrameStacking) {
        guard let workspace = document?.workspace else { return }
        let ids = workspace.frames.map(\.id)
        let next = move.reordered(ids, selected: Set(selectedFrameIDs))
        guard next != ids else { return }
        workspace.reorderFrames(next)
        document?.undoManager?.setActionName(move.rawValue)
    }

    /// Aligns or distributes the selected frames as one undo step.
    func arrangeSelection(_ action: FrameArrangement) {
        guard canArrange(action) else { return }
        moveSelection(to: action.positions(for: arrangementTargets(action)), action: action.rawValue)
    }
    private func moveSelection(to positions: [String: CGPoint], action: String) {
        guard let document, !positions.isEmpty else { return }
        document.undoManager?.beginUndoGrouping()
        for (id, position) in positions { document.workspace.moveFrame(id: id, to: position) }
        document.undoManager?.setActionName(action)
        document.undoManager?.endUndoGrouping()
    }

    private var marqueeStart: CGPoint?
    private var marqueeBase: [String] = []
    private let marqueeLayer = CAShapeLayer()
    var isMarqueeSelecting: Bool { marqueeStart != nil }
    func beginMarquee(at point: CGPoint, additive: Bool) {
        marqueeStart = point; marqueeBase = additive ? selectedFrameIDs : []
        setFrameSelection(marqueeBase)
        wantsLayer = true
        marqueeLayer.fillColor = WFDesign.accent.withAlphaComponent(0.12).cgColor
        marqueeLayer.strokeColor = WFDesign.accent.cgColor
        marqueeLayer.lineWidth = 1
        marqueeLayer.zPosition = 1000
        layer?.addSublayer(marqueeLayer)
    }
    func updateMarquee(at point: CGPoint) {
        guard let start = marqueeStart, let workspace = document?.workspace else { return }
        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x-start.x), height: abs(point.y-start.y))
        marqueeLayer.path = CGPath(rect: rect, transform: nil)
        let a = worldPoint(clientX: rect.minX, clientY: bounds.height - rect.maxY)
        let b = worldPoint(clientX: rect.maxX, clientY: bounds.height - rect.minY)
        let worldRect = CGRect(x: a.x, y: a.y, width: b.x-a.x, height: b.y-a.y)
        let hits = workspace.frames.filter { worldRect.intersects(CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h)) }.map(\.id)
        setFrameSelection(marqueeBase + hits)
    }
    func cancelMarquee() { setFrameSelection(marqueeBase); endMarquee() }
    func endMarquee() { marqueeStart = nil; marqueeBase = []; marqueeLayer.removeFromSuperlayer(); marqueeLayer.path = nil }

    /// Drop the frame selection if any. Called from the window-level
    /// mouseDown monitor when the user clicks somewhere that isn't a
    /// frame card (and isn't a link curve — the link deselect monitor
    /// runs first and returns without touching frame state when it
    /// finds a link under the pointer).
    func clearFrameSelectionIfNeeded() {
        guard !selectedFrameIDs.isEmpty else {return};setFrameSelection([])
    }

    /// Called from the window-level keyDown monitor when the user hits
    /// Delete/Backspace with a frame selected (and no link selected).
    /// Routes through `WorkspaceStore.deleteFrame` so the delete is
    /// undoable and cascades annotations + links through the same path
    /// JS's `workspaceDeleteFrame` uses. Returns true if consumed.
    func deleteSelectedFrame() -> Bool {
        guard !selectedFrameIDs.isEmpty, let document else { return false }
        let ids = selectedFrameIDs
        setFrameSelection([])
        document.undoManager?.beginUndoGrouping()
        for id in ids { document.workspace.deleteFrame(id: id) }
        document.undoManager?.setActionName("Delete Frames")
        document.undoManager?.endUndoGrouping()
        return true
    }

    // MARK: - Frame-card intents (Phase 6e Step 70d)
    //
    // `FrameManager.frameCard(_:didEmit:)` used to serialize close, reload,
    // size-preset, size-commit, and title-commit into `frame-intent`
    // envelopes and `bridge.forwardToCanvas(msg)` them at JS, which then
    // round-tripped back via `NativeAPI.workspace*`. Swift is authoritative
    // now — we commit directly. All five helpers are no-ops on unknown ids
    // because the underlying `WorkspaceStore` mutations already guard
    // against missing frames, so a stale intent arriving from a
    // mid-destroy card costs a single dictionary miss.

    /// Close the frame (undoable, cascades annotations + links). Mirrors
    /// `deleteSelectedFrame` above but keyed by the card that emitted the
    /// close intent. If the closing card was also the selection target,
    /// clear the selection so the next chrome repaint doesn't carry a
    /// stale `selectedFrameId` pointing at a vanished frame.
    func closeFrame(id: String) {
        if selectedFrameIDs.contains(id) {setFrameSelection(selectedFrameIDs.filter {$0 != id})}
        document?.workspace.deleteFrame(id: id)
    }

    /// Re-open the frame's saved URL. An explicit load is required when the
    /// first provisional navigation failed while a local server was offline:
    /// in that state WKWebView has no committed page for `reload()` to retry.
    func reloadFrame(id: String) {
        guard let frame = document?.workspace.frame(id: id), !frame.isImage else { return }
        bridge.loadURLInFrameView(id: id, url: frame.url)
    }

    func reloadProjectWebFrames() {
        for frame in document?.workspace.frames ?? [] where !frame.isImage {
            reloadFrame(id: frame.id)
        }
    }

    /// Replace a live web renderer with a persisted viewport snapshot while
    /// keeping the frame id intact, so links and comments stay attached.
    func freezeFrameAsSnapshot(id: String) {
        guard !snapshotCapturesInProgress.contains(id),
              let workspace = document?.workspace,
              let frame = workspace.frame(id: id), !frame.isImage,
              let webView = bridge.astraWebView(id: id) else { return }

        snapshotCapturesInProgress.insert(id)
        ToastView.show(message: "Capturing snapshot…", in: self, duration: 3)
        Task { @MainActor [weak self, weak webView] in
            guard let self else { return }
            defer { self.snapshotCapturesInProgress.remove(id) }
            guard let webView else { return }
            do {
                let capture = try await self.snapshotCaptureService.snapshot(webView)
                guard let current = self.document?.workspace.frame(id: id), !current.isImage else { return }
                let sourceURL = (capture.context["url"] as? String) ?? current.url
                let pixelWidth = (capture.context["pixelWidth"] as? NSNumber)?.doubleValue
                    ?? Double(max(1, capture.width))
                let pixelHeight = (capture.context["pixelHeight"] as? NSNumber)?.doubleValue
                    ?? Double(max(1, capture.height))
                self.document?.workspace.convertFrameToSnapshot(
                    id: id,
                    dataURL: ImageOptimizer.optimize(dataURL: capture.dataURL),
                    sourceURL: sourceURL,
                    pixelSize: CGSize(width: pixelWidth, height: pixelHeight)
                )
                ToastView.show(message: "Converted to snapshot", in: self)
            } catch is CancellationError {
                return
            } catch {
                ToastView.show(message: "Snapshot failed: \(error.localizedDescription)",
                               in: self, duration: 4)
            }
        }
    }

    /// Turn a frozen snapshot back into its original live web frame.
    func restoreSnapshotToLive(id: String) {
        guard let frame = document?.workspace.frame(id: id),
              frame.isImage,
              case .string = frame.extras["snapshotSourceURL"] ?? .null else { return }
        document?.workspace.restoreLiveFrame(id: id)
        ToastView.show(message: "Restored live website", in: self)
    }

    /// Navigate back in the frame's webview history. No-op when there's
    /// nothing to go back to — matches browser behaviour.
    func goBackFrame(id: String) {
        bridge.goBackInFrameView(id: id)
    }

    /// Navigate the frame's webview to `url`, committed from the header's
    /// address-bar field. Accepts bare hostnames ("example.com",
    /// "localhost:3000") — missing scheme gets https:// prepended for web
    /// and http:// for localhost / 127.0.0.1. Blank strings are ignored.
    /// Workspace state isn't mutated — the frame's persisted URL stays
    /// what it was at creation; the live address is a runtime display
    /// concern, synced by `wf-nav`.
    func navigateFrame(id: String, url rawURL: String) {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lower = trimmed.lowercased()
        let normalized: String
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            normalized = trimmed
        } else if lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1") {
            normalized = "http://" + trimmed
        } else {
            normalized = "https://" + trimmed
        }
        bridge.loadURLInFrameView(id: id, url: normalized)
    }

    /// Apply a size preset. `preset == "mobile"` → 390×844, everything
    /// else (including `"desktop"`) → 1280×800. Mirrors `DESKTOP_PRESET`
    /// / `MOBILE_PRESET` at index.html:1185–1186. `workspace.resizeFrame`
    /// clamps to ≥ 1; we pre-clamp to `minFrameDim` (200) so the commit
    /// lands at the same value the drag-resize path uses.
    func applyFrameSizePreset(id: String, preset: String) {
        let size: CGSize = preset == "mobile"
            ? CGSize(width: 390,  height: 844)
            : CGSize(width: 1280, height: 800)
        commitFrameSize(id: id, w: size.width, h: size.height)
    }

    /// Commit an explicit size from the header's width/height inputs.
    /// Pre-clamps to `minFrameDim` to match JS `wfFrameApplySize`, which
    /// clamps at 200 before assigning `f.w/f.h`. `resizeFrame` re-checks
    /// (≥ 1) as a defensive net; the effective floor is 200.
    func commitFrameSize(id: String, w: CGFloat, h: CGFloat) {
        let clamped = CGSize(
            width:  max(Self.minFrameDim, w).rounded(),
            height: max(Self.minFrameDim, h).rounded()
        )
        document?.workspace.resizeFrame(id: id, size: clamped)
    }

    /// Commit a titlebar rename. Trims whitespace and drops empty labels
    /// (a blank rename collapses to the URL fallback only at *display*
    /// time — we don't overwrite `label` with an empty string because
    /// that would wipe a previously-set name the user no longer sees).
    /// `renameFrame` itself is a no-op when the trimmed label matches
    /// the current `label`, so a click-commit without edit costs nothing.
    func commitFrameTitle(id: String, label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        document?.workspace.renameFrame(id: id, label: trimmed)
    }

    // MARK: - Add-frame modal presentation

    /// Entry point from `NativeBridge` when the canvas sends
    /// `open-add-frame-modal`. Lazily constructs the modal, resets its
    /// state, and pins it to the host bounds above every other subview.
    func presentAddFrameModal() {
        serverDiscovery.projectAddress = document?.workspace.projectMap?.baseURL
        onBeforeAddFrame?()
        let modal = addFrameModal ?? {
            let m = AddFrameModal(discovery: serverDiscovery)
            m.delegate = self
            m.projectImportView = makeProjectImportView
            m.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
            m.translatesAutoresizingMaskIntoConstraints = false
            addFrameModal = m
            return m
        }()
        // Re-add if it was previously removed (delegate dismissals detach
        // from the view hierarchy so frames repaint uncovered).
        if modal.superview !== self {
            addSubview(modal, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                modal.topAnchor.constraint(equalTo: topAnchor),
                modal.bottomAnchor.constraint(equalTo: bottomAnchor),
                modal.leadingAnchor.constraint(equalTo: leadingAnchor),
                modal.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        modal.reset()
        // Hide all frames while the modal is visible — the glass card lives
        // in Swift/AppKit, but per-frame WKWebViews sit above the canvas
        // webview. If we left them visible the backdrop wouldn't dim them.
        bridge.setAllFramesVisible(false)
    }

    func dismissAddFrameModal() {
        window?.makeFirstResponder(self)
        addFrameModal?.removeFromSuperview()
        bridge.setAllFramesVisible(true)
    }

    // MARK: - Scroll-gesture gating
    //
    // `DocumentWindowController`'s Phase 6e Step 1 scroll/magnify monitor
    // calls this to decide whether a gesture belongs to the canvas or
    // should fall through to whatever subview is under the cursor (dock
    // buttons don't scroll, annotation panel's pin list scrolls its own
    // NSScrollView). When a modal is on top of everything, every gesture
    // is swallowed without effect — users don't expect the canvas to pan
    // behind an open pin editor.
    var isModalPresented: Bool {
        (addFrameModal?.superview === self) ||
        (pinEditorModal?.superview != nil)
    }

    /// True when the gesture's hit target is the annotation panel
    /// subtree — its internal NSScrollView should keep its own scroll.
    /// Topmost view in the whole window under a point given in this view's
    /// coordinates. The region checks below need the window's answer, not
    /// the host's: the dock is a subview of the split view (so it stays
    /// window-centred), never of the host, and `hitTest` on the host could
    /// not find it — every monitor took dock clicks for canvas clicks, so
    /// in Hand mode the pan monitor swallowed them.
    private func hitView(atHostPoint point: NSPoint) -> NSView? {
        guard let root = window?.contentView else {
            return hitTest(superview.map { convert(point, to: $0) } ?? point)
        }
        // `hitTest(_:)` takes the receiver's superview coordinates.
        return root.hitTest(convert(point, to: root.superview))
    }

    /// `point` is in this view's coordinates, like the other region checks.
    func isAnnotationPanelRegion(_ point: NSPoint) -> Bool {
        guard let hit = hitView(atHostPoint: point) else { return false }
        return hit === annotationPanel || hit.isDescendant(of: annotationPanel)
    }

    /// True when the gesture's hit target is the dock or one of its
    /// buttons — dock buttons don't consume scroll, but we don't want
    /// the canvas to pan under the user's fingers on the dock either.
    func isDockRegion(_ point: NSPoint) -> Bool {
        guard let hit = hitView(atHostPoint: point) else { return false }
        return hit === dock || hit.isDescendant(of: dock)
    }

/// True when the hit target at `point` lives inside a `FrameCardView`
    /// — i.e. the pointer is over a frame's chrome / web content. Used by
    /// the window-level mouseDown monitor (Phase 6e Step 3) to decide
    /// whether an empty-canvas click should drop the frame selection.
    ///
    /// Implemented by walking up the hit-target chain looking for a
    /// `FrameCardView` ancestor, rather than asking the `FrameLayerView`
    /// directly — FrameCardViews are actually hosted by `FrameLayerView`
    /// so a descent-of-frameLayer check would flag the layer's empty
    /// background as "on a frame", which is the opposite of what we want.
    func isFrameCardRegion(_ point: NSPoint) -> Bool {
        return frameCardId(at: point) != nil
    }

    /// Returns the id of the `FrameCardView` under `point` (host coords),
    /// or nil if the pointer isn't over any card. Used by the deselect
    /// monitor to promote body-clicks into frame selection so the user
    /// doesn't have to hit the header strip to focus a frame.
    func frameCardId(at point: NSPoint) -> String? {
        guard var hit = hitView(atHostPoint: point) else { return nil }
        while true {
            if let card = hit as? FrameCardView { return card.id }
            guard let parent = hit.superview else { return nil }
            hit = parent
        }
    }

    /// True when `point` (host coords) lands inside the currently
    /// selected frame card. The scroll-wheel monitor uses this to route
    /// wheel events to the WKWebView (in-frame scroll) instead of panning
    /// the canvas — keeps the canvas still once the user has "entered" a
    /// frame, mirroring the way DevTools / Figma embed iframes behave.
    /// Returns false in annotation mode: the shield owns hitTest there,
    /// and the user expects the crosshair to follow pointer without the
    /// page scrolling out from under it.
    func isSelectedFrameBodyRegion(_ point: NSPoint) -> Bool {
        guard !annotationMode, let selectedId = selectedFrameId else { return false }
        guard var hit = hitView(atHostPoint: point) else { return false }
        while true {
            if let card = hit as? FrameCardView {
                return card.id == selectedId
            }
            guard let parent = hit.superview else { return false }
            hit = parent
        }
    }

    // MARK: - Image paste and drop (Phase 6e Step 70e polish #4)
    //
    // The pre-migration JS path lived at `cw.addEventListener('drop',...)`
    // in `Renderer/index.html` (~line 1097). Step 70e deleted that file
    // wholesale, so without a native replacement Egor's image drags fell
    // on deaf ears — the OS showed no accept cursor, `performDrop` never
    // fired, frames never spawned. This block restores the behaviour.
    //
    // `CanvasHost` is registered as the drop target (see init's
    // `registerForDraggedTypes([.fileURL, .tiff, .png])`); it sits above
    // `frameLayer` and `linkLayer` so drops anywhere in the document
    // window (except over a frame's WKWebView, which consumes the drag
    // internally for its own page's content) route here.

    /// The Edit → Paste responder-chain action reaches the canvas when a
    /// text field or an embedded page has not already consumed it.
    func pasteIntoAddFrameModal() -> Bool {
        guard addFrameModal?.superview === self else { return false }
        return addFrameModal?.pasteImage() ?? false
    }

    @objc func paste(_ sender: Any?) {
        if isModalPresented { _ = pasteIntoAddFrameModal(); return }
        _ = pasteImageFrames(from: .general)
    }

    func pasteImageFrames(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]) as? [URL], !urls.isEmpty {
            return spawnImageFrames(items: imageSpecItems(fromURLs: urls))
        }

        let isFigma = pasteboard.types?.contains(where: { $0.rawValue.localizedCaseInsensitiveContains("figma") }) == true
        let name = isFigma ? "Figma selection" : "Pasted image"

        // Figma's explicit “Copy as SVG” path may expose either public.svg
        // data or plain SVG text, depending on the desktop/browser build.
        let svgType = NSPasteboard.PasteboardType(UTType.svg.identifier)
        if let data = pasteboard.data(forType: svgType),
           let item = imageSpecItem(fromData: data, mime: "image/svg+xml", name: name) {
            return spawnImageFrames(items: [item])
        }
        if let string = pasteboard.string(forType: .string),
           string.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<svg"),
           let data = string.data(using: .utf8),
           let item = imageSpecItem(fromData: data, mime: "image/svg+xml", name: name) {
            return spawnImageFrames(items: [item])
        }
        if let image = NSImage(pasteboard: pasteboard),
           let item = imageSpecItem(from: image, name: name) {
            return spawnImageFrames(items: [item])
        }
        return false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return acceptsDraggedImages(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return acceptsDraggedImages(sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        // File URL path — preferred: lets us read the original bytes
        // verbatim so formats like webp/svg that NSImage's PNG round-trip
        // would lose info pass through intact.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]) as? [URL], !urls.isEmpty {
            let images = imageSpecItems(fromURLs: urls)
            return spawnImageFrames(items: images, centeredAt: dropWorldPoint(sender))
        }
        // Raw-image path: someone dragged an image out of Preview /
        // Finder's quick-look / another app's canvas. No file URL, just
        // a TIFF/PNG blob on the pasteboard.
        if let img = NSImage(pasteboard: pb),
           let item = imageSpecItem(from: img, name: "dropped-image") {
            return spawnImageFrames(items: [item], centeredAt: dropWorldPoint(sender))
        }
        return false
    }

    /// Where the user let go, in world coordinates.
    private func dropWorldPoint(_ info: NSDraggingInfo) -> CGPoint {
        let p = convert(info.draggingLocation, from: nil)
        return worldPoint(clientX: p.x, clientY: flipClientY(p.y))
    }

    /// Center of the visible canvas, in world coordinates.
    private func visibleCenterWorldPoint() -> CGPoint {
        worldPoint(clientX: bounds.midX, clientY: flipClientY(bounds.midY))
    }

    /// True when the pasteboard carries at least one image-conforming
    /// file URL or a raw image blob. Drives the accept-cursor during
    /// the drag hover so the user sees upfront whether the drop will
    /// land — matches AppKit's usual NSImageView behaviour.
    private func acceptsDraggedImages(_ pb: NSPasteboard) -> Bool {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]) as? [URL], !urls.isEmpty {
            return true
        }
        return NSImage(pasteboard: pb) != nil
    }

    /// Convert image file URLs into the `[String: Any]` items consumed
    /// by `AddFrameSpecApplier.frames(for:)`'s `kind == "image"` branch —
    /// same contract as `AddFrameModal.addFilesFromURLs` builds. Each
    /// item carries `dataURL` (base64-encoded with the correct MIME),
    /// `natW`/`natH` (pixel dimensions), and `name` (filename without
    /// extension, used for the frame label).
    private func imageSpecItems(fromURLs urls: [URL]) -> [[String: Any]] {
        urls.compactMap { url -> [String: Any]? in
            guard let data = try? Data(contentsOf: url),
                  let img  = NSImage(data: data) else { return nil }
            let mime = mimeType(for: url)
            // natW/natH keep the original size for layout; only the stored
            // pixels shrink (see ImageOptimizer).
            let stored = ImageOptimizer.optimize(data, mime: mime)
            let dataURL = "data:\(stored?.mime ?? mime);base64,\((stored?.data ?? data).base64EncodedString())"
            let rep = img.representations.first as? NSBitmapImageRep
            let natW = rep?.pixelsWide ?? Int(img.size.width)
            let natH = rep?.pixelsHigh ?? Int(img.size.height)
            return [
                "name":    url.deletingPathExtension().lastPathComponent,
                "dataURL": dataURL,
                "natW":    natW,
                "natH":    natH,
            ]
        }
    }

    /// Convert a raw NSImage (paste / non-URL drag) into a single spec
    /// item. We serialize to PNG — lossless, universally accepted — so
    /// the downstream `image://` WKWebView load path doesn't have to
    /// care about the on-pasteboard format.
    private func imageSpecItem(from image: NSImage, name: String) -> [String: Any]? {
        guard let tiff = image.tiffRepresentation,
              let bmp  = NSBitmapImageRep(data: tiff),
              let data = bmp.representation(using: .png, properties: [:]) else {
            return nil
        }
        let stored = ImageOptimizer.optimize(data, mime: "image/png")
        let dataURL = "data:\(stored?.mime ?? "image/png");base64,\((stored?.data ?? data).base64EncodedString())"
        return [
            "name":    name,
            "dataURL": dataURL,
            "natW":    bmp.pixelsWide,
            "natH":    bmp.pixelsHigh,
        ]
    }

    private func imageSpecItem(fromData data: Data, mime: String, name: String) -> [String: Any]? {
        guard let image = NSImage(data: data) else { return nil }
        let rep = image.representations.first as? NSBitmapImageRep
        let stored = ImageOptimizer.optimize(data, mime: mime)
        return [
            "name": name,
            "dataURL": "data:\(stored?.mime ?? mime);base64,\((stored?.data ?? data).base64EncodedString())",
            "natW": rep?.pixelsWide ?? max(1, Int(image.size.width)),
            "natH": rep?.pixelsHigh ?? max(1, Int(image.size.height)),
        ]
    }

    private func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png":          return "image/png"
        case "jpg", "jpeg":  return "image/jpeg"
        case "gif":          return "image/gif"
        case "svg":          return "image/svg+xml"
        case "webp":         return "image/webp"
        default:             return "application/octet-stream"
        }
    }

    /// Route an array of image spec items through `AddFrameSpecApplier`
    /// (same call shape as `addFrameModal(_:didConfirmSpec:)` uses for
    /// the modal's Done button, so drops and the modal produce identical
    /// frames). Returns `true` iff at least one frame was created, which
    /// is what `performDragOperation` wants to surface back to the OS.
    @discardableResult
    /// Adds image frames centered on `point` (drop location or the visible
    /// center for paste), side by side when there are several, and selects
    /// them. The spec applier's default origin stacks new frames to the
    /// right of every existing one, which on a full board is off-screen.
    private func spawnImageFrames(items: [[String: Any]], centeredAt point: CGPoint? = nil) -> Bool {
        guard let workspace = document?.workspace, !items.isEmpty else {
            return false
        }
        let spec: [String: Any] = ["kind": "image", "images": items]
        let models = AddFrameSpecApplier.frames(
            for: spec,
            existingFrameCount: workspace.frames.count,
            viewport: workspace.viewport,
            allocateNum: { workspace.allocateFrameNum() },
            generateId: { AddFrameSpecApplier.defaultIdGenerator() }
        )
        guard !models.isEmpty else { return false }
        let target = point ?? visibleCenterWorldPoint()
        let gap: CGFloat = 48
        let rowWidth = models.reduce(CGFloat.zero) { $0 + $1.w + CardGeometry.chromeWidth } + gap * CGFloat(models.count - 1)
        var x = target.x - rowWidth / 2
        for var model in models {
            model.x = x.rounded()
            model.y = (target.y - (model.h + CardGeometry.chromeHeight) / 2).rounded()
            x += model.w + CardGeometry.chromeWidth + gap
            workspace.createFrame(model)
        }
        setFrameSelection(models.map(\.id))
        return true
    }

    // MARK: - AddFrameModalDelegate

    func addFrameModal(_ modal: AddFrameModal,
                       didConfirmSpec spec: [String: Any]) {
        dismissAddFrameModal()
        // Phase 6e Step 70b: the spec used to go through
        // `forwardToCanvas("add-frame-spec")` → JS `applyAddFrameSpec`
        // → `spawnFrame` / `spawnImageFrame` → `NativeAPI
        // .workspaceCreateFrame` → Swift `workspace.createFrame`.
        // Step 70e deleted the canvas WKWebView outright, so the JS
        // hop is physically gone: the applier runs the URL
        // normalization / position math / image scaling natively and
        // calls `workspace.createFrame` directly. The store observer
        // on this host then drives the native frame lifecycle.
        guard let workspace = document?.workspace else { return }
        let models = AddFrameSpecApplier.frames(
            for: spec,
            existingFrameCount: workspace.frames.count,
            viewport: workspace.viewport,
            allocateNum: { workspace.allocateFrameNum() },
            generateId: { AddFrameSpecApplier.defaultIdGenerator() }
        )
        for model in models {
            workspace.createFrame(model)
        }
        // A freshly-added page should never appear as a narrow sliver at
        // the edge of a previously panned or zoomed canvas. Focus a single
        // addition and fit it to the visible canvas. Batch imports keep
        // their relative layout and fit the complete group instead.
        if let onlyFrame = models.first, models.count == 1 {
            selectFrame(onlyFrame.id, additive: false)
            zoomToSelectedFrame()
        } else if !models.isEmpty {
            clearFrameSelectionIfNeeded()
            performDockZoomFit()
        }
    }

    func addFrameModalDidCancel(_ modal: AddFrameModal) {
        dismissAddFrameModal()
    }

    // MARK: - AnnotationPanelDelegate
    //
    // Phase 6d flipped `delete` and `toggle-resolved` to direct
    // `WorkspaceStore` mutations (undoable via `NSUndoManager`).
    //
    // Phase 6e Step 70a flipped `close`, `copy-all`, and `copy-one`
    // to direct Swift implementations: close hides the native panel
    // and updates the dock state, the two `copy` actions format
    // through `AnnotationCopyFormatter` and write to `NSPasteboard`.
    //
    // As of Phase 6e Step 70a all panel actions (close / reset / copy /
    // copy-one / select / delete / toggleResolved) are native; the
    // `ann-panel-action` envelope is no longer forwarded from here. The
    // JS handler in `WFAnn` at index.html is now dead code and will be
    // deleted in Step 70e together with the canvas WKWebView.

    func annotationPanelDidRequestClose() {
        // Phase 6e Step 70a: close is a pure UI action — hide the
        // native panel and update the dock's notes-open state
        // directly. JS used to own the `notesOpen` dock flag (via
        // `toggleAnnPanel(false)`); we mirror the same behaviour here
        // so the dock button returns to the inactive tint.
        onCloseComments?()
    }

    func annotationPanelDidRequestResetCounters() {
        // Phase 6e Step 70a: native renumber. `workspace.resetCounters`
        // reassigns `num` on every frame and annotation by array order
        // and resets `nextFrameNum` / `nextAnnNum` to `count + 1`. The
        // delegate persists + re-pushes `doc-load-state`, and
        // `updateAnnUI` on the JS side picks up the new numbers through
        // the normal apply-payload path. Not registered on the undo
        // manager — matches the JS behaviour where `annResetCounters`
        // had no undo hook. Also drop any live pin drafts — the editor
        // snapshot's `num` would otherwise lag behind the workspace.
        pinDrafts.removeAll()
        dismissPinEditor()
        document?.workspace.resetCounters()
    }

    private func openCommentsMarkdown() -> String? {
        guard let workspace = document?.workspace,
              workspace.annotations.contains(where: { !$0.resolved }) else { return nil }
        return AnnotationCopyFormatter.fullText(annotations: workspace.annotations, frames: workspace.frames)
    }

    func annotationPanelDidRequestCopyAll() {
        guard let text = openCommentsMarkdown() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if pb.setString(text, forType: .string) { annotationPanel.flashCopied() }
    }

    func annotationPanelDidRequestDownloadMarkdown() {
        guard let text = openCommentsMarkdown(), let window else { return }
        // Capture the same open-comment snapshot that Copy all uses before opening the sheet.
        let panel = NSSavePanel()
        panel.title = "Download comments"
        panel.nameFieldStringValue = "Web Frames Comments.md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                if let self { ToastView.show(message: "Comments saved", in: self) }
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    func annotationPanelDidRequestFixWithCodex() {
        onFixCommentsWithCodex?()
    }

    func annotationPanel(didSelect id: String) {
        // Phase 6e Step 70a: native "open the pin editor for this
        // annotation" — matches the flipped path from PinOverlayView's
        // pin-dot click. JS used to run `annSelect(id)` → `openPinEditor`
        // which also handled the focus flip; the native modal spawned
        // via `openPinEditor(forAnnotationId:)` takes over that role.
        // Camera pan-to-pin is intentionally not ported — the panel is
        // anchored to the top-right and the editor overlays its frame,
        // so a panned camera would just hide the clicked pin under the
        // editor glass.
        openPinEditor(forAnnotationId: id)
    }

    func annotationPanel(didRequestDelete id: String) {
        // Swift-owned: `workspace.deleteAnnotation` mutates the store,
        // the delegate persists and pushes `doc-load-state` to JS (which
        // rebuilds its in-memory arrays and re-pushes the panel list
        // via `pushAnnotationsToNative`), and the inverse is registered
        // on the document's `NSUndoManager`.
        document?.workspace.deleteAnnotation(id: id)
    }

    func annotationPanel(didRequestCopy id: String) {
        // Phase 6e Step 70a: format a single annotation in Swift and
        // write to the system pasteboard. Index unset so the line
        // numbering falls back to `a.num` (matches the JS behaviour
        // of calling `annotationToCopyLine(a)` with no index arg).
        guard let ann = document?.workspace.annotations
                .first(where: { $0.id == id }) else { return }
        let text = AnnotationCopyFormatter.line(for: ann,
                                                comment: ann.comment,
                                                edits: ann.edits)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        annotationPanel.flashCopied()
    }

    func annotationPanel(didToggleResolved id: String) {
        // Swift-owned — see `annotationPanel(didRequestDelete:)`. Toggle
        // is self-inverse, so the undoManager registration in the
        // delegate captures just the id.
        document?.workspace.toggleAnnotationResolved(id: id)
    }

    // MARK: - Pin-editor modal presentation
    //
    // Entry points from `NativeBridge` when the canvas sends
    // `pin-editor-open` / `pin-editor-close-all`. The modal itself is
    // a full-bounds overlay pinned above every other CanvasHost subview
    // (dock, annotation panel, frame layer) so its backdrop darkens/blurs
    // the whole canvas uniformly.

    /// Phase 6e Step 70a: build a `PinEditPayload` from the live
    /// workspace annotation and open the native editor. Replaces the
    /// `pin-clicked` → canvas JS → `pin-editor-open` round-trip that
    /// the JS path used to do in `WFPins.onPinClicked` →
    /// `openPinEditor` → `NativeAPI.pinEditorOpen`.
    ///
    /// Pulls `elementLabel` / `screenshot` / `computedStyles` out of
    /// `AnnotationModel.extras["element"]` — the same JS-originated
    /// element snapshot that `handleInspectContext` stores on new
    /// pins. Falls back gracefully on missing fields (label defaults
    /// to `"element"`, styles default to `[:]`, screenshot absent
    /// hides the thumb row).
    func openPinEditor(forAnnotationId id: String) {
        guard let ann = document?.workspace.annotations
                .first(where: { $0.id == id }) else { return }
        let element = elementDict(ann.extras["element"])
        let elementLabel = element
            .flatMap { dict -> String? in
                if case .string(let s) = dict["componentName"] ?? .null,
                   !s.isEmpty { return s }
                if case .string(let s) = dict["tagName"] ?? .null,
                   !s.isEmpty { return s }
                return nil
            } ?? "element"
        let styles: [String: String] = element
            .flatMap { dict -> [String: JSONValue]? in
                if case .object(let d) = dict["computedStyles"] ?? .null { return d }
                return nil
            }
            .map { dict in
                var out: [String: String] = [:]
                for (k, v) in dict {
                    if case .string(let s) = v { out[k] = s }
                    else if case .number(let n) = v { out[k] = "\(n)" }
                }
                return out
            } ?? [:]
        var screenshot: NSImage?
        if let dict = element,
           case .string(let dataURL) = dict["screenshot"] ?? .null,
           let comma = dataURL.firstIndex(of: ","),
           let data = Data(base64Encoded:
               String(dataURL[dataURL.index(after: comma)...])) {
            screenshot = NSImage(data: data)
        }
        let payload = PinEditPayload(
            id: ann.id, num: ann.num, color: ann.color,
            comment: ann.comment, elementLabel: elementLabel,
            screenshot: screenshot, computedStyles: styles,
            edits: ann.edits, isNew: false, resolved: ann.resolved
        )
        presentPinEditor(payload)
    }

    private func elementDict(_ value: JSONValue?) -> [String: JSONValue]? {
        guard let value else { return nil }
        if case .object(let d) = value { return d }
        return nil
    }

    func presentPinEditor(_ payload: PinEditPayload) {
        let modal = pinEditorModal ?? {
            let m = PinEditorModal()
            m.delegate = self
            m.translatesAutoresizingMaskIntoConstraints = false
            pinEditorModal = m
            return m
        }()
        // The editor belongs to the whole document window. Hosting it only
        // inside CanvasHost clipped the 480pt card whenever both split-view
        // sidebars were open and left no useful room for dragging.
        let overlayHost = window?.contentView ?? self
        if modal.superview !== overlayHost {
            modal.removeFromSuperview()
            overlayHost.addSubview(modal, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                modal.topAnchor.constraint(equalTo: overlayHost.topAnchor),
                modal.bottomAnchor.constraint(equalTo: overlayHost.bottomAnchor),
                modal.leadingAnchor.constraint(equalTo: overlayHost.leadingAnchor),
                modal.trailingAnchor.constraint(equalTo: overlayHost.trailingAnchor),
            ])
        }
        modal.present(payload)
        // While the pin editor is up the user's mouse work is with the
        // modal's text fields / color swatches / buttons — a crosshair
        // there reads as a stuck cursor. Hide the shield so the default
        // arrow / iBeam cursors come back; `dismissPinEditor` flips it
        // back on if annotation mode is still armed.
        annotationCursorShield.isHidden = true
        annotationCursorShield.window?.invalidateCursorRects(for: annotationCursorShield)
        NSCursor.arrow.set()
    }

    func dismissPinEditor() {
        window?.makeFirstResponder(self)
        pinEditorModal?.dismiss()
        if annotationMode {
            annotationCursorShield.isHidden = false
            annotationCursorShield.window?.invalidateCursorRects(for: annotationCursorShield)
        }
    }

    // MARK: - PinEditorDelegate
    //
    // Every intent becomes a `pin-editor-action` envelope. Canvas JS keeps
    // the annotations array as the source of truth, so all mutations
    // (persist / revert / copy / delete / color update) happen there via
    // `window.WFPinEditor`.

    func pinEditorDidSave(id: String, comment: String, color: String,
                          edits: [String: String]) {
        // Phase 6e Step 70a: both paths now commit directly through
        // `WorkspaceStore` — new pins via `createAnnotation` (Step 6),
        // existing pins via `updateAnnotation`. No JS round-trip.
        defer { restoreAnnotationCursorShieldIfNeeded() }
        if var draft = pinDrafts.removeValue(forKey: id) {
            draft.ann.comment = comment
            draft.ann.color   = color
            draft.ann.edits   = edits
            document?.workspace.createAnnotation(draft.ann)
            bridge.setAllFramesVisible(true)
            return
        }
        document?.workspace.updateAnnotation(
            id: id, comment: comment, color: color, edits: edits)
        bridge.setAllFramesVisible(true)
    }

    func pinEditorDidCancel(id: String, isNew: Bool) {
        // Phase 6e Step 70a: cancel has no model-level consequence in
        // either path. A draft is silently dropped (Swift never saw
        // it). An existing pin's edits are discarded — the workspace
        // wasn't mutated live, so there's nothing to revert. In both
        // cases we just re-enable the frames the modal had dimmed.
        pinDrafts.removeValue(forKey: id)
        bridge.setAllFramesVisible(true)
        restoreAnnotationCursorShieldIfNeeded()
    }

    /// Re-arm the crosshair cursor shield after the pin editor closes,
    /// provided annotation mode is still on. Called from every path
    /// that can close the modal (save, cancel, delete) since the modal
    /// self-dismisses without round-tripping through `dismissPinEditor`.
    private func restoreAnnotationCursorShieldIfNeeded() {
        guard annotationMode else { return }
        annotationCursorShield.isHidden = false
        annotationCursorShield.window?.invalidateCursorRects(for: annotationCursorShield)
    }

    func pinEditorDidRequestCopy(id: String, comment: String,
                                 edits: [String: String]) {
        // Phase 6e Step 70a: Swift formats the copy line and writes
        // the clipboard directly. For a draft (new pin mid-edit), use
        // the draft's working copy; for an existing pin, use the
        // workspace annotation plus the freshest comment/edits from
        // the modal.
        let ann: AnnotationModel?
        let liveComment: String
        let liveEdits: [String: String]
        if let draft = pinDrafts[id] {
            ann = draft.ann
            liveComment = comment
            liveEdits = edits
        } else if let existing = document?.workspace.annotations.first(where: { $0.id == id }) {
            ann = existing
            liveComment = comment
            liveEdits = edits
        } else {
            return
        }
        guard let a = ann else { return }
        let text = AnnotationCopyFormatter.line(for: a,
                                                comment: liveComment,
                                                edits: liveEdits)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func pinEditorDidSetResolved(id:String,resolved:Bool) {
        if pinDrafts[id] != nil {pinDrafts[id]?.ann.resolved = resolved;return}
        document?.workspace.setAnnotationResolved(id:id,resolved:resolved)
    }

    func pinEditorDidRequestDelete(id: String) {
        defer { restoreAnnotationCursorShieldIfNeeded() }
        // Swift-owned in Phase 6d — same path as the annotation panel's
        // trash button (see `annotationPanel(didRequestDelete:)`).
        document?.workspace.deleteAnnotation(id: id)
        bridge.setAllFramesVisible(true)
    }

    func pinEditorDidChangeColor(id: String, color: String) {
        // Phase 6e Step 70a: direct update. For drafts, mutate the
        // in-memory working copy — the modal owns its own swatch
        // paint, and the pin overlay picks up the tint on save. For
        // an existing pin, push the single-field update so undo can
        // revert the color change.
        if pinDrafts[id] != nil {
            pinDrafts[id]?.ann.color = color
            return
        }
        document?.workspace.updateAnnotation(id: id, color: color)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        canvasBackdrop.frame = bounds
        frameLayer.frame = bounds
        linkLayer.frame = bounds
        annotationCursorShield.frame = bounds
        panCursorShield.frame = bounds
        // `titlebarDragView.frame = ...` was here — removed 2026-05-03,
        // see ivar-site comment.
        // Dock: positioned by Auto Layout on a DIFFERENT parent — see
        // `DocumentWindowController.configureDockPlacement()`. The dock
        // is a non-arranged subview of the window's `NSSplitView` now,
        // pinned window-centered + bottom-16pt. Sidebar-refactor Step 3
        // follow-up: the old placement pinned `dock.centerXAnchor` to
        // `canvasHost.centerXAnchor`, which made the dock "ride" right
        // when the sidebar opened — now it's strictly window-centered.
    }
}

extension CanvasHost {
    /// Loads the shared `logo.svg` from the Renderer bundle directory.
    /// Mirrors `StartWindowController.loadRendererLogo()` so the start
    /// panel and the document window show the same brand mark from the
    /// same source file — one of the last survivors of the Renderer
    /// folder after Phase 6e Step 70e's bulk delete.
    ///
    /// Sidebar-refactor Step 3 (2026-04-21) widened this to `static`
    /// (was `fileprivate`) so `DocumentWindowController` can reuse the
    /// same loader when it constructs the window's centered brand
    /// stack — keeping the brand-mark source-of-truth in one place.
    static func loadRendererLogo() -> NSImage? {
        let url = Bundle.main.url(forResource: "logo",
                                  withExtension: "svg",
                                  subdirectory: "Renderer")
            ?? Bundle.main.url(forResource: "logo", withExtension: "svg")
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }
}

// MARK: - Titlebar drag (removed 2026-05-03)
//
// `TitlebarDragView` (an `NSView` with `mouseDownCanMoveWindow = true`,
// pinned at the top 38pt of `CanvasHost`) used to back custom drag-to-move
// behavior across the canvas pane while `fullSizeContentView` extended
// content under a transparent titlebar. After the sidebar refactor (2026-
// 04-21) the window gained an `NSToolbar` configured with `.unified` style
// and a trailing `.flexibleSpace` — the toolbar's empty area handles
// drag-to-move and double-click-to-zoom natively, so the custom drag view
// is redundant. See `DocumentWindowController` toolbar setup for the
// replacement path.

// MARK: - Frame overlay

final class FrameLayerView: NSView {
    override var isFlipped: Bool { true }
    /// Card controls (`CardChromeHostView`) stay above every card: adding
    /// or reordering a card would otherwise put it over other cards'
    /// toolbars and handles.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview is FrameCardView { raiseCardControls() }
    }
    /// Reordering an existing card (layer order) goes through here without
    /// `didAddSubview`.
    override func addSubview(_ view: NSView, positioned place: NSWindow.OrderingMode, relativeTo otherView: NSView?) {
        super.addSubview(view, positioned: place, relativeTo: otherView)
        if view is FrameCardView { raiseCardControls() }
    }
    private func raiseCardControls() {
        let hosts = subviews.filter { $0 is CardChromeHostView }
        guard let lastCard = subviews.lastIndex(where: { $0 is FrameCardView }),
              hosts.contains(where: { subviews.firstIndex(of: $0)! < lastCard }) else { return }
        for host in hosts { super.addSubview(host, positioned: .above, relativeTo: nil) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

// MARK: - Annotation cursor shield
//
// Transparent overlay that claims a crosshair cursor rect over its full
// bounds when annotation mode is on. Sits above the frame layer in
// z-order, so AppKit's "last sibling wins for cursor rects at a point"
// rule forces crosshair over WKWebView's internal cursor rects. Events
// pass through via `hitTest → nil`, so frame drag/resize/pin click
// still work. Visibility (not cursor-rect state) is the on/off switch:
// when hidden, AppKit skips the view entirely and default cursors win.
final class AnnotationCursorShield: NSView {
    override var isFlipped: Bool { true }
    /// Fired on every mouseMoved / mouseEntered / mouseExited. Host wires
    /// this up to drive the per-frame JS hover highlight — the shield
    /// swallows the event from WKWebView, then mirrors the coordinate
    /// back through `wf-highlight` so the DOM picker outline follows the
    /// crosshair.
    var onPointerMove: ((NSPoint) -> Void)?
    var onPointerExit: (() -> Void)?
    private var trackingAreaInstalled: NSTrackingArea?

    /// Swallow every mouse event that reaches us — WKWebView's
    /// WebContent process otherwise dispatches cursor changes
    /// asynchronously that beat both `NSCursor.set()` and cursor
    /// rects (WKWebView sets the cursor directly from IPC replies,
    /// out-of-band from AppKit's cursor-rect pass). By owning hit-test
    /// we stop mouseMoved from ever reaching WKWebView; the
    /// window-level click monitor still runs first and captures
    /// annotation-place clicks before dispatch, so the pin-drop flow
    /// is unaffected. Trade-off: frame header drag/resize is disabled
    /// while annotation mode is armed — user toggles the mode off to
    /// reorganize frames.
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : self
    }
    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingAreaInstalled { removeTrackingArea(old) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited,
                      .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingAreaInstalled = ta
    }
    override func mouseMoved(with event: NSEvent) {
        onPointerMove?(event.locationInWindow)
    }
    override func mouseEntered(with event: NSEvent) {
        onPointerMove?(event.locationInWindow)
    }
    override func mouseExited(with event: NSEvent) {
        onPointerExit?()
    }
    override func mouseDown(with event: NSEvent) { /* consumed */ }
    override func mouseUp(with event: NSEvent) { /* consumed */ }
    override func mouseDragged(with event: NSEvent) {
        // Drag acts like move for highlight purposes — user can arm the
        // crosshair, scrub across the page, and see the picker follow.
        onPointerMove?(event.locationInWindow)
    }
}

/// Same idea as `AnnotationCursorShield` but for pan mode (Space held /
/// V-toggle). Displays `cursor` (open hand idle, closed hand while
/// dragging) via a cursor rect that wins over any WKWebView-asserted
/// cursor underneath. Mouse events are intentionally NOT consumed at the
/// view level — the window-level `canvasPanDragMonitor` already picks up
/// leftMouseDown/Dragged/Up before dispatch and drives the pan. Letting
/// the events reach this view (and die in its empty mouse* overrides)
/// also prevents frames beneath from starting their own drag/select
/// gesture while pan mode is armed, which matches the JS behaviour.
final class PanCursorShield: NSView {
    var cursor: NSCursor = .openHand {
        didSet {
            guard cursor !== oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden ? nil : self
    }
    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }
    override func mouseDown(with event: NSEvent) { /* consumed — pan monitor handled it */ }
    override func mouseUp(with event: NSEvent) { /* consumed */ }
    override func mouseDragged(with event: NSEvent) { /* consumed */ }
}
