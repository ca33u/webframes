import AppKit
import WebKit
import os

/// Per-document window. Replaces the singleton `MainWindowController` —
/// `NSDocument` drives one instance per open `.webframes` file.
///
/// Window-frame persistence
/// ------------------------
/// Native-side window frame is stored per document using
/// `NSWindow.setFrameAutosaveName(_:)` keyed by the file's path hash.
/// Untitled docs share the "Untitled" autosave name — one remembered
/// position regardless of how many new docs you open.
///
/// Titlebar name field
/// -------------------
/// A native NSTextField pinned to the top-center of the content view edits
/// the project's name in place. The field is sibling to the canvas and
/// lives on top of the titlebar-drag strip, so it captures clicks before
/// they become window drags.
///
/// Visibility (aka: why the window sometimes didn't show up)
/// ---------------------------------------------------------
/// When `openUntitledDocumentAndDisplay(_:)` was called from inside a
/// click handler on the Start window and that window order-out'd itself
/// in the same synchronous turn, we observed the freshly-keyed doc
/// window getting lost in the transition — `makeKeyAndOrderFront` had
/// already been dispatched by `NSDocument.showWindows()` but the window
/// server never resolved it to a visible position. Overriding
/// `showWindow(_:)` to log + force activation lets us see what happens,
/// and `orderFrontRegardless` is a belt-and-suspenders fallback that
/// guarantees the window lands in front regardless of app-focus state.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {

    /// Root content VC: an `NSSplitViewController` with the frames
    /// sidebar on the leading side and the canvas host on the trailing
    /// side. Phase 6e sidebar-refactor Step 1 replaced the old
    /// `window.contentView = canvasHost` arrangement with this native
    /// split-view path so the window gains the Apple-HIG sidebar
    /// affordances (toolbar toggle, auto-collapse on narrow resize,
    /// system ⌘⌥S, traffic-lights visually riding on the sidebar).
    let splitViewController: DocumentSplitViewController
    /// Convenience accessor — resolves to `splitViewController.canvasVC.canvasHost`
    /// but used so often by the event monitors below (scroll gate, pan
    /// drag, annotation click, deselect, delete key) that a direct
    /// reference is worth keeping. The actual ownership is on the split
    /// VC; this is a second, type-erased hop for callsite clarity.
    let canvasHost: CanvasHost
    private let titleField = NSTextField()
    /// Centered-top brand stack for the document window: `logo.svg` image
    /// + "web frames" wordmark. Phase 6e sidebar-refactor Step 3 moved
    /// the brand out of `CanvasHost` (where it sat 92pt from the leading
    /// edge, just past the traffic lights) and onto the window itself so
    /// it reads as a window-level brand mark rather than a host-local
    /// corner label. Pinned to `window.contentView.centerXAnchor` +
    /// `topAnchor + 14` by `configureLogoStack()`. Passive — the stack
    /// and its subviews don't intercept events, so dragging anywhere in
    /// the title band still grabs the window via `NSToolbar`'s native
    /// drag-to-move behavior (`.unified` style + trailing `.flexibleSpace`).
    private let logoView: NSImageView
    private let logoLabel: NSTextField
    private let logoStack: NSStackView
    private weak var boundDocument: WebFramesDocument?
    private var astraReviewWindow: AstraReviewWindow?
    private var projectMapController: ProjectMapController?
    private var componentCatalogue: ComponentCatalogueController?
    private lazy var workspaceModes: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: ["Flow", "Library"], trackingMode: .selectOne, target: self, action: #selector(changeWorkspaceMode))
        control.selectedSegment = 0; control.segmentStyle = .rounded; control.selectedSegmentBezelColor = WFDesign.accent
        control.setAccessibilityLabel("Workspace view")
        return control
    }()
    @objc private func changeWorkspaceMode() {
        switch workspaceModes.selectedSegment {
        case 1: showComponentCatalogue()
        default: showFlow()
        }
    }
    func showFlow() {
        componentCatalogue?.close(); workspaceModes.selectedSegment = 0
        astraReviewWindow?.setWorkspaceVisible(true)
    }
    private func projectImportView(onChange: @escaping () -> Void) -> AddFrameTabPanel? {
        guard let project = boundDocument else { return nil }
        if projectMapController == nil { projectMapController = ProjectMapController(owner: self, project: project) }
        projectMapController?.onConfirmationChange = onChange
        return projectMapController
    }

    @objc func showSettings() {
        canvasHost.dismissAddFrameModal()
        AppSettingsWindowController.shared.present()
    }

    func showComponentCatalogue() {
        guard let project = boundDocument else { return }
        if componentCatalogue == nil { componentCatalogue = ComponentCatalogueController(owner: self, project: project) }
        canvasHost.dismissAddFrameModal()
        astraReviewWindow?.setWorkspaceVisible(false)
        workspaceModes.selectedSegment = 1
        componentCatalogue?.present()
    }

    /// Local keydown monitor that intercepts Cmd+Z / Shift+Cmd+Z before
    /// they reach the canvas WKWebView. Phase 6d owns undo on the Swift
    /// side via `NSUndoManager`; without this monitor, WKWebView would
    /// deliver the keystroke to `index.html`'s window-level keydown
    /// handler, which would run the now-dead JS `undo()` against an
    /// empty JS `undoStack` and silently swallow the event.
    ///
    /// Installed when the window becomes key, including the launcher's
    /// direct-window path, and torn down in `windowWillClose(_:)` to keep
    /// the removal on the main actor — `NSEvent.removeMonitor` can't
    /// safely run in `deinit` under strict concurrency.
    private var keyMonitor: Any?

    /// Local scrollWheel / magnify monitor that consumes trackpad and
    /// mouse-wheel gestures over the canvas area and routes them through
    /// `WorkspaceStore.setViewport(_:)`. Phase 6e Step 1 moves pan/zoom
    /// authority to Swift — before this monitor, WKWebView's
    /// `cw.addEventListener('wheel', ...)` in `index.html` owned the math
    /// and pushed the result to Swift via the `canvas-view` envelope.
    /// With the monitor in place, Swift mutates the workspace first,
    /// the observer paints the backdrop + link layer, and the delegate
    /// echoes a compact `canvas-view-set` envelope back to JS so the
    /// CSS transform (`cv.style.transform`) stays aligned with the
    /// authoritative viewport.
    ///
    /// Guards around the consume/pass decision live in
    /// `handleCanvasGesture(_:)` — the monitor itself is thin so we can
    /// install/remove it alongside the undo monitor on the same cues.
    private var canvasGestureMonitor: Any?

    /// Local `.leftMouseDown` monitor that clears the link / frame
    /// selection on `CanvasHost` when the user clicks somewhere that
    /// isn't a link curve or a frame card (Phase 6e Steps 2–3). Paired
    /// with the `.keyDown` delete monitor below so selection + delete
    /// flow stays entirely in Swift — JS's `selectedLinkId` and the
    /// `.fc.sel` DOM sweep are gated behind `!NativeAPI.available` and
    /// don't run in the app.
    ///
    /// This monitor is observation-only — it never consumes the click.
    /// Frames, the backdrop, the dock, the annotation panel all still
    /// receive the mouseDown they would have received otherwise; we
    /// just inspect the target first and, if it's on empty canvas,
    /// notify the host to drop any selection ring.
    private var canvasDeselectMonitor: Any?

    /// Local `.keyDown` monitor that intercepts Delete / Backspace when
    /// a link OR a frame is selected in `CanvasHost` (Phase 6e Steps
    /// 2–3). Routes the delete through `WorkspaceStore.deleteLink` /
    /// `.deleteFrame` — the store's mutations land on `NSUndoManager`
    /// via `WebFramesDocument`'s delegate, so Cmd+Z restores the
    /// removed element.
    ///
    /// Link takes priority over frame (mirrors the JS policy at
    /// `index.html:2315`: "prefer deleting a selected link over a
    /// selected frame"). When neither is selected the event passes
    /// through untouched.
    private var canvasDeleteKeyMonitor: Any?

    init(document: WebFramesDocument) {
        let defaultRect = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(
            contentRect: defaultRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = WFDesign.bg2
        WFTheme.apply(to: window)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 800, height: 600)
        // We manage window lifetime via NSDocument + Start window — AppKit's
        // automatic restoration would try to re-instantiate windows with no
        // registered restoration class, logging "className=(null)".
        window.isRestorable = false
        // UI test anchor — see StartWindowController for rationale.
        window.identifier = NSUserInterfaceItemIdentifier("webframes.project")
        window.setAccessibilityIdentifier("documentWindow")

        // Phase 6e sidebar-refactor Step 1: the window's content is now
        // a split-view controller (sidebar + canvas), not the canvas
        // host on its own. Setting `contentViewController` replaces
        // `contentView` and also wires the responder chain so
        // `.toggleSidebar(_:)` from the toolbar / ⌘⌥S reaches the split
        // VC without a manual first-responder swap.
        let splitVC = DocumentSplitViewController(document: document)
        self.splitViewController = splitVC
        self.canvasHost = splitVC.canvasVC.canvasHost
        window.contentViewController = splitVC
        self.boundDocument = document

        // Build the brand stack (logo glyph + "web frames" wordmark)
        // before super.init — the ivars are `let`, so they must be
        // initialized on every path out of this init. Layout/pinning
        // happens in `configureLogoStack()` below, which runs after
        // super.init once `window.contentView` is reachable.
        self.logoView = NSImageView(image: CanvasHost.loadRendererLogo() ?? NSImage())
        self.logoLabel = NSTextField(labelWithString: "web frames")
        self.logoStack = NSStackView(views: [])

        super.init(window: window)
        astraReviewWindow = AstraReviewWindow(owner:self,project:document)
        canvasHost.onFixCommentsWithCodex = { [weak self] in
            self?.astraReviewWindow?.fixOpenComments()
        }

        // Toolbar wiring. `.unified` paints the toolbar as part of the
        // title band (no visible chrome break between the title band and
        // the content), which is what lets the sidebar extend up to the
        // window top under the traffic-lights — same pattern Mail, Finder,
        // and Notes use. `.sidebarTrackingSeparator` is positioned
        // automatically by AppKit so the vertical divider in the title
        // band lines up with the split divider below it; `.toggleSidebar`
        // is the stock item that dispatches to `toggleSidebar(_:)` on the
        // responder chain (reaches `DocumentSplitViewController`).
        let toolbar = NSToolbar(identifier: "webframes.document.toolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // Do NOT set self.document = document here — Apple's docs say
        // NSWindowController.document must not be set directly. The document
        // binding happens inside NSDocument.addWindowController(_:), which
        // makeWindowControllers() calls for us. Setting it here poisons that
        // path: addWindowController sees wc.document == self and takes an
        // early-out branch that skips appending wc to windowControllers,
        // leaving the document with zero controllers and no visible window.
        window.delegate = self

        configureLogoStack()
        logoStack.isHidden = true
        canvasHost.makeProjectImportView = { [weak self] onChange in self?.projectImportView(onChange: onChange) }
        canvasHost.onBeforeAddFrame = { [weak self] in self?.showFlow() }
        canvasHost.onOpenSettings = { [weak self] in self?.showSettings() }
        configureDockPlacement()
        configureTitleField(initialName: document.payload.name)

        // Open projects with room for the canvas and both sidebars. Apply
        // this after autosave registration so an old small window cannot
        // override the requested opening size. visibleFrame excludes the
        // menu bar and Dock; the window remains freely resizable.
        window.setFrameAutosaveName(Self.autosaveName(for: document))
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            // Each project already open shifts the new window down and to
            // the right, so several projects stay visible instead of
            // stacking exactly on top of each other.
            let open = NSApp.windows.filter {
                $0 !== window && $0.identifier == window.identifier && ($0.isVisible || $0.isMiniaturized)
            }.count
            let step = CGFloat(min(open, 8)) * 28
            var frame = screen.visibleFrame.insetBy(dx: 16, dy: 16)
            frame.origin.x += step
            frame.size.width -= step
            frame.size.height -= step
            window.setFrame(frame, display: false)
        } else {
            window.center()
        }

        Log.doc.info("DocumentWindowController init — frame=\(NSStringFromRect(window.frame), privacy: .public)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        Log.doc.info("DocumentWindowController deinit")
    }

    // MARK: - Show

    /// NSDocument.showWindows() iterates controllers and calls this; we log
    /// plus hard-activate the app so that even when Start is order-out'd in
    /// the same event cycle, the doc window reliably lands in front.
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard let w = window else { return }
        // If the saved autosave frame is off-screen (older build, external
        // display disconnected, etc.), re-center. Otherwise trust it.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(w.frame) }) {
            Log.doc.error("DocumentWindowController: saved frame \(NSStringFromRect(w.frame), privacy: .public) is off all screens — re-centering")
            w.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.orderFrontRegardless()
        if w.firstResponder === w { w.makeFirstResponder(canvasHost) }
        installCanvasEventMonitors()
        // Phase 6e sidebar-refactor Step 1: the old local ⌘1 monitor that
        // called `canvasHost.toggleFramesSidebar()` was removed — the
        // native split VC provides system-generated ⌘⌥S through the
        // responder chain (reaches `DocumentSplitViewController.toggleSidebar`).
        // The dock button that also called into that path was deleted on
        // 2026-04-21 when Egor asked to drop it — toolbar + ⌘⌥S are the
        // only entry points now.
        Log.doc.info("DocumentWindowController.showWindow — visible=\(w.isVisible) key=\(w.isKeyWindow) frame=\(NSStringFromRect(w.frame), privacy: .public)")
    }

    /// Both NSDocument.showWindows and the launcher's direct window opening
    /// need these handlers. Each installer is idempotent, so reactivation
    /// cannot register duplicate actions; windowWillClose removes them all.
    private func installCanvasEventMonitors() {
        installUndoKeyMonitor()
        installCanvasGestureMonitor()
        installCanvasDeselectMonitor()
        installCanvasDeleteKeyMonitor()
        installCanvasPanKeyMonitor()
        installCanvasPanDragMonitor()
        installCanvasAnnotationClickMonitor()
        installCanvasShortcutKeyMonitor()
    }

    // MARK: - Undo key monitor

    /// Installs a local keydown monitor that consumes Cmd+Z /
    /// Shift+Cmd+Z for this document's window. The monitor fires before
    /// the key event is dispatched into the responder chain, so
    /// WKWebView (and therefore the JS window-level keydown handler)
    /// never sees it — guaranteeing a single source of truth for undo.
    ///
    /// Idempotent: safe to call from multiple `showWindow` turns (e.g.
    /// if the window gets hidden and re-shown).
    private func installUndoKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleUndoKeyDown(event)
        }
    }

    /// Returns nil to consume the event, or the original event to pass
    /// it through to the next handler. Guards:
    ///   * Only events targeting *this* window are considered — avoids
    ///     stealing Cmd+Z from the Start window or a sibling document.
    ///   * Only bare `Cmd+Z` and `Shift+Cmd+Z` are intercepted; any
    ///     additional modifier (Option, Control, Caps Lock, Fn) falls
    ///     through so custom shortcuts aren't hijacked.
    ///   * If the document has no undoManager (torn down mid-event),
    ///     the event passes through.
    private func handleUndoKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window?.attachedSheet == nil, projectMapController?.isPresented != true, componentCatalogue?.isPresented != true else { return event }
        guard !canvasHost.isModalPresented, !keyboardFocusIsEditor, CanvasKeyboard.isUndo(event) else { return event }
        let mods = CanvasKeyboard.modifiers(event)
        guard let undoManager = boundDocument?.undoManager else { return event }
        if mods.contains(.shift) {
            if undoManager.canRedo { undoManager.redo() }
        } else {
            if undoManager.canUndo { undoManager.undo() }
        }
        return nil
    }

    private func removeUndoKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Canvas gesture monitor (Phase 6e Step 1)

    /// Installs a local `.scrollWheel` + `.magnify` monitor that consumes
    /// trackpad and mouse-wheel gestures over the canvas region. Idempotent
    /// across multiple `showWindow` turns.
    ///
    /// The monitor returns nil (consume) for gestures over the canvas
    /// surface and passes the event through unmodified otherwise —
    /// scrolling over the annotation panel's pin list, over the dock, or
    /// while a modal is up behaves exactly as before because the native
    /// path takes no action and the event reaches the subview / WKWebView
    /// that would have received it pre-monitor.
    private func installCanvasGestureMonitor() {
        guard canvasGestureMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .magnify]
        canvasGestureMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleCanvasGesture(event) ?? event
        }
    }

    /// Decides whether a given scroll/magnify event is a canvas pan/zoom
    /// and applies it via `workspace.setViewport(_:)`. Returns nil to
    /// consume, or the event to pass through.
    ///
    /// Pass-through cases (each intentional):
    ///   * Different window — a document's monitor isn't allowed to
    ///     steal scrolls from sibling windows (Start, about, another
    ///     open document).
    ///   * No document — mid-tear-down, don't fire late.
    ///   * Modal is up — scrolling over the add-frame modal or pin-editor
    ///     shouldn't pan the canvas behind it; we let the event flow
    ///     normally so modal list scrolling (if any) still works.
    ///   * Hit target is the annotation panel or the dock — the panel's
    ///     NSScrollView scrolls its pin list; the dock is a stack view
    ///     with no scroll affordance but we still don't want surprise
    ///     canvas pans under the user's fingers on dock chrome.
    ///
    /// Math: see `ViewportModel.panned(byX:byY:)` and
    /// `ViewportModel.zoomed(multiplier:aroundX:aroundY:)` — those are
    /// the pure functions ported from the JS wheel handler at
    /// `index.html:664`. Here we only translate AppKit event fields
    /// (`scrollingDeltaX/Y`, `magnification`, modifier flags, cursor
    /// position) into their inputs.
    // Trackpads deliver scroll and pinch events faster than the display
    // refreshes. Viewport changes are collected and applied once per frame,
    // so each frame does the layout work once instead of per event.
    private var pendingViewport: ViewportModel?
    private var viewportDisplayLink: CADisplayLink?

    private func queueViewport(_ viewport: ViewportModel) {
        pendingViewport = viewport
        guard viewportDisplayLink == nil else { return }
        let link = canvasHost.displayLink(target: self, selector: #selector(flushPendingViewport(_:)))
        link.add(to: .main, forMode: .common)
        viewportDisplayLink = link
    }

    @objc private func flushPendingViewport(_ link: CADisplayLink) {
        guard let viewport = pendingViewport else {
            link.invalidate(); viewportDisplayLink = nil
            return
        }
        pendingViewport = nil
        boundDocument?.workspace.setViewport(viewport)
    }

    private func handleCanvasGesture(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window?.attachedSheet == nil, projectMapController?.isPresented != true, componentCatalogue?.isPresented != true else { return event }
        guard let workspace = boundDocument?.workspace else { return event }
        // Modal-up: consume nothing, swallow nothing — the modal's own
        // event handling decides what scrolling does inside it.
        if canvasHost.isModalPresented { return event }

        let locInWindow = event.locationInWindow
        // Hit-target gates.
        let gestureHostPoint = canvasHost.convert(locInWindow, from: nil)
        if canvasHost.isAnnotationPanelRegion(gestureHostPoint) { return event }
        if canvasHost.isDockRegion(gestureHostPoint)             { return event }
        if splitViewController.isHitInSidePanel(locInWindow)  { return event }

        // Convert to canvas-local top-left-origin coords so the zoom
        // anchor lines up with JS's cursor-centric math. CanvasHost is
        // not `isFlipped`, so AppKit gives us bottom-left-origin; px/py
        // live in top-left space (same as `cv.style.transform`). Flip
        // the Y explicitly here rather than retrofitting isFlipped —
        // too many things (title field autolayout, dock y=16-from-bottom)
        // assume the current convention.
        let locInHost = canvasHost.convert(locInWindow, from: nil)
        guard canvasHost.bounds.contains(locInHost) else { return event }
        let anchorX = locInHost.x
        let anchorY = canvasHost.bounds.height - locInHost.y

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.type {
        case .scrollWheel:
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            let isZoomGesture = mods.contains(.command) || mods.contains(.control)
            // Scroll inside a selected frame should move the page, not pan
            // the canvas. Zoom gestures (Cmd/Ctrl+scroll) still zoom the
            // canvas — that matches a user zooming out of a frame they're
            // reading, and avoids conflating with browser-level ⌘+scroll
            // zoom which isn't a thing here anyway.
            if !isZoomGesture &&
               canvasHost.isSelectedFrameBodyRegion(gestureHostPoint) {
                return event
            }
            if isZoomGesture {
                // Cmd/Ctrl+scroll → zoom around cursor. JS uses
                // `zoomFactor = exp(-e.deltaY * 0.0015)` on DOM delta,
                // where up-swipe is `deltaY < 0`. AppKit sign-flips:
                // up-swipe → `scrollingDeltaY > 0`. Dropping the minus
                // keeps up-swipe → zoom-in, same physical direction.
                let factor = exp(dy * 0.0015)
                let next = (pendingViewport ?? workspace.viewport).zoomed(
                    multiplier: factor, aroundX: anchorX, aroundY: anchorY
                )
                queueViewport(next)
            } else {
                // Pan. Shift+wheel on a regular (non-precision) mouse
                // flips vertical into horizontal — mirrors the JS
                // `e.shiftKey && !e.deltaX` branch, which is specifically
                // for users on a mouse that has no dedicated X wheel.
                // Trackpad events have `hasPreciseScrollingDeltas == true`
                // and already carry a native dx, so we skip the flip.
                let panDX: CGFloat
                let panDY: CGFloat
                if !event.hasPreciseScrollingDeltas &&
                    mods.contains(.shift) && dx == 0 {
                    panDX = dy
                    panDY = 0
                } else {
                    panDX = dx
                    panDY = dy
                }
                let next = (pendingViewport ?? workspace.viewport).panned(byX: panDX, byY: panDY)
                queueViewport(next)
            }
            return nil

        case .magnify:
            // Pinch → zoom around cursor. `event.magnification` is a
            // fractional delta per tick (e.g. 0.03 for a small pinch
            // step), so the multiplier is `1 + magnification`. At the
            // zoom rails (0.05 / 5) the clamp inside `zoomed` pins
            // `scale` and the helper bails out with `self` — no pan
            // drift from over-zoom at the rails.
            let next = (pendingViewport ?? workspace.viewport).zoomed(
                multiplier: 1 + event.magnification,
                aroundX: anchorX, aroundY: anchorY
            )
            queueViewport(next)
            return nil

        default:
            return event
        }
    }

    private func removeCanvasGestureMonitor() {
        if let monitor = canvasGestureMonitor {
            NSEvent.removeMonitor(monitor)
            canvasGestureMonitor = nil
        }
    }

    // MARK: - Canvas deselect / delete monitors (Phase 6e Steps 2–3)

    /// Clears the host's link AND frame selection when the user
    /// left-clicks away from both (Phase 6e Step 3 generalization of
    /// the Step 2 link-deselect monitor). Mirrors JS
    /// `cw.addEventListener('mousedown')`'s canvas-background branch —
    /// any click that doesn't hit a link curve or a frame card drops
    /// both selection rings at once.
    ///
    /// Order matters: link deselect runs first so a click on a frame
    /// card doesn't accidentally wipe a prior link selection (frames
    /// sit below the LinkLayerView visually but above it in z-order
    /// outside link curves — `FrameCardView.mouseDown` → `.select`
    /// intent → `canvasHost.selectFrame` already handles the mutual
    /// exclusivity, so clicks on a frame never reach the frame-deselect
    /// branch below).
    private func installCanvasDeselectMonitor() {
        guard canvasDeselectMonitor == nil else { return }
        canvasDeselectMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleCanvasDeselect(event)
            return event
        }
    }

    private func handleCanvasDeselect(_ event: NSEvent) {
        guard event.window === window, !isInWindowChrome(event), !splitViewController.isHitInSidePanel(event.locationInWindow) else { return }
        // Modal up: backdrop click dismisses the modal; canvas state
        // shouldn't mutate underneath.
        if componentCatalogue?.isPresented == true || canvasHost.isModalPresented || astraReviewWindow?.containsControl(at:event.locationInWindow) == true { return }
        let hostPoint = canvasHost.convert(event.locationInWindow, from: nil)
        if canvasHost.isArrangementBarRegion(hostPoint) || canvasHost.isDockRegion(hostPoint) || canvasHost.isAnnotationPanelRegion(hostPoint) { return }
        // `LinkLayerView.hitTest(_:)` expects its superview's coord
        // space — linkLayer is a direct child of canvasHost, so
        // hostPoint is exactly that.
        let onLink  = canvasHost.linkLayer.hitTest(hostPoint) != nil
        let frameHit = canvasHost.frameCardId(at: hostPoint)
        if !onLink  { canvasHost.clearLinkSelectionIfNeeded() }
        if let frameId = frameHit {
            // Click anywhere on a frame card — chrome, body, or webview —
            // promotes it to selected. FrameCardView.mouseDown already
            // does this for clicks that land on empty card background;
            // the window-level monitor covers clicks consumed by inner
            // subviews (WKWebView, toolbar, etc.) so selection follows
            // the user's intent everywhere on the card.
            canvasHost.selectFrame(frameId)
        }
    }

    private func removeCanvasDeselectMonitor() {
        if let monitor = canvasDeselectMonitor {
            NSEvent.removeMonitor(monitor)
            canvasDeselectMonitor = nil
        }
    }

    /// Phase 6e Step 8: tracks space-held for transient pan cursor,
    /// V-toggle for persistent pan lock, and the click-drag pan gesture
    /// itself. See `installCanvasPanKeyMonitor` / `installCanvasPanDragMonitor`.
    private var canvasPanKeyMonitor: Any?
    private var canvasShortcutKeyMonitor: Any?
    private var canvasPanDragMonitor: Any?

    /// Phase 6e Step 6: consumes `.leftMouseDown` while annotation mode
    /// is armed, hit-tests against frame bodies in Swift, and kicks off
    /// the DOM-context round-trip to open the pin editor without a JS
    /// round-trip. Paired with the `annotation-mode` envelope handler
    /// in `NativeBridge`, which mirrors the flag onto `canvasHost`.
    ///
    /// When annotation mode is off, the event passes through unchanged.
    private var canvasAnnotationClickMonitor: Any?

    /// Consumes Delete / Backspace when a link OR frame is selected;
    /// otherwise passes through. Matches the JS policy at
    /// `index.html:2315` — "prefer deleting a selected link over a
    /// selected frame" — so a link always wins when both flags happen
    /// to be set simultaneously (shouldn't happen because the selection
    /// setters clear the other kind, but we keep the priority here as
    /// a second line of defense).
    private func installCanvasDeleteKeyMonitor() {
        guard canvasDeleteKeyMonitor == nil else { return }
        canvasDeleteKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleCanvasDeleteKeyDown(event)
        }
    }

    private func handleCanvasDeleteKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window?.attachedSheet == nil, projectMapController?.isPresented != true, componentCatalogue?.isPresented != true else { return event }
        // Fast-out when nothing is selected — avoids walking the
        // modifier/keycode checks on every typed character.
        guard canvasHost.selectedLinkId != nil ||
              canvasHost.selectedFrameId != nil else { return event }
        // Don't steal Delete while the title field (or any other text
        // editor) is the first responder — user is editing the project
        // name, not trying to delete canvas state. `NSText` is the
        // field editor that NSTextField/NSTextView vend for actual
        // typing, so checking against it covers both.
        if canvasHost.isModalPresented || keyboardFocusIsEditor { return event }
        // Delete = 0x33, Forward-Delete = 0xF728 / NSDeleteFunctionKey.
        // Using the keyCode enumerations rather than the character
        // because some keyboard layouts map the same key to varying
        // unicode codepoints.
        let deleteCodes: Set<UInt16> = [51, 117]
        guard deleteCodes.contains(event.keyCode) else { return event }
        // Ignore modifier combos — plain Delete/Backspace only.
        guard CanvasKeyboard.modifiers(event).isEmpty else { return event }
        if canvasHost.deleteSelectedLink() {
            return nil  // consumed — link beats frame
        }
        if canvasHost.deleteSelectedFrame() {
            return nil  // consumed
        }
        return event
    }

    private func removeCanvasDeleteKeyMonitor() {
        if let monitor = canvasDeleteKeyMonitor {
            NSEvent.removeMonitor(monitor)
            canvasDeleteKeyMonitor = nil
        }
    }

    // MARK: - Pan (space / V / click-drag) monitors (Phase 6e Step 8)

    /// Space temporarily selects the hand tool. Release is handled even if focus changes.
    private func installCanvasPanKeyMonitor() {
        guard canvasPanKeyMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp]
        canvasPanKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return self.handleCanvasPanKey(event)
        }
    }

    /// Returns `nil` to consume the event (suppress NSWindow's
    /// "unhandled key" beep), or the event itself to pass it along.
    private func handleCanvasPanKey(_ event: NSEvent) -> NSEvent? {
        guard event.window === window else { return event }
        if event.keyCode == 49, event.type == .keyUp, canvasHost.spaceHeld {
            canvasHost.setSpaceHeld(false)
            return nil
        }
        guard window?.attachedSheet == nil, !canvasHost.isModalPresented,
              componentCatalogue?.isPresented != true, !keyboardFocusIsEditor,
              !(window?.firstResponder is NSControl), !(window?.firstResponder is DockButton),
              event.keyCode == 49, CanvasKeyboard.modifiers(event).isEmpty else { return event }
        if event.type == .keyDown, !event.isARepeat { canvasHost.setSpaceHeld(true) }
        return nil
    }

    private func removeCanvasPanKeyMonitor() {
        if let monitor = canvasPanKeyMonitor {
            NSEvent.removeMonitor(monitor)
            canvasPanKeyMonitor = nil
        }
    }

    // MARK: - Canvas shortcut keys (a / 0 / + / -)

    /// Route physical canvas shortcuts without stealing typing or modal controls.
    private func installCanvasShortcutKeyMonitor() {
        guard canvasShortcutKeyMonitor == nil else { return }
        canvasShortcutKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // No `?? event` fallback — if the handler returns nil we want
            // the event CONSUMED (otherwise the responder chain receives
            // the key, no one handles it, and NSWindow plays the "unhandled
            // key" beep). The weak-self branch still returns event so we
            // don't accidentally swallow keys after the controller dies.
            guard let self else { return event }
            return self.handleCanvasShortcutKeyDown(event)
        }
    }

    /// Text and embedded browsers own their keyboard input; canvas chrome does not.
    private var keyboardFocusIsEditor: Bool {
        if window?.firstResponder is NSText { return true }
        var view = window?.firstResponder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }

    private func handleCanvasShortcutKeyDown(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window?.attachedSheet == nil else { return event }
        if CanvasKeyboard.isPaste(event) {
            if keyboardFocusIsEditor {
                // Cmd+V stays native. Also support the explicitly requested Ctrl+V alias.
                if CanvasKeyboard.modifiers(event) == .control,
                   NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return nil }
                return event
            }
            guard componentCatalogue?.isPresented != true else { return event }
            if canvasHost.isModalPresented {
                return canvasHost.pasteIntoAddFrameModal() ? nil : event
            }
            return canvasHost.pasteImageFrames(from: .general) ? nil : event
        }
        guard !canvasHost.isModalPresented, componentCatalogue?.isPresented != true, !keyboardFocusIsEditor else { return event }
        if event.keyCode == 0, CanvasKeyboard.modifiers(event) == .command {
            canvasHost.setFrameSelection(canvasHost.document?.workspace.frames.map(\.id) ?? []); return nil
        }
        if event.keyCode == 53, canvasHost.isMarqueeSelecting { canvasHost.cancelMarquee(); return nil }
        guard CanvasKeyboard.allowsCanvasShortcut(event) else { return event }
        let action: DockView.Action?
        switch event.keyCode {
        case 8: action = .toggleAnnotation
        case 3: action = .addFrame
        case 9: action = .selectCursor
        case 4: action = .selectPan
        case 35:
            canvasHost.zoomToSelectedFrame()
            return nil
        case 29, 82: action = .zoomFit
        case 24, 69: action = .zoomIn
        case 27, 78: action = .zoomOut
        default: action = nil
        }
        if let action {
            if !event.isARepeat || [.zoomIn, .zoomOut].contains(action) {
                canvasHost.performDockAction(action)
            }
            return nil
        }
        // Keep Tab, Escape, arrows and unassigned keys in the responder chain.
        return event
    }

    private func removeCanvasShortcutKeyMonitor() {
        if let monitor = canvasShortcutKeyMonitor {
            NSEvent.removeMonitor(monitor)
            canvasShortcutKeyMonitor = nil
        }
    }

    /// Watches `.leftMouseDown` / `.leftMouseDragged` / `.leftMouseUp`
    /// for click-drag canvas pans. Only starts a drag when:
    ///   * The click is in this window.
    ///   * No modal is up.
    ///   * Either `spaceHeld` OR `panLocked` is true.
    ///   * Click is NOT on a frame card (frames still own
    ///     click-to-select / drag even while space is held — mirrors
    ///     the JS `target===cw||target===cv||target===dc` guard at
    ///     `index.html:748`).
    ///   * Click is NOT on the dock / annotation panel / link curve
    ///     (dock buttons and panel controls keep working; links stay
    ///     clickable so the user can select a link while in pan mode).
    ///
    /// Returns `nil` from the mousedown handler to consume the event
    /// so downstream (FrameCardView mouseDown, canvasDeselect) doesn't
    /// also run for the same gesture. Drag/up pass through unchanged
    /// — AppKit needs the full leftMouseUp to clean up its gesture
    /// state, and we don't want to block future clicks.
    private func installCanvasPanDragMonitor() {
        guard canvasPanDragMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        canvasPanDragMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            return self.handleCanvasPanDrag(event)
        }
    }

    /// The canvas extends under the unified title bar and toolbar
    /// (.fullSizeContentView). Clicks there belong to the toolbar buttons
    /// (inspector toggle, Settings, Reload) and the window, never the canvas.
    private func isInWindowChrome(_ event: NSEvent) -> Bool {
        guard let window else { return false }
        return event.locationInWindow.y >= window.contentLayoutRect.maxY
    }

    private func handleCanvasPanDrag(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window?.attachedSheet == nil, projectMapController?.isPresented != true, componentCatalogue?.isPresented != true else { return event }
        // A drag that started on the toolbar never became a canvas gesture.
        if event.type == .leftMouseDown, isInWindowChrome(event) { return event }

        switch event.type {
        case .leftMouseDown:
            if canvasHost.isModalPresented { return event }
            let hostPoint = canvasHost.convert(event.locationInWindow, from: nil)
            // Let frames, dock, panel, and link curves keep their
            // click semantics even while space is held.
            if canvasHost.isFrameCardRegion(hostPoint) { return event }
            if canvasHost.isDockRegion(hostPoint) || canvasHost.isArrangementBarRegion(hostPoint) { return event }
            if canvasHost.isAnnotationPanelRegion(hostPoint) { return event }
            // Sidebar lives in a different split pane now — check against
            // the split VC (window coords), not the canvasHost hit-test.
            if splitViewController.isHitInSidePanel(event.locationInWindow) { return event }
            if canvasHost.linkLayer.hitTest(hostPoint) != nil { return event }
            if astraReviewWindow?.containsControl(at: event.locationInWindow) == true { return event }
            var hit = canvasHost.hitTest(hostPoint)
            while let view = hit, view !== canvasHost {
                if view is NSControl { return event }
                hit = view.superview
            }
            if !canvasHost.spaceHeld && !canvasHost.panLocked {
                guard !canvasHost.annotationMode, canvasHost.bounds.contains(hostPoint) else { return event }
                canvasHost.beginMarquee(at: hostPoint, additive: !event.modifierFlags.intersection([.shift, .command]).isEmpty)
                window?.makeFirstResponder(canvasHost)
                return nil
            }
            if canvasHost.beginPanDrag(at: event.locationInWindow) {
                return nil  // consume — no frame select, no deselect.
            }
            return event
        case .leftMouseDragged:
            if canvasHost.isMarqueeSelecting {
                canvasHost.updateMarquee(at: canvasHost.convert(event.locationInWindow, from: nil)); return nil
            }
            guard canvasHost.isPanDragging else { return event }
            canvasHost.updatePanDrag(at: event.locationInWindow)
            return nil  // consume so child views don't also drag.
        case .leftMouseUp:
            if canvasHost.isMarqueeSelecting { canvasHost.endMarquee(); return nil }
            guard canvasHost.isPanDragging else { return event }
            canvasHost.endPanDrag()
            return nil
        default:
            return event
        }
    }

    private func removeCanvasPanDragMonitor() {
        if let monitor = canvasPanDragMonitor {
            NSEvent.removeMonitor(monitor)
            canvasPanDragMonitor = nil
        }
    }

    // MARK: - Annotation click monitor (Phase 6e Step 6)

    /// Watches `.leftMouseDown` for annotation-mode clicks. When
    /// annotation mode is armed and the click lands on empty canvas
    /// (not dock / panel / modal), consumes the event and dispatches
    /// to `CanvasHost.beginAnnotationPress` — which hit-tests the
    /// frame bodies, fires a `wf-inspect` at the target, and opens
    /// the native pin editor on the inspect reply.
    ///
    /// Ordering note: this monitor is installed AFTER the pan monitor,
    /// so if both armed-pan and armed-annotation somehow overlap, pan
    /// wins (the pan monitor sees the event first and consumes it).
    /// In practice this can't happen — the dock's annotation-mode
    /// toggle and space/V pan gestures are exclusive at the UI
    /// level — but the precedence matters if a future keybind breaks
    /// that assumption.
    ///
    /// Consumes via `return nil` so neither the canvas WKWebView's
    /// `.shld` click handler nor the frame-card mouseDown path runs
    /// for the same gesture. The `FrameContainer.hitTest` → nil
    /// behavior in annotation mode already prevents per-frame
    /// WKWebViews from seeing the click, but we still want to stop
    /// the canvas WKWebView's legacy JS path from firing in parallel.
    private func installCanvasAnnotationClickMonitor() {
        guard canvasAnnotationClickMonitor == nil else { return }
        canvasAnnotationClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown: return self.handleCanvasAnnotationClick(event)
            // Drag and up belong to a press the host accepted on mouse down;
            // anything else (header drags, the pin editor) flows on.
            case .leftMouseDragged:
                guard event.window === self.window else { return event }
                return self.canvasHost.dragAnnotationPress(toWindowPoint: event.locationInWindow) ? nil : event
            case .leftMouseUp:
                guard event.window === self.window else { return event }
                return self.canvasHost.endAnnotationPress(atWindowPoint: event.locationInWindow) ? nil : event
            default: return event
            }
        }
    }

    private func handleCanvasAnnotationClick(_ event: NSEvent) -> NSEvent? {
        guard event.window === window, window?.attachedSheet == nil, projectMapController?.isPresented != true, componentCatalogue?.isPresented != true else { return event }
        guard canvasHost.annotationMode, !isInWindowChrome(event) else { return event }
        // Modal up: never consume — the user may be clicking inside
        // the pin editor they just opened for a brand-new draft, or
        // backdrop-dismissing it.
        if canvasHost.isModalPresented { return event }
        let hostPoint = canvasHost.convert(event.locationInWindow, from: nil)
        // Dock, annotation panel, and the link layer all keep their
        // click semantics in annotation mode. The frame card region
        // check is intentionally absent — `FrameContainer.hitTest`
        // already returns nil in annotation mode, so body clicks
        // reach the canvas; header/handle clicks still hit their
        // subview (the body gate is on the container, not the card).
        // We perform body-rect hit-testing inside `beginAnnotationPress`
        // to determine whether a frame's body actually owns the click.
        if canvasHost.isDockRegion(hostPoint)            { return event }
        if canvasHost.isAnnotationPanelRegion(hostPoint) { return event }
        // Sidebar is in a different split pane — check window coords.
        if splitViewController.isHitInSidePanel(event.locationInWindow) { return event }
        if canvasHost.linkLayer.hitTest(hostPoint) != nil { return event }
        // Dispatch into the host. The host returns `true` only when
        // the click landed on a frame's body (the JS `.shld` overlay
        // region); in that case we consume the event so neither the
        // canvas WKWebView's JS `.shld` handler nor the per-frame
        // WKWebView below gets a duplicate. `false` means the click
        // missed every body — could be a header, a resize handle, or
        // truly empty canvas. Let it flow through so header drag /
        // resize / close-button still work even while annotation mode
        // is armed, matching JS where `.shld` only overlaid `.fb`.
        if canvasHost.beginAnnotationPress(atWindowPoint: event.locationInWindow) {
            return nil
        }
        return event
    }

    private func removeCanvasAnnotationClickMonitor() {
        if let monitor = canvasAnnotationClickMonitor {
            NSEvent.removeMonitor(monitor)
            canvasAnnotationClickMonitor = nil
        }
    }

    // MARK: - Brand stack (centered at the top of the window)

    /// Pins the `logo.svg` + "web frames" wordmark stack to the window
    /// content view's centerX / top. Phase 6e sidebar-refactor Step 3
    /// hoisted the brand out of `CanvasHost` (where it pinned 92pt from
    /// the leading edge, just past the traffic lights) onto the window
    /// itself so it reads as a window-level mark instead of a host-local
    /// corner label.
    ///
    /// The stack is decorative: no hit-testing, no tooltip. Clicks that
    /// land on top of it fall through to the titlebar drag strip beneath
    /// so window dragging keeps working.
    ///
    /// Note on parent choice: `window.contentView` here is the
    /// `NSSplitView` inside `DocumentSplitViewController` (because
    /// `contentViewController = splitVC`). Adding a subview to an
    /// `NSSplitView` is not part of its arranged-subviews layout —
    /// `NSSplitView` only lays out its `arrangedSubviews`, so an
    /// overlay subview is left at the constraint positions we give
    /// it. This is the same pattern as `NSSplitView`-hosting windows
    /// in Xcode / Mail that overlay accessory chrome above the split.
    private func configureLogoStack() {
        guard let parent = window?.contentView else { return }

        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.translatesAutoresizingMaskIntoConstraints = false
        logoView.setAccessibilityIdentifier("webframes.logo")
        NSLayoutConstraint.activate([
            logoView.widthAnchor.constraint(equalToConstant: 26),
            logoView.heightAnchor.constraint(equalToConstant: 17),
        ])

        // Wordmark next to the glyph. `.medium` weight + 12pt reads as a
        // brand mark rather than a generic UI label; `text2` (medium
        // emphasis) keeps it from competing with document content below.
        logoLabel.font = .systemFont(ofSize: 12, weight: .medium)
        logoLabel.textColor = WFDesign.text2
        logoLabel.isEditable = false
        logoLabel.isBordered = false
        logoLabel.drawsBackground = false
        logoLabel.setAccessibilityIdentifier("webframes.logoLabel")
        logoLabel.translatesAutoresizingMaskIntoConstraints = false

        logoStack.orientation = .horizontal
        logoStack.alignment = .centerY
        logoStack.spacing = 8
        logoStack.addArrangedSubview(logoView)
        logoStack.addArrangedSubview(logoLabel)
        logoStack.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(logoStack)

        NSLayoutConstraint.activate([
            logoStack.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            logoStack.topAnchor.constraint(equalTo: parent.topAnchor, constant: 14),
        ])
    }

    // MARK: - Dock placement (window-centered, sidebar-invariant)

    /// Pins `canvasHost.dock` to the window's content view so its horizontal
    /// position is strictly window-centered and doesn't shift when the
    /// sidebar opens or closes. Sidebar-refactor Step 3 follow-up
    /// (2026-04-21 evening): Egor asked "сделай так чтобы панель
    /// управления не ездела за сайдпейджем а всегда была строго по
    /// центру" — the old placement pinned the dock to
    /// `canvasHost.centerXAnchor` (the main pane), so opening the
    /// sidebar dragged the dock right by half of the sidebar's width.
    /// Window-centering fixes that.
    ///
    /// Ownership note: `dock` is still `let dock: DockView` on
    /// `CanvasHost`. The host constructs it and sets its delegate —
    /// only the view-tree parent changed. The dock is added as a
    /// non-arranged subview of the `NSSplitView` (which is
    /// `window.contentView`), so it sits on top of both the sidebar
    /// pane and the canvas pane in z-order. That preserves the
    /// "dock occludes per-frame WKWebViews where they overlap"
    /// property that was the whole point of the native-dock migration.
    ///
    /// Narrow-window note: in very narrow windows the dock's window-
    /// centered position may visually overlap the sidebar pane (since
    /// the sidebar takes 220–320pt of the leading edge). The dock
    /// still wins clicks because it's above the sidebar in z-order,
    /// and the sidebar material reads clearly around the dock's
    /// capsule shape. Acceptable trade-off — the alternative
    /// (clipping the dock to the main pane) would restore the
    /// sidebar-riding behavior we just fixed.
    private func configureDockPlacement() {
        guard let parent = window?.contentView else { return }
        let dock = canvasHost.dock
        // The dock was `addSubview`'d by `CanvasHost` in earlier cuts;
        // Step 3 removed that call. Defensive `removeFromSuperview` in
        // case of any leftover (no-op if the view has no superview).
        dock.removeFromSuperview()
        parent.addSubview(dock)
        NSLayoutConstraint.activate([
            dock.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
            dock.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -16),
        ])
        // Force dock to the top of z-order via CALayer zPosition. Subview
        // order alone is not always respected when siblings include a
        // layer-hosting `NSVisualEffectView` (the sidebar pane) or
        // WKWebView-backed descendants (the per-frame web views inside
        // `canvasHost.frameLayer`) — both of those can render above
        // normal AppKit views in spite of the `addSubview` order
        // because they composite on their own `CALayer`s. Setting
        // `wantsLayer = true` plus a high `zPosition` pulls the dock's
        // layer to the front of the layer-tree render order, so the
        // dock is never occluded by the sidebar material or by frame
        // web views regardless of sidebar collapse state or frame
        // placement. Value 1000 is arbitrary but comfortably above
        // anything else in the window (nothing else sets zPosition).
        //
        // Follow-up on 2026-04-21 evening — Egor: "можем панель поднять
        // по z?". Diagnosed as the classic AppKit issue above.
        dock.wantsLayer = true
        dock.layer?.zPosition = 1000
    }

    // MARK: - Title field

    /// Native NSTextField for the document's editable project name.
    /// Commits edits on focus loss via `controlTextDidEndEditing(_:)`.
    ///
    /// Phase 6e sidebar-refactor Step 3 (2026-04-21 evening) moved this
    /// field out of the canvas-host titlebar strip and into the sidebar's
    /// `titleSlot` (the 36pt horizontal strip just below the traffic-light
    /// header spacer). The field lives in the sidebar now so users see
    /// the project name where Finder / Mail / Notes show source labels.
    /// The sidebar takes care of leading/trailing padding + vertical
    /// centering in `FramesSidebar.installTitleView(_:)` — we only hand
    /// it the configured text field.
    private func configureTitleField(initialName: String) {
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.isBordered = false
        titleField.isBezeled = false
        titleField.drawsBackground = false
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleField.textColor = WFDesign.text
        // Sidebar alignment: leading reads as a source label (Finder /
        // Mail / Notes pattern) rather than a centered titlebar caption.
        titleField.alignment = .left
        titleField.focusRingType = .none
        titleField.delegate = self
        titleField.stringValue = initialName
        titleField.placeholderString = "Untitled"
        titleField.cell?.isScrollable = true
        titleField.cell?.wraps = false
        titleField.cell?.usesSingleLineMode = true
        titleField.maximumNumberOfLines = 1
        titleField.setAccessibilityIdentifier("documentTitleField")
        // Start non-editable so the field doesn't steal first-responder
        // on window open and keep it indefinitely — that blocked every
        // command-key hotkey because keystrokes were being typed into
        // the name field. Flip to editable on double-click; the field
        // reverts when editing ends via `controlTextDidEndEditing`.
        titleField.isEditable = false
        titleField.isSelectable = false
        titleField.refusesFirstResponder = true
        let dbl = NSClickGestureRecognizer(target: self, action: #selector(beginTitleEdit))
        dbl.numberOfClicksRequired = 2
        titleField.addGestureRecognizer(dbl)

        // Sidebar owns placement (leading/trailing 12pt + centerY in the
        // 36pt titleSlot). If the split VC or sidebar isn't fully wired
        // yet (shouldn't happen — this runs after super.init), the call
        // degrades to a no-op rather than crashing the window bring-up.
        splitViewController.sidebarVC.sidebar.installTitleView(titleField)
    }

    /// Called by WebFramesDocument after a name change (e.g. revert from
    /// disk) so the titlebar field and window.title stay in sync.
    func refreshTitle() {
        guard let doc = boundDocument else { return }
        let name = doc.payload.name
        if titleField.stringValue != name { titleField.stringValue = name }
        window?.title = name
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField, tf === titleField,
              let doc = boundDocument else { return }
        doc.setName(tf.stringValue)
        // Revert to a non-editable label so hotkeys keep working after
        // the user finishes renaming. Next double-click flips it back.
        tf.isEditable = false
        tf.isSelectable = false
        tf.refusesFirstResponder = true
        tf.window?.makeFirstResponder(nil)
    }

    @objc private func beginTitleEdit() {
        titleField.refusesFirstResponder = false
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.window?.makeFirstResponder(titleField)
        titleField.currentEditor()?.selectAll(nil)
    }

    // MARK: - Toast

    /// Shown after Cmd+S to explain that auto-save is already on.
    func showAutoSaveToast() {
        ToastView.show(message: "Auto-save is on — no need to save", in: canvasHost)
    }

    // MARK: - Autosave key

    private static func autosaveName(for document: NSDocument) -> NSWindow.FrameAutosaveName {
        guard let url = document.fileURL else { return "WebFramesWindow.Untitled" }
        // Hash the full path so spaces / punctuation don't break the plist key.
        let hash = String(abs(url.path.hashValue), radix: 36)
        return "WebFramesWindow.\(hash)"
    }

    // MARK: - Title

    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        // Keep the native titlebar chrome hidden — the centered NSTextField
        // is the real title surface.
        window?.titleVisibility = .hidden
    }

    // MARK: - Delegate instrumentation

    func windowDidBecomeKey(_ notification: Notification) {
        // New Project orders the NSWindow directly and never calls showWindow.
        // Install on activation as well, before its first keyboard event.
        installCanvasEventMonitors()
        if let window, window.firstResponder == nil || window.firstResponder === window {
            window.makeFirstResponder(canvasHost)
        }
        Log.doc.info("windowDidBecomeKey — canvas event handlers ready")
    }
    func windowDidResignKey(_ notification: Notification) {
        Log.doc.info("windowDidResignKey")
        canvasHost.setSpaceHeld(false)
        // Committing an in-progress edit when the window loses key avoids
        // the "user typed a new name, clicked away, closed without blur"
        // edge case: controlTextDidEndEditing fires via endEditing.
        window?.makeFirstResponder(nil)
    }
    func windowDidExpose(_ notification: Notification) {
        Log.doc.info("windowDidExpose")
    }

    func windowWillClose(_ notification: Notification) {
        Log.doc.info("windowWillClose")
        shutDown()
        // Tear down the undo key monitor here (not in deinit) because
        // `NSEvent.removeMonitor` must run on the main actor; deinit
        // runs on an arbitrary actor under Swift 6 strict concurrency.
        removeUndoKeyMonitor()
        removeCanvasGestureMonitor()
        removeCanvasDeselectMonitor()
        removeCanvasDeleteKeyMonitor()
        removeCanvasPanKeyMonitor()
        removeCanvasPanDragMonitor()
        removeCanvasAnnotationClickMonitor()
        removeCanvasShortcutKeyMonitor()
    }

    /// Stops everything this window owns that outlives AppKit's own
    /// teardown: the Library helper, Codex flows, the dev server, the
    /// web-source probe and every frame's WKWebView. Runs from
    /// `windowWillClose` and, for Quit, from `applicationWillTerminate`
    /// (Quit does not close windows first). Idempotent.
    func shutDown() {
        componentCatalogue?.close()
        componentCatalogue = nil
        astraReviewWindow?.shutdown()
        astraReviewWindow = nil
        canvasHost.tearDown()
    }
}

