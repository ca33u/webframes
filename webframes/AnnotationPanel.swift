import AppKit

// MARK: - Data

/// Annotation payload pushed from the canvas JS via the bridge.
///
/// The canvas remains the source of truth for the annotations array (all
/// mutations — add, delete, toggle-resolve, reset — still happen there so
/// pin pops, color bindings, and persistence keep working). The panel is a
/// passive *view* on that state: JS serializes its current `annotations`
/// into `[AnnotationInfo]` whenever anything changes and pushes the list
/// here via `setAnnotations(_:)`. Actions the user takes in the panel are
/// routed back through `AnnotationPanelDelegate` and translated into
/// existing JS handlers, so the native panel doesn't need to reimplement
/// any of the annotation logic.
struct AnnotationInfo {
    let id: String
    let num: Int
    let color: String          // "blue" | "red" | "amber" | "green" | "purple"
    let comment: String        // may be empty → "no comment" placeholder
    let resolved: Bool
    let frameLabel: String     // resolved label string "page" / "localhost:3000" / etc.
    let viewport: String?      // "1280×800" — nil if unknown
    let selector: String       // element selector / path / tagName / "—"
    let screenshot: NSImage?   // decoded from a.element.screenshot data-URL
    var resolutionNote: String? = nil
    let editKeys: [String]     // Object.keys(a.edits) — for edit chips

    static func parse(_ dict: [String: Any]) -> AnnotationInfo? {
        guard let id = dict["id"] as? String,
              let num = dict["num"] as? Int,
              let frameLabel = dict["frameLabel"] as? String else { return nil }
        let color = (dict["color"] as? String) ?? "blue"
        let comment = (dict["comment"] as? String) ?? ""
        let resolved = (dict["resolved"] as? Bool) ?? false
        let viewport = dict["viewport"] as? String
        let selector = (dict["selector"] as? String) ?? "—"
        let editKeys = (dict["editKeys"] as? [String]) ?? []

        var image: NSImage?
        if let dataURL = dict["screenshot"] as? String,
           let comma = dataURL.firstIndex(of: ","),
           let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) {
            image = NSImage(data: data)
        }

        return AnnotationInfo(
            id: id, num: num, color: color, comment: comment,
            resolved: resolved, frameLabel: frameLabel, viewport: viewport,
            selector: selector, screenshot: image, editKeys: editKeys
        )
    }
}

// MARK: - Delegate

protocol AnnotationPanelDelegate: AnyObject {
    func annotationPanelDidRequestClose()
    func annotationPanelDidRequestResetCounters()
    func annotationPanelDidRequestCopyAll()
    func annotationPanelDidRequestDownloadMarkdown()
    func annotationPanelDidRequestFixWithCodex()
    func annotationPanel(didSelect id: String)
    func annotationPanel(didRequestDelete id: String)
    func annotationPanel(didRequestCopy id: String)
    func annotationPanel(didToggleResolved id: String)
}

// MARK: - Pin colors

enum PinColor {
    /// Pin hues deliberately defer to system semantic colors rather than
    /// hand-rolled RGB. On Tahoe these hues shift with Increase Contrast,
    /// Reduce Transparency, and the system color-blind filters — so pins
    /// stay legible across accessibility modes without per-app tuning.
    /// The `orange` case (not currently exposed in the JS palette but
    /// reserved for future use) maps to `.systemOrange` to preserve the
    /// app's accent hue family if we add it back as an option.
    static func resolve(_ name: String) -> NSColor {
        switch name {
        case "red":    return .systemRed
        case "amber":  return .systemYellow
        case "green":  return .systemGreen
        case "purple": return .systemPurple
        case "blue":   return .systemBlue
        case "orange": return .systemOrange
        default:       return WFDesign.text2
        }
    }
}

// MARK: - Panel

/// Comments inspector (the trailing split item). Built from stock AppKit:
/// a sidebar-material surface, a title bar with an overflow menu, a
/// view-based `NSTableView` in inset style (system selection, hover and
/// context menu), and Fix as an accent push button with a menu button
/// next to it (NSComboButton cannot take the accent color).
///
/// Rows follow Reminders: a leading circle in the comment's color toggles
/// resolved, the first line names the comment and its frame, the comment
/// text follows. Copy, Resolve and Delete are in the row's context menu.
final class AnnotationPanel: NSVisualEffectView {

