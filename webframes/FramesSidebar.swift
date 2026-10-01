import AppKit

// MARK: - Delegate

protocol FramesSidebarDelegate: AnyObject {
    /// Fired when the user clicks a frame row. The host is expected to select
    /// the frame (`canvasHost.selectFrame`) AND pan the viewport so the
    /// frame's center lands at the visible canvas center — matches the
    /// "click on minimap" UX users expect from IDE/file-tree sidebars.
    func framesSidebar(_ sidebar: FramesSidebar, didReorderFrameIDs ids: [String])
    func framesSidebar(_ sidebar: FramesSidebar, didSelectFrameID id: String)
    func framesSidebar(_ sidebar: FramesSidebar, didRequest action: FramesSidebar.SourceAction, forSourceID sourceID: String)
}

// MARK: - Sidebar

/// Native left-side project navigator — lists every frame in the current
/// workspace as a row (label + type badge).
///
/// Phase 6e sidebar-refactor Step 2 (2026-04-21)
/// --------------------------------------------
/// Visibility is owned by `NSSplitViewItem(sidebarWithViewController:)` —
/// the split item handles `isCollapsed`, tracks the toolbar's
/// `.sidebarTrackingSeparator`, and dispatches the responder-chain
/// `.toggleSidebar` action. Pre-Step 2 this view carried its own
/// `NSGlassEffectView`, a `.large` corner radius, and a slide-from-left
/// `setVisible(_:animated:)` shim — all stripped so visibility has one
/// source of truth (`isCollapsed`) and there's no custom rounded chrome
/// fighting the split item's flat pane geometry.
///
/// Step 2 fix-up (2026-04-21 evening): `NSSplitViewItem(.sidebar)`
/// provides sidebar BEHAVIOR but does NOT automatically draw the `.sidebar`
/// visual-effect material — the VC's view is responsible for that. The
/// initial Step 2 cut made `FramesSidebar` a plain `NSView` on the
/// assumption that the split item supplied the material; it did not, and
/// the raw window/split-pane background bled through as a flat grey slab
/// that read as "another sidebar beneath the sidebar" (Egor: "под sidebar
/// как будто есть еще один сайдбар с серым фоном"). Correct pattern is
/// to make the sidebar view itself an `NSVisualEffectView` with the
/// system `.sidebar` material + `.behindWindow` blending — matches
/// Mail / Finder / Notes exactly.
///
/// The sidebar is a passive view: it owns no workspace state. Rows emit a
/// `didSelectFrameID:` callback through the delegate; `CanvasHost` maps that
/// to `selectFrame(_:)` + a viewport pan. Workspace observer (owned by
/// `FramesSidebarViewController`) pushes the frame list here via
/// `setFrames(_:)` on every mutation.
final class FramesSidebar: NSVisualEffectView {

    enum SourceStatus: Equatable {
        case checking
        case starting
        case online
        case managedOnline
        case offline
    }

    enum SourceAction {
        case retry
        case startServer
        case stopServer
        case restartServer
        case reloadFrames
        case changeAddress
        case openInBrowser
    }

    private struct SourceEntry: Equatable {
        let source: ProjectWebSource
        let frameIDs: Set<String>
    }

    // MARK: - Row model
    //
    // The model is trivially derivable from a `FrameModel` via `from(frame:)`
    // — we keep a separate struct so the row view doesn't depend on the
    // wider FrameModel surface (extras, JSONValue, etc.).

    struct Entry: Equatable {
        let id: String
        let label: String
        let kind: Kind

        enum Kind: String {
            case web    = "Web"
            case github = "GitHub"
            case image  = "Image"

            /// Badge chrome color. Chosen from the app's accent family + two
            /// system semantics (blue / purple) that read distinct from the
            /// accent orange without clashing with the Liquid Glass backdrop.
            /// Web uses a neutral gray so the dominant category doesn't
            /// paint the sidebar in one color — the badges exist to surface
            /// the *exceptions* (folder / github / image).
            var color: NSColor {
                switch self {
                case .web:    return NSColor(white: 0.55, alpha: 1)
                case .github: return NSColor(white: 0.82, alpha: 1)
                case .image:  return .systemPurple
                }
            }
        }