// MARK: - NSToolbarDelegate

private extension NSToolbarItem.Identifier {
    static let reloadAllFrames = NSToolbarItem.Identifier("reloadAllFrames")
}

/// Feeds the window's `NSToolbar` with the two stock items the Apple-HIG
/// sidebar pattern needs: `.toggleSidebar` (a button that dispatches
/// `toggleSidebar(_:)` through the responder chain — reaches
/// `DocumentSplitViewController`) and `.sidebarTrackingSeparator` (the
/// vertical divider in the title band that AppKit positions to line up
/// with the split view's divider). `.flexibleSpace` keeps the right-hand
/// side of the toolbar from collapsing around the sidebar item when the
/// sidebar is wide.
///
/// All three identifiers are AppKit-provided — the delegate only needs to
/// list them; the `itemForItemIdentifier` method can return nil for any
/// system-provided item and AppKit still vends the correct one.
// MARK: - Menu actions
//
// View and File menu items dispatch through the responder chain to the key
// document window. The canvas key monitor still handles the same keys first;
// these give every canvas shortcut a visible, clickable menu entry.
extension DocumentWindowController: NSMenuItemValidation {
    @objc func newFrame(_ sender: Any?) {
        Log.menu.debug("new-frame from menu")
        canvasHost.presentAddFrameModal()
    }
    @objc func zoomInCanvas(_ sender: Any?) { canvasHost.performDockAction(.zoomIn) }
    @objc func zoomOutCanvas(_ sender: Any?) { canvasHost.performDockAction(.zoomOut) }
    @objc func zoomCanvasToFit(_ sender: Any?) { canvasHost.performDockAction(.zoomFit) }
    @objc func zoomCanvasToSelection(_ sender: Any?) { canvasHost.zoomToSelectedFrame() }
    @objc func selectCursorTool(_ sender: Any?) { canvasHost.performDockAction(.selectCursor) }
    @objc func selectHandTool(_ sender: Any?) { canvasHost.performDockAction(.selectPan) }
    @objc func toggleCommentMode(_ sender: Any?) { canvasHost.performDockAction(.toggleAnnotation) }
    @objc func toggleFramesSidebar(_ sender: Any?) { splitViewController.toggleSidebar(sender) }
    @objc func toggleCommentsPanel(_ sender: Any?) { splitViewController.toggleInspector(sender) }
    @objc func showFlowMode(_ sender: Any?) { showFlow() }
    /// Shrinks the images already in this project to ImageOptimizer's size.
    /// Computes first, shows the saving, and applies only after confirmation.
    @objc func reduceImageSizes(_ sender: Any?) {
        guard let document = boundDocument, let window else { return }
        let byUse = document.workspace.imageDataURLsByUse
        let commentURLs = Set(byUse.comments)
        let originals = Array(Set(byUse.frames).union(commentURLs))
        guard !originals.isEmpty else {
            let alert = NSAlert(); alert.messageText = "No Images to Reduce"
            alert.informativeText = "This project has no screenshots or image frames."
            alert.beginSheetModal(for: window); return
        }
        ToastView.show(message: "Checking image sizes…", in: canvasHost, duration: 3)
        Task { [weak self] in
            let replacements = await Task.detached(priority: .userInitiated) { () -> [String: String] in
                var result: [String: String] = [:]
                for url in originals {
                    let optimized = ImageOptimizer.optimize(dataURL: url, use: commentURLs.contains(url) ? .commentScreenshot : .frame)
                    if optimized.utf8.count < url.utf8.count { result[url] = optimized }
                }
                return result
            }.value
            guard let self, let window = self.window else { return }
            let before = replacements.keys.reduce(0) { $0 + $1.utf8.count * 3 / 4 }
            let after = replacements.values.reduce(0) { $0 + $1.utf8.count * 3 / 4 }
            let alert = NSAlert()
            guard !replacements.isEmpty else {
                alert.messageText = "Images Are Already Compact"
                alert.informativeText = "All \(originals.count) images are already within \(ImageOptimizer.maxLongEdge) px; nothing to reduce."
                alert.beginSheetModal(for: window, completionHandler: nil); return
            }
            let formatter = ByteCountFormatter()
            alert.messageText = "Reduce \(replacements.count) of \(originals.count) Images?"
            alert.informativeText = "Images larger than \(ImageOptimizer.maxLongEdge) px are scaled down and re-compressed: "
                + formatter.string(fromByteCount: Int64(before)) + " → " + formatter.string(fromByteCount: Int64(after))
                + ". That is still more detail than coding agents read. Frames keep their size on the canvas. You can undo this until you close the project."
            alert.addButton(withTitle: "Reduce")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn, let document = self?.boundDocument else { return }
                document.workspace.replaceImages(replacements)
            }
        }
    }

    @objc func restackFrames(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, FrameStacking.allCases.indices.contains(item.tag) else { return }
        canvasHost.restackSelection(FrameStacking.allCases[item.tag])
    }
    @objc func arrangeFrames(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, FrameArrangement.allCases.indices.contains(item.tag) else { return }
        canvasHost.arrangeSelection(FrameArrangement.allCases[item.tag])
    }
    @objc func showLibraryMode(_ sender: Any?) { showComponentCatalogue() }
    @objc func openSampleProject(_ sender: Any?) {
        canvasHost.dismissAddFrameModal()
        showFlow()
        astraReviewWindow?.openSampleProject()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleFramesSidebar(_:)):
            menuItem.title = splitViewController.isSidebarCollapsed ? "Show Sidebar" : "Hide Sidebar"
            return true
        case #selector(toggleCommentsPanel(_:)):
            menuItem.title = splitViewController.isCommentsCollapsed ? "Show Comments" : "Hide Comments"
            return true
        case #selector(showFlowMode(_:)):
            menuItem.state = componentCatalogue?.isPresented == true ? .off : .on
            return window?.attachedSheet == nil
        case #selector(showLibraryMode(_:)):
            menuItem.state = componentCatalogue?.isPresented == true ? .on : .off
            return window?.attachedSheet == nil
        case #selector(toggleCommentMode(_:)):
            menuItem.state = canvasHost.annotationMode ? .on : .off
            return canvasActionsEnabled
        case #selector(selectHandTool(_:)):
            menuItem.state = canvasHost.panLocked && !canvasHost.annotationMode ? .on : .off
            return canvasActionsEnabled
        case #selector(selectCursorTool(_:)):
            menuItem.state = !canvasHost.panLocked && !canvasHost.annotationMode ? .on : .off
            return canvasActionsEnabled
        case #selector(restackFrames(_:)):
            guard FrameStacking.allCases.indices.contains(menuItem.tag) else { return false }
            return canvasActionsEnabled && canvasHost.canRestack(FrameStacking.allCases[menuItem.tag])
        case #selector(arrangeFrames(_:)):
            guard FrameArrangement.allCases.indices.contains(menuItem.tag) else { return false }
            return canvasActionsEnabled && canvasHost.canArrange(FrameArrangement.allCases[menuItem.tag])
        case #selector(openSampleProject(_:)):
            return window?.attachedSheet == nil
        case #selector(newFrame(_:)), #selector(zoomInCanvas(_:)), #selector(zoomOutCanvas(_:)),
             #selector(zoomCanvasToFit(_:)), #selector(zoomCanvasToSelection(_:)):
            return canvasActionsEnabled
        default:
            return true
        }
    }

    /// Mirrors the guards of the canvas key monitor so a single-key menu
    /// equivalent never steals a keystroke from a text field or web page.
    private var canvasActionsEnabled: Bool {
        window?.attachedSheet == nil && !canvasHost.isModalPresented
            && componentCatalogue?.isPresented != true && !keyboardFocusIsEditor
    }
}

