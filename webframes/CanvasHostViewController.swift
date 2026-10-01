import AppKit

/// Thin `NSViewController` wrapper around `CanvasHost` so it can be the
/// main item of the document window's `NSSplitViewController`.
///
/// Phase 6e sidebar-refactor Step 1
/// --------------------------------
/// Before this refactor, `DocumentWindowController` set
/// `window.contentView = canvasHost` and the sidebar was a floating child
/// view of `CanvasHost` with its own slide-in animation. To migrate to the
/// Apple HIG sidebar pattern (Mail / Finder — traffic-lights sit over the
/// sidebar, toolbar owns a `.toggleSidebar` button, split view owns the
/// divider), the window's contentViewController is now a
/// `DocumentSplitViewController`. That split view hosts two items:
///
///   * Sidebar: `FramesSidebarViewController` (this file's sibling)
///   * Main:    `CanvasHostViewController` (this file)
///
/// This VC is intentionally empty beyond `loadView`. The actual work still
/// lives in `CanvasHost` itself — delegate plumbing, workspace observer,
/// mouse/keyboard monitors, frame lifecycle. Keeping the VC a thin shell
/// means the split-view migration landed additively: `CanvasHost` didn't
/// need to change class shape, and `DocumentWindowController` can still
/// reach into the host via `splitVC.canvasVC.canvasHost` for the existing
/// event-monitor hooks.
@MainActor
final class CanvasHostViewController: NSViewController {

    /// The root content view for this VC. Published as `let` so the
    /// window controller and split VC can both grab it during setup
    /// (event monitors, delegate wiring).
    let canvasHost: CanvasHost

    init(document: WebFramesDocument) {
        self.canvasHost = CanvasHost(document: document)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Set the VC's view to the `CanvasHost` itself, not a wrapper. The
    /// split view's main pane becomes `canvasHost` directly — no extra
    /// Auto Layout nesting between the split view and the backdrop /
    /// frame-layer / dock / annotation-panel. Matches how a plain
    /// `window.contentView = canvasHost` would have sized it.
    override func loadView() {
        view = canvasHost
    }
}