        /// Discrimination matches the url-prefix convention used by
        /// `WebFramesDocument` / JS addFrame paths. `FrameModel` itself has
        /// only the `isImage` flag typed — everything else is inferred from
        /// the `url` string (see `WorkspaceModels.swift` FrameModel docs).
        ///
        ///   * `isImage == true`           → Image
        ///   * `url` `wf-github://…`       → GitHub (GitHub repo browser)
        ///   * else                        → Web
        static func from(frame: FrameModel) -> Entry {
            let kind: Kind
            if frame.isImage {
                kind = .image
            } else if frame.url.hasPrefix(GitHubFrameSource.scheme + "://") {
                kind = .github
            } else {
                kind = .web
            }
            return Entry(id: frame.id, label: frame.label, kind: kind)
        }
    }

    weak var delegate: FramesSidebarDelegate?

    // MARK: - Views

    /// Transparent 44pt spacer at the top — reserves the titlebar /
    /// traffic-light band so the first row doesn't paint under the
    /// traffic lights. The sidebar extends up under the title band
    /// because the window uses `fullSizeContentView` + `toolbarStyle =
    /// .unified`. Before Step 1 this block carried a "Frames" title label
    /// + item count + divider — all stripped 2026-04-21 after Egor
    /// screenshotted the title text being clipped by the traffic lights.
    /// `NSSplitViewItem(.sidebar)` + `NSToolbar` provide the title band
    /// and the tracked divider; a second "Frames" header here would be
    /// redundant.
    private let header  = NSView()

    /// 36pt strip below the traffic-light spacer that hosts the document's
    /// editable project-name text field. The field itself is owned by
    /// `DocumentWindowController` (so the existing text-binding /
    /// delegate wiring stays put) and injected via `installTitleView(_:)`.
    /// Empty when the host hasn't injected anything yet; subview lifecycle
    /// belongs to the caller. Added 2026-04-21 per Egor's request to
    /// relocate the project title from the canvas titlebar strip to
    /// "в сайд бар под кнопки".
    private let titleSlot = NSView()

    private let scroll  = NSScrollView()
    private let stack   = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No frames yet")

    // MARK: - State

    private var entries: [Entry] = []
    private var sourceEntry: SourceEntry?
    private var sourceStatus: SourceStatus = .checking
    private var sourceExpanded = true
    private var selectedId: String?
    private var dropIndex: Int?
    private let dropLine = NSView()
    static let reorderType = NSPasteboard.PasteboardType("app.webframes.frame-order")

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        // HIG sidebar material. NSSplitViewItem(.sidebar) supplies
        // behavior-only (collapse/responder-chain/tracking-separator); the
        // actual `.sidebar` visual-effect material must live on the VC's
        // view or the pane renders as a flat grey slab. `.behindWindow`
        // blending samples the desktop behind the window so the sidebar
        // picks up the user's wallpaper tint like Mail / Finder / Notes.
        // `.followsWindowActiveState` dims the material when the document
        // window loses key status, matching HIG.
        material = .sidebar
        // `.withinWindow` (not `.behindWindow`) on 2026-04-21 evening
        // after Egor flagged that the sidebar's bottom looked grey
        // while the top was green. Root cause: `.behindWindow` samples
        // the desktop wallpaper THROUGH the window, and his wallpaper
        // has a green-to-dark gradient — so the bottom of the sidebar
        // legitimately picked up the darker wallpaper region and read
        // as grey. Mail / Finder accept that trade-off for wallpaper
        // vibrancy; this app is dark-first (WFDesign.bg) and a uniform
        // sidebar reads cleaner than a variable-tint one. `.withinWindow`
        // keeps the NSVisualEffectView chrome but samples only content
        // inside the window behind the sidebar pane (the NSSplitView
        // backdrop), so the render is flat and doesn't depend on
        // wallpaper colors.
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        // No `alphaValue = 0`, no `isHidden = true`. Step 2 handed
        // visibility over to `NSSplitViewItem`'s `isCollapsed`, and the
        // transform-based slide-in animation is gone; the view is fully
        // visible whenever the split item uncollapses, period.
        // `NSVisualEffectView` already has a backing layer, so rows that
        // want rounded fills (`FramesSidebarRow`) continue to opt-in via
        // their own `wantsLayer = true`.
        buildHeader()
        buildBody()
        registerForDraggedTypes([Self.reorderType])
        dropLine.wantsLayer = true; dropLine.layer?.backgroundColor = WFDesign.accent.cgColor
        dropLine.isHidden = true; addSubview(dropLine)
        setAccessibilityIdentifier("webframes.framesSidebar")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build

