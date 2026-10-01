import AppKit

/// The document window's root content view controller — an
/// `NSSplitViewController` hosting the frames sidebar on the leading edge
/// and the canvas host on the trailing side.
///
/// Phase 6e sidebar-refactor Step 1
/// --------------------------------
/// Replaces the previous arrangement where `DocumentWindowController` set
/// `window.contentView = canvasHost` and `CanvasHost` owned the sidebar
/// as a floating child view. Going through a real split view controller
/// unlocks Apple's HIG sidebar affordances: the window's `.unified`
/// toolbar can include `.toggleSidebar` + `.sidebarTrackingSeparator`,
/// system-generated ⌘⌥S toggles the sidebar through the responder chain,
/// and traffic-lights visually sit over the sidebar (like Mail / Finder /
/// Notes) because the sidebar extends up under the title band thanks to
/// `window.styleMask.fullSizeContentView` + `toolbarStyle = .unified`.
///
/// Users open and close the sidebar via the toolbar button or ⌘⌥S.
/// (The dock-side sidebar toggle existed briefly as a third entry point
/// but was removed on 2026-04-21 — the old KVO observation on
/// `sidebarItem.isCollapsed` that mirrored the split-item state onto the
/// dock button went with it.)
@MainActor
final class DocumentSplitViewController: NSSplitViewController {

    let sidebarVC: FramesSidebarViewController
    let canvasVC:  CanvasHostViewController

    private let sidebarItem: NSSplitViewItem
    private let mainItem:    NSSplitViewItem
    private var commentsItem: NSSplitViewItem!
    private var commentsObservation: NSKeyValueObservation?

    init(document: WebFramesDocument) {
        self.sidebarVC = FramesSidebarViewController(document: document)
        self.canvasVC  = CanvasHostViewController(document: document)

        // Sidebar item: AppKit's dedicated sidebar behavior. Enables the
        // native visual-effect material, responds to `.toggleSidebar`
        // actions through the responder chain, and allows the toolbar's
        // `.sidebarTrackingSeparator` to find its divider line.
        self.sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.canCollapse = true
        // Let the user collapse the sidebar by dragging the window
        // narrow enough — matches Mail/Finder behavior where a narrow
        // window auto-hides the sidebar so content doesn't squeeze.
        sidebarItem.canCollapseFromWindowResize = true
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 320
        // Start uncollapsed: sidebar-refactor Step 3 moved the editable
        // project-name `titleField` into the sidebar's `titleSlot`, so
        // the sidebar is now the primary source-label surface
        // (Finder / Mail / Notes pattern). Starting collapsed would
        // hide the document's own name at first open, which confused
        // Egor during post-Step 3 testing — flipped to `false` on
        // 2026-04-21. The initial `.isCollapsed = true` (Step 1,
        // earlier on 2026-04-21) was chosen back when the sidebar only
        // listed frames and the title still lived in the canvas-host
        // titlebar strip; that rationale no longer applies.
        //
        // `canCollapseFromWindowResize` still lets narrow windows
        // auto-hide the sidebar the Mail/Finder way.
        sidebarItem.isCollapsed = false

        self.mainItem = NSSplitViewItem(viewController: canvasVC)

        super.init(nibName: nil, bundle: nil)
        addSplitViewItem(sidebarItem)
        addSplitViewItem(mainItem)
        let commentsVC = NSViewController()
        commentsVC.view = canvasVC.canvasHost.annotationPanel
        commentsItem = NSSplitViewItem(inspectorWithViewController: commentsVC)
        commentsItem.maximumThickness = 400; commentsItem.minimumThickness = 280
        commentsItem.canCollapse = true; commentsItem.isCollapsed = true
        commentsItem.allowsFullHeightLayout = false
        addSplitViewItem(commentsItem)
        canvasVC.canvasHost.annotationPanel.setVisible(true, animated: false)
        canvasVC.canvasHost.onToggleComments = { [weak self] in self?.toggleInspector(nil) }
        canvasVC.canvasHost.onCloseComments = { [weak self] in self?.commentsItem.animator().isCollapsed = true }
        commentsObservation = commentsItem.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] item, _ in
            MainActor.assumeIsolated { self?.canvasVC.canvasHost.setCommentsInspectorOpen(!item.isCollapsed) }
        }

        // Wire the sidebar's row-click delegate back to the host NOW
        // (not in `viewDidLoad`) so the first frame-row click fires
        // correctly even if the user opens the sidebar before the
        // window finishes animating in.
        sidebarVC.attachDelegate(canvasVC.canvasHost)
        canvasVC.canvasHost.sidebar = sidebarVC.sidebar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Hit testing
    //
    // `DocumentWindowController`'s event monitors (scroll gate, pan
    // drag, annotation click) used to ask `CanvasHost.isFramesSidebarRegion`
    // whether a window point was inside the sidebar band so the canvas
    // didn't pan/zoom under the user's pointer on a sidebar row. Now
    // that the sidebar lives in a separate split pane, ownership of
    // that query moves here — the split VC knows both the sidebar's
    // view AND whether it's currently collapsed.

    /// True when `windowPoint` lives inside the sidebar pane AND the
    /// sidebar is currently uncollapsed. Returns false when collapsed so
    /// a pointer over the now-empty leading strip still pans the canvas.
    var isSidebarCollapsed: Bool { sidebarItem.isCollapsed }
    var isCommentsCollapsed: Bool { commentsItem.isCollapsed }

    func isHitInSidePanel(_ windowPoint: NSPoint) -> Bool {
        if !commentsItem.isCollapsed {
            let panel = commentsItem.viewController.view
            if panel.bounds.contains(panel.convert(windowPoint, from: nil)) { return true }
        }
        return isHitInSidebar(windowPoint)
    }
    func isHitInSidebar(_ windowPoint: NSPoint) -> Bool {
        guard !sidebarItem.isCollapsed else { return false }
        let sidebarView = sidebarVC.view
        let local = sidebarView.convert(windowPoint, from: nil)
        return sidebarView.bounds.contains(local)
    }

    // Programmatic toggle: callers should use
    //     NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)),
    //                      to: nil, from: self)
    // so the responder chain lands on this controller's inherited
    // `toggleSidebar(_:)` (same path the toolbar's `.toggleSidebar` item
    // takes). We intentionally don't wrap that path in a custom method —
    // two entry points for the same behaviour would make it easy to
    // accidentally bypass HIG-standard animation / state handling.
}