    weak var delegate: AnnotationPanelDelegate?

    private(set) var isShowing = false
    private var annotations: [AnnotationInfo] = []
    private var screenshotsEnabled = true

    private let header = NSView()
    private let titleLabel = NSTextField(labelWithString: "Comments")
    private let countLabel = NSTextField(labelWithString: "")
    private let moreButton = AnnotationPanel.iconButton("ellipsis.circle", "More")
    private let closeButton = AnnotationPanel.iconButton("sidebar.trailing", "Hide Comments")
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No comments yet")
    private let footer = NSView()
    private let fixButton = NSButton(title: "Fix", target: nil, action: nil)
    private let fixMenuButton = NSButton()
    private let fixMenu = NSMenu()
    /// Width the comment text actually gets in a laid-out row; row heights
    /// are measured against it (the inset table style adds its own margins).
    private var measuredTextWidth: CGFloat?
    private var copyFeedbackTimer: Timer?
    private var providerObserver: NSObjectProtocol?

    // MARK: init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        providerObserver = NotificationCenter.default.addObserver(forName: AgentProvider.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateExportActions() }
        }
        translatesAutoresizingMaskIntoConstraints = false
        // Same material as the frames sidebar so both flanks match.
        material = .sidebar
        blendingMode = .withinWindow
        state = .followsWindowActiveState

        buildHeader()
        buildBody()
        buildFooter()
        renderList()
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func iconButton(_ symbol: String, _ label: String) -> NSButton {
        let b = NSButton()
        b.bezelStyle = .accessoryBarAction
        b.isBordered = false
        b.imagePosition = .imageOnly
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = label
        b.setAccessibilityLabel(label)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return b
    }

    // MARK: Build

    private func buildHeader() {
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        countLabel.font = .systemFont(ofSize: 13)
        countLabel.textColor = .secondaryLabelColor
        for v in [titleLabel, countLabel] { v.translatesAutoresizingMaskIntoConstraints = false }

        moreButton.target = self
        moreButton.action = #selector(onMoreClicked(_:))
        closeButton.target = self
        closeButton.action = #selector(onCloseClicked)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        [titleLabel, countLabel, moreButton, closeButton, divider].forEach(header.addSubview)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            countLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),

            closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            moreButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -8),

            divider.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
    }

    private func buildBody() {
        let column = NSTableColumn(identifier: .init("comment"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(onRowClicked)
        table.setAccessibilityLabel("Comments")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = table
        scroll.contentView.postsBoundsChangedNotifications = false
        addSubview(scroll)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    private func buildFooter() {
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(divider)

        for b in [fixButton, fixMenuButton] {
            b.bezelStyle = .push
            b.controlSize = .large
            b.bezelColor = WFDesign.accent
            b.translatesAutoresizingMaskIntoConstraints = false
            footer.addSubview(b)
        }
        fixButton.target = self
        fixButton.action = #selector(onFixWithCodexClicked)
        fixButton.toolTip = "Prepare changes for all open comments; review before applying"
        fixButton.setAccessibilityIdentifier("comments.fixWithCodex")
        fixButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        fixMenuButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "More comment actions")
        fixMenuButton.imagePosition = .imageOnly
        fixMenuButton.target = self
        fixMenuButton.action = #selector(onFixMenuClicked(_:))
        fixMenuButton.toolTip = "Copy or download all open comments, or choose the agent"
        fixMenuButton.setAccessibilityIdentifier("comments.exportMenu")
        fixMenu.delegate = self
        updateExportActions()

        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 56),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),

            divider.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            divider.topAnchor.constraint(equalTo: footer.topAnchor),

            fixButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            fixButton.trailingAnchor.constraint(equalTo: fixMenuButton.leadingAnchor, constant: -4),
            fixButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            fixMenuButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            fixMenuButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            fixMenuButton.widthAnchor.constraint(equalToConstant: 40),
        ])
    }

    // MARK: Public API

    func setScreenshotsEnabled(_ enabled: Bool) {
        if screenshotsEnabled == enabled { return }
        screenshotsEnabled = enabled
        renderList()
    }

    func setAnnotations(_ list: [AnnotationInfo]) {
        annotations = list
        countLabel.stringValue = list.isEmpty ? "" : String(list.count)
        updateExportActions()
        renderList()
    }

    func setVisible(_ visible: Bool, animated: Bool = true) {
        if isShowing == visible { return }
        isShowing = visible
        if visible { isHidden = false }
        wantsLayer = true
        let offX: CGFloat = bounds.width + 24
        if animated {
            if visible {
                layer?.transform = CATransform3DMakeTranslation(offX, 0, 0)
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    self.animator().alphaValue = 1
                    self.layer?.transform = CATransform3DIdentity
                }
            } else {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    self.animator().alphaValue = 0
                    self.layer?.transform = CATransform3DMakeTranslation(offX, 0, 0)
                }, completionHandler: {
                    self.isHidden = true
                    self.layer?.transform = CATransform3DIdentity
                })
            }
        } else {
            alphaValue = visible ? 1 : 0
            isHidden = !visible
        }
    }

    private var openCommentCount: Int { annotations.filter { !$0.resolved }.count }

    private func updateExportActions() {
        guard copyFeedbackTimer == nil else { return }
        let count = openCommentCount
        let name = AgentProvider.current.name
        fixButton.title = count > 0 ? "Fix with \(name) · \(count)" : "Fix with \(name)"
        fixButton.isEnabled = count > 0
        fixMenuButton.isEnabled = count > 0
    }

    func flashCopied() {
        copyFeedbackTimer?.invalidate()
        fixButton.title = "Copied"
        copyFeedbackTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.copyFeedbackTimer = nil
                self?.updateExportActions()
            }
        }
    }

    /// A laid-out row reports the width its comment text gets; when that
    /// changes (first layout, sidebar resize) row heights are re-measured.
    fileprivate func rowTextWidthChanged(_ width: CGFloat) {
        guard width > 0, abs(width - (measuredTextWidth ?? 0)) > 0.5 else { return }
        measuredTextWidth = width
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.annotations.isEmpty else { return }
            self.table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<self.annotations.count))
        }
    }

    // MARK: List rendering

    private func renderList() {
        emptyLabel.isHidden = !annotations.isEmpty
        table.reloadData()
    }

    fileprivate func toggleResolved(id: String) { delegate?.annotationPanel(didToggleResolved: id) }

    // MARK: Actions

    @objc private func onRowClicked() {
        let row = table.clickedRow
        guard annotations.indices.contains(row) else { return }
        delegate?.annotationPanel(didSelect: annotations[row].id)
    }

    @objc private func onCloseClicked() {
        delegate?.annotationPanelDidRequestClose()
    }

    @objc private func onMoreClicked(_ sender: NSButton) {
        let menu = NSMenu()
        let reset = menu.addItem(withTitle: "Reset Comment Numbers", action: #selector(onResetClicked), keyEquivalent: "")
        reset.target = self
        reset.isEnabled = !annotations.isEmpty
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func onResetClicked() {
        delegate?.annotationPanelDidRequestResetCounters()
    }

    @objc private func onCopyAllClicked() {
        guard openCommentCount > 0 else { return }
        delegate?.annotationPanelDidRequestCopyAll()
    }

    @objc private func onFixMenuClicked(_ sender: NSButton) {
        fixMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func onFixWithCodexClicked() {
        guard openCommentCount > 0 else { return }
        delegate?.annotationPanelDidRequestFixWithCodex()
    }

    /// Fix's menu: export actions and the agent comments go to.
    private func fillFixMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let copy = menu.addItem(withTitle: "Copy All", action: #selector(onCopyAllClicked), keyEquivalent: "")
        copy.target = self
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        let download = menu.addItem(withTitle: "Download Markdown…", action: #selector(onDownloadMarkdownClicked), keyEquivalent: "")
        download.target = self
        download.image = NSImage(systemSymbolName: "arrow.down.document", accessibilityDescription: nil)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Send to"))
        for provider in AgentProvider.allCases {
            let installed = (try? BundledTools.agent(provider)) != nil
            let item = menu.addItem(withTitle: provider.productName + (installed ? "" : " — not installed"),
                                    action: installed ? #selector(onChooseAgent(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = provider.rawValue
            item.state = provider == AgentProvider.current ? .on : .off
            item.isEnabled = installed
        }
    }

    /// Row context menu: the clicked comment's actions.
    private func fillRowMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard annotations.indices.contains(row) else { return }
        let ann = annotations[row]
        let copy = menu.addItem(withTitle: "Copy", action: #selector(onRowCopy(_:)), keyEquivalent: "")
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        let resolve = menu.addItem(withTitle: ann.resolved ? "Reopen" : "Resolve", action: #selector(onRowResolve(_:)), keyEquivalent: "")
        resolve.image = NSImage(systemSymbolName: ann.resolved ? "arrow.uturn.backward.circle" : "checkmark.circle", accessibilityDescription: nil)
        menu.addItem(.separator())
        let delete = menu.addItem(withTitle: "Delete", action: #selector(onRowDelete(_:)), keyEquivalent: "")
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        for item in [copy, resolve, delete] {
            item.target = self
            item.representedObject = ann.id
        }
    }

    @objc private func onRowCopy(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { delegate?.annotationPanel(didRequestCopy: id) }
    }
    @objc private func onRowResolve(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { delegate?.annotationPanel(didToggleResolved: id) }
    }
    @objc private func onRowDelete(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { delegate?.annotationPanel(didRequestDelete: id) }
    }

    @objc private func onChooseAgent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let provider = AgentProvider(rawValue: raw),
              provider != AgentProvider.current else { return }
        AgentProvider.current = provider
        CodexConnectionStore.shared.agentConfigurationChanged()
        updateExportActions()
    }

    @objc private func onDownloadMarkdownClicked() {
        guard openCommentCount > 0 else { return }
        delegate?.annotationPanelDidRequestDownloadMarkdown()
    }
}

extension AnnotationPanel: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === table.menu { fillRowMenu(menu) } else if menu === fixMenu { fillFixMenu(menu) }
    }
}

extension AnnotationPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { annotations.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("AnnotationCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? AnnotationCellView) ?? {
            let c = AnnotationCellView()
            c.identifier = id
            return c
        }()
        cell.configure(annotations[row], showScreenshot: screenshotsEnabled) { [weak self] id in
            self?.toggleResolved(id: id)
        }
        cell.onTextWidth = { [weak self] width in self?.rowTextWidthChanged(width) }
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let width = measuredTextWidth
            ?? max(120, (tableView.tableColumns.first?.width ?? tableView.bounds.width) - AnnotationCellView.horizontalInsets)
        return AnnotationCellView.height(for: annotations[row], showScreenshot: screenshotsEnabled, textWidth: width)
    }
}

// MARK: - Row

/// One comment in the list: color circle (resolve toggle), a first line
/// with the number and frame, the comment text and an optional thumbnail.
private final class AnnotationCellView: NSTableCellView {
    static let circleSize: CGFloat = 18
    static let leading: CGFloat = 6
    static let textLeading: CGFloat = leading + circleSize + 8
    static let trailing: CGFloat = 8
    static let horizontalInsets: CGFloat = textLeading + trailing + 20   // + inset table margins
    static let thumbHeight: CGFloat = 72
    static let commentFont = NSFont.systemFont(ofSize: 13)
    static let maxCommentLines = 3
    private static let sizingCell: NSTextFieldCell = {
        let cell = NSTextFieldCell(textCell: "")
        cell.wraps = true
        cell.isScrollable = false
        cell.lineBreakMode = .byWordWrapping
        cell.truncatesLastVisibleLine = true
        return cell
    }()

    private let circle = NSButton()
    private let metaLabel = NSTextField(labelWithString: "")
    private let commentLabel = NSTextField(wrappingLabelWithString: "")
    private let thumb = NSImageView()
    private var thumbHeightConstraint: NSLayoutConstraint!
    private var annotationID = ""
    private var onToggle: ((String) -> Void)?
    var onTextWidth: ((CGFloat) -> Void)?

    init() {
        super.init(frame: .zero)
        circle.bezelStyle = .accessoryBarAction
        circle.isBordered = false
        circle.imagePosition = .imageOnly
        circle.target = self
        circle.action = #selector(toggle)

        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.maximumNumberOfLines = 1
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        commentLabel.font = Self.commentFont
        commentLabel.maximumNumberOfLines = Self.maxCommentLines
        commentLabel.lineBreakMode = .byTruncatingTail
        commentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        thumb.imageScaling = .scaleProportionallyDown
        thumb.imageAlignment = .alignLeft
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 4
        thumb.layer?.masksToBounds = true

        for v in [circle, metaLabel, commentLabel, thumb] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        thumbHeightConstraint = thumb.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            circle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leading),
            circle.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            circle.widthAnchor.constraint(equalToConstant: Self.circleSize + 4),
            circle.heightAnchor.constraint(equalToConstant: Self.circleSize + 4),

            metaLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textLeading),
            metaLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailing),
            metaLabel.centerYAnchor.constraint(equalTo: circle.centerYAnchor),

            commentLabel.leadingAnchor.constraint(equalTo: metaLabel.leadingAnchor),
            commentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailing),
            commentLabel.topAnchor.constraint(equalTo: metaLabel.bottomAnchor, constant: 3),

            thumb.leadingAnchor.constraint(equalTo: metaLabel.leadingAnchor),
            thumb.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.trailing),
            thumb.topAnchor.constraint(equalTo: commentLabel.bottomAnchor, constant: 6),
            thumbHeightConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        let textWidth = max(0, bounds.width - Self.textLeading - Self.trailing)
        commentLabel.preferredMaxLayoutWidth = textWidth
        super.layout()
        onTextWidth?(textWidth)
    }

    func configure(_ a: AnnotationInfo, showScreenshot: Bool, onToggle: @escaping (String) -> Void) {
        annotationID = a.id
        self.onToggle = onToggle
        let color = PinColor.resolve(a.color)
        circle.image = NSImage(systemSymbolName: a.resolved ? "checkmark.circle.fill" : "circle",
                               accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: Self.circleSize - 2, weight: .regular))
        circle.contentTintColor = a.resolved ? .tertiaryLabelColor : color
        circle.toolTip = (a.resolved ? "Reopen comment" : "Resolve comment") + (a.resolutionNote.map { " · " + $0 } ?? "")
        circle.setAccessibilityLabel(circle.toolTip)
        circle.setAccessibilityIdentifier("commentStatus." + a.id)

        let meta = NSMutableAttributedString(string: "#\(a.num)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: a.resolved ? NSColor.tertiaryLabelColor : color,
        ])
        var rest = "  " + a.frameLabel
        if let viewport = a.viewport { rest += " · " + viewport }
        if let note = a.resolutionNote { rest += " · " + note }
        meta.append(NSAttributedString(string: rest, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        metaLabel.attributedStringValue = meta

        commentLabel.attributedStringValue = Self.commentText(a)
        setAccessibilityLabel("Comment \(a.num): \(a.comment)")

        if showScreenshot, let image = a.screenshot {
            thumb.image = image
            thumb.isHidden = false
            thumbHeightConstraint.constant = Self.thumbHeight
        } else {
            thumb.image = nil
            thumb.isHidden = true
            thumbHeightConstraint.constant = 0
        }
    }

    private static func commentText(_ a: AnnotationInfo) -> NSAttributedString {
        var text = a.comment.isEmpty ? "No comment" : a.comment
        if !a.editKeys.isEmpty { text += "\nEdits: " + a.editKeys.prefix(6).joined(separator: ", ") }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: commentFont,
            .foregroundColor: a.comment.isEmpty || a.resolved ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        if a.resolved { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: text, attributes: attrs)
    }

    static func height(for a: AnnotationInfo, showScreenshot: Bool, textWidth: CGFloat) -> CGFloat {
        // Measure the way the label lays out: a wrapping text field cell,
        // capped at the label's line limit.
        sizingCell.attributedStringValue = commentText(a)
        let full = ceil(sizingCell.cellSize(forBounds: NSRect(x: 0, y: 0, width: textWidth, height: 10_000)).height)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: commentFont)
        let comment = min(full, ceil(lineHeight * CGFloat(maxCommentLines)) + 2)
        let thumb = (showScreenshot && a.screenshot != nil) ? thumbHeight + 6 : 0
        // top 7 + meta row (circle 22) + gap 3 + comment + thumb + bottom 10
        return 7 + 22 + 3 + comment + thumb + 10
    }

    @objc private func toggle() { onToggle?(annotationID) }
}

// MARK: - Helper views

/// Shared flipped clip — used by top-pinned scrolling lists (the frames
/// sidebar). Without this, NSScrollView lays content out bottom-up
/// (AppKit's default coordinate system) and the first row hugs the bottom
/// of the clip.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