    private func buildHeader() {
        // Transparent spacer only — see `header` ivar doc for the
        // "why no visible chrome anymore" story. Pinned directly to
        // `self` now that the intermediate `NSGlassEffectView` +
        // `content` contentView are gone (Step 2).
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        // Title slot sits immediately below the traffic-light spacer.
        // Intentionally empty at build time — `installTitleView(_:)` fills
        // it from the host. Keeping the slot in the layout (even empty)
        // means the scroll's top edge stays in the same place whether or
        // not the title has been injected yet, avoiding a re-layout shift
        // on first doc open.
        titleSlot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleSlot)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            titleSlot.topAnchor.constraint(equalTo: header.bottomAnchor),
            titleSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleSlot.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func buildBody() {
        // Same scroll setup as AnnotationPanel.buildBody — NSClipView's
        // default (non-flipped) coord system puts origin at bottom-left,
        // which makes the scroll bounce behavior and the "show first row
        // at the top" expectation fight each other. FlippedClipView
        // (defined at AnnotationPanel.swift:689) flips that so the stack
        // grows downward from the clip view's top edge, which is what the
        // user expects.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller?.controlSize = .small
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        addSubview(scroll)

        let flipped = FlippedClipView()
        flipped.drawsBackground = false
        scroll.contentView = flipped

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        // Empty state — positioned over the scroll area, hidden when the
        // list has any rows. Keeps the sidebar from looking "broken" when
        // a user opens a fresh project.
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = WFDesign.text3
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: titleSlot.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: flipped.widthAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    // MARK: - Title injection

    /// Hosts the caller-owned project-title text field inside
    /// `titleSlot`. `DocumentWindowController` invokes this during window
    /// setup with its own `titleField`, keeping edit plumbing (delegate,
    /// `controlTextDidEndEditing`, document name sync) in one place.
    /// Replacing on every call is defensive: if the caller ever re-wires
    /// after a sidebar teardown, the slot doesn't stack old views.
    func installTitleView(_ view: NSView) {
        titleSlot.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        titleSlot.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: titleSlot.leadingAnchor, constant: 12),
            view.trailingAnchor.constraint(equalTo: titleSlot.trailingAnchor, constant: -12),
            view.centerYAnchor.constraint(equalTo: titleSlot.centerYAnchor),
        ])
    }

    // MARK: - Data in

    /// Push the latest frames from `CanvasHost`'s workspace observer.
    /// Cheap path when the list is unchanged: re-uses `Entry` equality to
    /// skip the `removeArrangedSubview` churn. Without this guard, every
    /// workspace mutation (e.g. a drag-move, which fires `refreshNative`
    /// but doesn't change the frames array) would thrash the stack and
    /// flicker hover/highlight state on mouse-over'd rows.
    @MainActor func setFrames(_ frames: [FrameModel], projectMap: ProjectMapSnapshot?) {
        let newEntries = frames.map(Entry.from(frame:))
        let newSource: SourceEntry? = projectMap.map { map in
            let source = map.effectiveWebSource
            var ids = Set(map.routes.compactMap(\.frameID))
            for frame in frames {
                if case .string(let sourceID) = frame.extras["webSourceID"], sourceID == source.id { ids.insert(frame.id) }
            }
            return SourceEntry(source: source, frameIDs: ids)
        }
        guard newEntries != entries || newSource != sourceEntry else { return }
        entries = newEntries
        sourceEntry = newSource
        emptyLabel.isHidden = !entries.isEmpty || newSource != nil
        renderRows()
    }

    func setSourceStatus(_ status: SourceStatus, sourceID: String) {
        guard sourceEntry?.source.id == sourceID, sourceStatus != status else { return }
        sourceStatus = status
        for case let row as FramesSidebarSourceRow in stack.arrangedSubviews {
            row.setStatus(status)
        }
    }

    /// Reflects the host's `selectedFrameId` into the sidebar's row
    /// highlight. No-op if the selection didn't actually change —
    /// avoids the per-row redraw loop below on observer ticks that
    /// didn't touch selection.
    func setSelectedFrameID(_ id: String?) {
        guard selectedId != id else { return }
        selectedId = id
        for case let row as FramesSidebarRow in stack.arrangedSubviews {
            row.setHighlighted(row.entry.id == id)
        }
    }

    // MARK: - Visibility
    //
    // Visibility lives on `NSSplitViewItem.isCollapsed` now — toggled via
    // `DocumentSplitViewController`'s inherited `toggleSidebar(_:)` (from
    // the toolbar button, the dock button via `NSApp.sendAction`, or the
    // system ⌘⌥S keystroke). The custom `setVisible(_:animated:)` shim
    // with its slide-from-left CATransform3D + alpha fade was deleted in
    // Step 2 — `NSSplitViewController` animates the collapse itself, and
    // owning a second visibility source would race with `isCollapsed`.

    // MARK: - Row rendering

    private func renderRows() {
        // Drop old rows cleanly — NSStackView owns arranged subviews,
        // removeArrangedSubview + removeFromSuperview is the documented
        // "remove for good" pattern.
        stack.arrangedSubviews.forEach { v in
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        var didInsertSource = false
        for entry in entries {
            if let sourceEntry, sourceEntry.frameIDs.contains(entry.id), !didInsertSource {
                addSourceRow(sourceEntry)
                didInsertSource = true
            }
            if let sourceEntry, sourceEntry.frameIDs.contains(entry.id), !sourceExpanded { continue }
            let row = FramesSidebarRow(entry: entry)
            row.isSourceChild = sourceEntry?.frameIDs.contains(entry.id) == true
            row.setHighlighted(entry.id == selectedId)
            row.reorderOwner = self
            row.onClick = { [weak self] id in
                guard let self else { return }
                self.delegate?.framesSidebar(self, didSelectFrameID: id)
            }
            stack.addArrangedSubview(row)
            // Each row fills the full stack width so labels can truncate
            // middle-elided when the frame title is long — without this,
            // NSStackView's `.leading` alignment would let each row size
            // to its intrinsic content (which for a long title is "as
            // wide as the text", exceeding the stack and overflowing the
            // scroll view's horizontal axis).
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        if let sourceEntry, !didInsertSource { addSourceRow(sourceEntry) }
    }

    private func addSourceRow(_ entry: SourceEntry) {
        let row = FramesSidebarSourceRow(source: entry.source, status: sourceStatus, expanded: sourceExpanded)
        row.onToggle = { [weak self] in
            guard let self else { return }
            self.sourceExpanded.toggle()
            self.renderRows()
        }
        row.onAction = { [weak self] action in
            guard let self else { return }
            self.delegate?.framesSidebar(self, didRequest: action, forSourceID: entry.source.id)
        }
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    private func proposedDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let row = info.draggingSource as? FramesSidebarRow, row.reorderOwner === self,
              let id = info.draggingPasteboard.string(forType: Self.reorderType), entries.contains(where: { $0.id == id }) else {
            dropLine.isHidden = true; dropIndex = nil; return []
        }
        let point = convert(info.draggingLocation, from: nil)
        let views = stack.arrangedSubviews.compactMap { $0 as? FramesSidebarRow }
        var index = views.count
        for (i, view) in views.enumerated() where point.y > view.convert(view.bounds, to: self).midY { index = i; break }
        dropIndex = index
        let y: CGFloat
        if index < views.count { y = views[index].convert(views[index].bounds, to: self).maxY }
        else { y = views.last.map { $0.convert($0.bounds, to: self).minY } ?? point.y }
        dropLine.frame = NSRect(x: 8, y: y - 1, width: max(0, bounds.width - 16), height: 2)
        dropLine.isHidden = false
        if let event = NSApp.currentEvent { _ = scroll.autoscroll(with: event) }
        return .move
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { proposedDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { proposedDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropLine.isHidden = true; dropIndex = nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard proposedDrop(sender) == .move, let index = dropIndex,
              let id = sender.draggingPasteboard.string(forType: Self.reorderType),
              let from = entries.firstIndex(where: { $0.id == id }) else { return false }
        let visibleIDs = stack.arrangedSubviews.compactMap { ($0 as? FramesSidebarRow)?.entry.id }
        let beforeID = index < visibleIDs.count ? visibleIDs[index] : nil
        var order = entries.map(\.id); order.remove(at: from)
        let destination = beforeID.flatMap { order.firstIndex(of: $0) } ?? order.count
        order.insert(id, at: destination)
        dropLine.isHidden = true; dropIndex = nil
        delegate?.framesSidebar(self, didReorderFrameIDs: order)
        return true
    }

}

// MARK: - Web source row

/// A persistent server group. It keeps server health and recovery controls
/// next to the frames that depend on that server instead of hiding them in
/// the import sheet.
final class FramesSidebarSourceRow: NSView {
    var onToggle: (() -> Void)?
    var onAction: ((FramesSidebar.SourceAction) -> Void)?

    private let source: ProjectWebSource
    private let icon = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let addressField = NSTextField(labelWithString: "")
    private let menuButton = NSButton()
    private var status: FramesSidebar.SourceStatus
    private var tracking: NSTrackingArea?

    init(source: ProjectWebSource, status: FramesSidebar.SourceStatus, expanded: Bool) {
        self.source = source
        self.status = status
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = WFDesign.Radius.small

        icon.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Web server")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        icon.translatesAutoresizingMaskIntoConstraints = false

        nameField.stringValue = source.name.isEmpty ? "Web project" : source.name
        nameField.font = .systemFont(ofSize: 12, weight: .semibold)
        nameField.textColor = WFDesign.text
        nameField.lineBreakMode = .byTruncatingTail
        nameField.translatesAutoresizingMaskIntoConstraints = false

        addressField.stringValue = source.address
        addressField.font = .systemFont(ofSize: 10)
        addressField.textColor = WFDesign.text3
        addressField.lineBreakMode = .byTruncatingMiddle
        addressField.translatesAutoresizingMaskIntoConstraints = false

        menuButton.bezelStyle = .inline
        menuButton.isBordered = false
        menuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Server actions")
        menuButton.imagePosition = .imageOnly
        menuButton.target = self; menuButton.action = #selector(showActions)
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.isHidden = true

        [icon, nameField, addressField, menuButton].forEach(addSubview)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), icon.centerYAnchor.constraint(equalTo: nameField.centerYAnchor), icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            nameField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), nameField.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            nameField.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -6),
            addressField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor), addressField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 1),
            addressField.trailingAnchor.constraint(lessThanOrEqualTo: menuButton.leadingAnchor, constant: -6),
            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12), menuButton.centerYAnchor.constraint(equalTo: nameField.centerYAnchor), menuButton.widthAnchor.constraint(equalToConstant: 24), menuButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        setStatus(status)
        setAccessibilityIdentifier("webframes.framesSidebar.source.\(source.id)")
        setAccessibilityLabel("\(nameField.stringValue), \(source.address)")
        setAccessibilityHelp(expanded ? "Click to collapse pages" : "Click to expand pages")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setStatus(_ status: FramesSidebar.SourceStatus) {
        self.status = status
        switch status {
        case .checking, .starting:
            icon.contentTintColor = .systemOrange
            icon.toolTip = status == .starting ? "Starting server…" : "Checking \(source.address)"
        case .online, .managedOnline:
            icon.contentTintColor = .systemGreen
            icon.toolTip = status == .managedOnline ? "Online · managed by Web Frames" : "Online"
        case .offline:
            icon.contentTintColor = .systemRed
            icon.toolTip = "No server is responding at \(source.address)"
        }
    }

    @objc private func showActions() {
        let menu = NSMenu()
        switch status {
        case .managedOnline:
            addItem("Restart Server", symbol: "arrow.clockwise", action: .restartServer, to: menu)
            addItem("Stop Server", symbol: "stop.fill", action: .stopServer, to: menu)
            menu.addItem(.separator())
            addItem("Reload All Frames", symbol: "arrow.clockwise", action: .reloadFrames, to: menu)
        case .starting:
            addItem("Stop Server", symbol: "stop.fill", action: .stopServer, to: menu)
        case .online:
            addItem("Reload All Frames", symbol: "arrow.clockwise", action: .reloadFrames, to: menu)
        case .checking, .offline:
            addItem("Start Server", symbol: "play.fill", action: .startServer, to: menu)
            addItem("Retry Connection", symbol: "arrow.clockwise", action: .retry, to: menu)
        }
        menu.addItem(.separator())
        addItem("Change Address…", symbol: "pencil", action: .changeAddress, to: menu)
        addItem("Open in Browser", symbol: "safari", action: .openInBrowser, to: menu)
        menu.popUp(positioning: nil, at: NSPoint(x: menuButton.bounds.maxX, y: menuButton.bounds.minY), in: menuButton)
    }
    private func addItem(_ title: String, symbol: String, action: FramesSidebar.SourceAction, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.representedObject = action
        menu.addItem(item)
    }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? FramesSidebar.SourceAction else { return }
        onAction?(action)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { menuButton.isHidden = false }
    override func mouseExited(with event: NSEvent) { menuButton.isHidden = true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === menuButton ? hit : self
    }
    override func mouseUp(with event: NSEvent) { onToggle?() }
    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Row