extension DocumentWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .reloadAllFrames, .sidebarTrackingSeparator, .flexibleSpace, NSToolbarItem.Identifier("workspaceMode"), .flexibleSpace, .inspectorTrackingSeparator, NSToolbarItem.Identifier("commentsPanel"), NSToolbarItem.Identifier("appSettings")]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .reloadAllFrames, .sidebarTrackingSeparator, .flexibleSpace, NSToolbarItem.Identifier("workspaceMode"), .flexibleSpace, .inspectorTrackingSeparator, NSToolbarItem.Identifier("commentsPanel"), NSToolbarItem.Identifier("appSettings")]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if itemIdentifier.rawValue == "appSettings" {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Settings"; item.toolTip = "Application settings (⌘,)"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Application settings")
            item.target = MenuActions.shared; item.action = #selector(MenuActions.openSettings(_:))
            return item
        }
        if itemIdentifier.rawValue == "commentsPanel" {
            // Replaces AppKit's generic inspector icon: this panel is the
            // comment list, so it gets the conversation symbol.
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Comments"; item.toolTip = "Show or hide comments (⌃⌘I)"
            item.image = NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: "Comments")
            item.target = self; item.action = #selector(toggleCommentsPanel(_:))
            return item
        }
        if itemIdentifier.rawValue == "workspaceMode" {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Workspace view"; item.view = workspaceModes
            return item
        }
        if itemIdentifier == .reloadAllFrames {
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Reload"
            item.paletteLabel = "Reload all frames"
            item.toolTip = "Reload all web frames"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Reload all web frames")
            item.target = self
            item.action = #selector(reloadAllFrames(_:))
            return item
        }
        // All three identifiers we ship are AppKit-provided — return nil
        // and AppKit vends the correct item. If we ever add a custom
        // toolbar item, branch on `itemIdentifier` here and construct it.
        return nil
    }

    @objc private func reloadAllFrames(_ sender: Any?) {
        canvasHost.performDockAction(.refreshAll)
    }
}
