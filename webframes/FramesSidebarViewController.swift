import AppKit

/// Hosts the `FramesSidebar` inside an `NSSplitViewItem(sidebar:)` so the
/// document window gets the stock Apple-HIG sidebar: collapsible from the
/// toolbar's `.toggleSidebar` item, tracked by `.sidebarTrackingSeparator`
/// so the title-band divider aligns with the split divider, full visual
/// effect material behind the rows (provided by AppKit's sidebar chrome).
///
/// Phase 6e sidebar-refactor Steps 1 + 2
/// ------------------------------------
/// Before the refactor, `FramesSidebar` was a floating child of
/// `CanvasHost`: its own `NSGlassEffectView`, its own slide-from-left
/// animation, its own alpha-driven show/hide path. Step 1 moved
/// visibility ownership to `NSSplitViewItem.isCollapsed` (driven by the
/// toolbar button, ⌘⌥S, or a programmatic call through the responder
/// chain). Step 2 (2026-04-21) stripped the custom glass, the header
/// chrome ("Frames" title + divider), and the `setVisible(_:animated:)`
/// slide shim — there is now one material (the split item's `.sidebar`
/// `NSVisualEffectView`) and one visibility source of truth.
///
/// Data flow: this VC owns its own `WorkspaceStore` observer and pushes
/// `setFrames(_:)` on every mutation. Selection is pushed separately by
/// `CanvasHost` through a weak back-reference, because selection lives
/// outside the workspace store (see `CanvasHost.selectedFrameId`).
@MainActor
final class FramesSidebarViewController: NSViewController {

    /// The actual sidebar view. Exposed so `DocumentSplitViewController`
    /// can wire it as the `FramesSidebarDelegate` target and `CanvasHost`
    /// can push selection updates.
    let sidebar: FramesSidebar

    private weak var document: WebFramesDocument?
    private var workspaceSubscription: WorkspaceStore.Subscription?

    init(document: WebFramesDocument) {
        self.document = document
        self.sidebar = FramesSidebar(frame: .zero)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Use `FramesSidebar` itself as the VC's view. The split view's
    /// sidebar item wraps this in its own `NSVisualEffectView`-backed
    /// chrome automatically.
    ///
    /// Post-Step 2: `FramesSidebar.init` no longer stamps `alphaValue = 0`
    /// / `isHidden = true` / a CATransform3D slide, so no "force visible"
    /// shim is needed here. Visibility lives entirely on the split item's
    /// `isCollapsed` flag.
    override func loadView() {
        view = sidebar
    }

    /// Called by `DocumentSplitViewController` once both child VCs exist
    /// so the sidebar's `didSelectFrameID:` callback reaches the host's
    /// `selectFrame(_:)` + viewport-pan path.
    func attachDelegate(_ delegate: FramesSidebarDelegate) {
        sidebar.delegate = delegate
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installWorkspaceObserver()
    }

    // MARK: - Workspace observer
    //
    // Mirrors the push that used to live inside
    // `CanvasHost.refreshNativeViewsFromWorkspace`. `observe(_:)` fires
    // once synchronously on registration, so the initial frame list paints
    // on first open without waiting for a mutation tick. `[weak self]` to
    // avoid a retain cycle: the document outlives the VC, so capturing
    // strongly would keep the VC around after the window closes.
    private func installWorkspaceObserver() {
        guard let document else { return }
        workspaceSubscription = document.workspace.observe { [weak self] in
            guard let self, let doc = self.document else { return }
            self.sidebar.setFrames(doc.workspace.frames, projectMap: doc.workspace.projectMap)
        }
    }
}