/// Single row in the sidebar list. Label on the left (middle-truncating
/// single line), type badge pinned right. Highlight modes: hover (faint
/// white wash), selected (accent-tinted wash, matches DockButton's `.standard,
/// true` active look).
final class FramesSidebarRow: NSView, NSDraggingSource {
    weak var reorderOwner: FramesSidebar?
    private var mouseStart: NSPoint?
    private var didDrag = false
    let entry: FramesSidebar.Entry
    var isSourceChild = false { didSet { iconLeading.constant = isSourceChild ? 28 : 10 } }
    /// Called on mouse-up inside the row. Passes the entry id so the caller
    /// doesn't have to retain a reference to `self`.
    var onClick: ((String) -> Void)?

    private let labelField = NSTextField(labelWithString: "")
    private let kindIcon = NSImageView()
    private var iconLeading: NSLayoutConstraint!
    private var hovering = false { didSet { needsDisplay = true } }
    private var highlighted = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    init(entry: FramesSidebar.Entry) {
        self.entry = entry
        super.init(frame: .zero)
        wantsLayer = true
        // Row radius mirrors DockButton.standard (22pt capsule is overkill
        // for a wide thin list row — `.small` 8pt reads as "rounded row"
        // without becoming a pill). Matches Finder / Music sidebar rows.
        layer?.cornerRadius = WFDesign.Radius.small
        layer?.masksToBounds = true

        // Fallback to "(untitled)" so a freshly-spawned frame with an
        // empty label still reads as a row rather than a blank slab.
        labelField.stringValue = entry.label.isEmpty ? "(untitled)" : entry.label
        labelField.font = .systemFont(ofSize: 12, weight: .regular)
        labelField.textColor = WFDesign.text
        labelField.lineBreakMode = .byTruncatingMiddle
        labelField.maximumNumberOfLines = 1
        labelField.cell?.truncatesLastVisibleLine = true
        labelField.isEditable = false
        labelField.isBordered = false
        labelField.drawsBackground = false
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let symbol: String
        switch entry.kind {
        case .web: symbol = "globe"
        case .image: symbol = "photo"
        case .github: symbol = "chevron.left.forwardslash.chevron.right"
        }
        kindIcon.image = NSImage(systemSymbolName:symbol,accessibilityDescription:entry.kind.rawValue)
        kindIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize:13,weight:.regular)
        kindIcon.contentTintColor = .secondaryLabelColor
        kindIcon.toolTip = entry.kind.rawValue
        kindIcon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(kindIcon);addSubview(labelField)
        translatesAutoresizingMaskIntoConstraints = false
        iconLeading = kindIcon.leadingAnchor.constraint(equalTo:leadingAnchor,constant:10)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant:28),
            iconLeading,
            kindIcon.centerYAnchor.constraint(equalTo:centerYAnchor),
            kindIcon.widthAnchor.constraint(equalToConstant:16),kindIcon.heightAnchor.constraint(equalToConstant:16),
            labelField.leadingAnchor.constraint(equalTo:kindIcon.trailingAnchor,constant:8),
            labelField.centerYAnchor.constraint(equalTo:centerYAnchor),
            labelField.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-10)
        ])
        setAccessibilityIdentifier("webframes.framesSidebar.row.\(entry.id)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setHighlighted(_ on: Bool) { highlighted = on }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(
            roundedRect: bounds,
            xRadius: WFDesign.Radius.small,
            yRadius: WFDesign.Radius.small
        )
        if highlighted {
            // Same wash as DockButton active state (accent @ 18%) for
            // visual consistency across the app's "this is selected" idiom.
            WFDesign.accent.withAlphaComponent(0.18).setFill()
            path.fill()
        } else if hovering {
            NSColor.white.withAlphaComponent(0.07).setFill()
            path.fill()
        }
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
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func mouseDown(with event: NSEvent) { mouseStart = event.locationInWindow; didDrag = false }
    override func mouseUp(with event: NSEvent) { if !didDrag { onClick?(entry.id) }; mouseStart = nil }
    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let start = mouseStart, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        didDrag = true
        let item = NSPasteboardItem(); item.setString(entry.id, forType: FramesSidebar.reorderType)
        let drag = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        image.lockFocus(); WFDesign.bg3.setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        (entry.label as NSString).draw(at: NSPoint(x: 14, y: 7), withAttributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: WFDesign.text]); image.unlockFocus()
        drag.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [drag], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { didDrag = false; mouseStart = nil }


    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

// MARK: - Type badge

/// Small colored pill showing a frame's kind (Web / Folder / GitHub / Image).
/// Chrome: rounded-rect, tinted background at 18% alpha of the kind color,
/// text in a brighter tint of the same color so the badge reads as a
/// chip rather than a neutral label.
final class TypeBadge: NSView {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 9, weight: .medium)
        label.textColor = WFDesign.text2
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setKind(_ kind: FramesSidebar.Entry.Kind) {
        label.stringValue = kind.rawValue
        let tint = kind.color
        layer?.backgroundColor = tint.withAlphaComponent(0.18).cgColor
        // Text: blend the kind color with white to lift it above the 18%
        // background wash for readability. `blended(withFraction:of:)`
        // returns nil if the color spaces don't match — fall back to
        // text2 in that case (which on our dark theme is #888, legible
        // against the dimmed tint).
        label.textColor = tint.blended(withFraction: 0.5, of: .white) ?? WFDesign.text2
    }
}
