import AppKit
import os

/// Launcher / dispatch window — the first thing the user sees when no
/// document is open.
///
/// Visual language
/// ---------------
/// Matches the canvas UI: #0c0c0c background, #FE6337 accent, rounded
/// corners, monospace micro-labels. Glass chrome elsewhere in the app is
/// painted with macOS 26 Tahoe `NSGlassEffectView` (dock + modals); the
/// Start window itself is a flat-fill NSView hierarchy because it's a
/// full-window surface, not a discrete floating pane. The goal is that
/// opening the Start window doesn't feel like a detour into stock AppKit —
/// it reads as part of the same product surface as the canvas.
///
/// Actions
/// -------
///   • New Project  — creates a new `WebFramesDocument` (managed URL)
///   • Projects     — one row per `.webframes` file in the app's project
///                     library; click to open, hover to reveal a delete
///                     button that asks for confirmation.
final class StartWindowController: NSWindowController, NSWindowDelegate {

    /// Matches the dock/help/frame-card aesthetic — identical width keeps
    /// visual rhythm if a user arranges Start alongside the canvas.
    static let windowWidth: CGFloat = 720
    static let windowHeight: CGFloat = 520

    init() {
        let rect = NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Web Frames"
        WFTheme.apply(to: window)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        // Solid dark behind the content view; the content itself paints the
        // layered glass/accent surface on top.
        window.backgroundColor = WFDesign.bg
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        // We own window lifetime; AppKit's automatic restoration would try
        // to reinstantiate this window after relaunch with no restoration
        // class and spam "className=(null)" into the log.
        window.isRestorable = false
        window.center()
        window.setFrameAutosaveName("WebFramesStartWindow")
        // UI test anchor — XCUITest resolves NSWindow by
        // accessibilityIdentifier, which is more robust than matching
        // on the localised title.
        window.setAccessibilityIdentifier("startWindow")

        super.init(window: window)
        window.delegate = self
        window.contentView = StartContentView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        // Let AppDelegate know so it can decide whether to keep the app alive
        // or offer "quit" behaviour. We don't destroy the controller —
        // `AppDelegate` may reshow us after the last document closes.
        NotificationCenter.default.post(name: .startWindowDidClose, object: self)
    }
}

extension Notification.Name {
    static let startWindowDidClose = Notification.Name("pro.webframes.startWindowDidClose")
}

// MARK: - Design tokens
//
// Swift mirror of the CSS `:root` variables in index.html. Keeping them in
// one struct means the native surface and the canvas stay visually in sync
// if the palette is tuned.

enum WFDesign {
    static let bg        = NSColor(red: 0.047, green: 0.047, blue: 0.047, alpha: 1) // #0c0c0c
    static let bg2       = NSColor(red: 0.086, green: 0.086, blue: 0.086, alpha: 1) // #161616
    static let bg3       = NSColor(red: 0.122, green: 0.122, blue: 0.122, alpha: 1) // #1f1f1f
    static let bg4       = NSColor(red: 0.157, green: 0.157, blue: 0.157, alpha: 1) // #282828
    static let bg5       = NSColor(red: 0.192, green: 0.192, blue: 0.192, alpha: 1) // #313131
    static let accent    = NSColor(red: 0.996, green: 0.388, blue: 0.216, alpha: 1) // #FE6337
    static let accentBg  = NSColor(red: 0.996, green: 0.388, blue: 0.216, alpha: 0.15)
    static let accentBdr = NSColor(red: 0.996, green: 0.388, blue: 0.216, alpha: 0.35)
    static let text      = NSColor(white: 0.886, alpha: 1)  // #e2e2e2 — primary
    static let text2     = NSColor(white: 0.533, alpha: 1)  // #888 — secondary
    // Bumped from 0.267 to 0.45 so field labels, counts, and selector
    // readouts clear AA Large contrast (≈3.5:1 on bg3 #1f1f1f). The old
    // value failed WCAG and rendered several labels close to invisible on
    // the glass surface. Strictly-decorative text (mini T/R/B/L quad
    // labels and similar scaffolding) should use `text4` instead, which
    // preserves the original dim recipe.
    static let text3     = NSColor(white: 0.45,  alpha: 1)  // #737373 — tertiary (AA Large)
    static let text4     = NSColor(white: 0.267, alpha: 1)  // #444 — decorative-only, fails AA
    static let border    = NSColor(white: 1, alpha: 0.07)
    static let border2   = NSColor(white: 1, alpha: 0.13)
    static let border3   = NSColor(white: 1, alpha: 0.20)
    static let danger    = NSColor(red: 0.95, green: 0.36, blue: 0.36, alpha: 1)

    // Corner-radius tiers. One source of truth for rounded-rect geometry
    // across the product. Tiered so that nested surfaces can step down
    // predictably: a 16-rad glass card contains 12-rad rows, which contain
    // 8-rad controls. This mirrors Apple's Liquid Glass guidance of keeping
    // parent/child curvatures in a consistent ratio.
    //
    //   .large  (16) — top-level glass panels, modal cards, window-scale cards
    //   .medium (12) — dock buttons, project rows, frame cards, major controls
    //   .small  (8)  — inline inputs, chips, pin swatches, small controls
    enum Radius {
        static let large:  CGFloat = 16
        static let medium: CGFloat = 12
        static let small:  CGFloat = 8
    }
}

// MARK: - Root content view

private final class StartContentView: NSView {

    private let projectsList = ProjectsListView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = WFDesign.bg.cgColor
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {

        // ── Wordmark ─ "web frames" in mono, lowercase — mirrors the
        //   product's inline type treatment in index.html.
        let logoImage = Self.loadRendererLogo()
        let logoView = NSImageView(image: logoImage ?? NSImage())
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(logoView)

        let wordmark = NSTextField(labelWithString: "web frames")
        wordmark.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .medium)
        wordmark.textColor = WFDesign.text
        wordmark.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wordmark)

        // ── Primary CTA sits on the same baseline as the wordmark, pinned
        //   to the right edge. Default button (Return activates).
        let newBtn = AccentButton(title: "New Project")
        newBtn.target = self
        newBtn.action = #selector(newProjectAction(_:))
        newBtn.keyEquivalent = "\r"
        newBtn.translatesAutoresizingMaskIntoConstraints = false
        newBtn.setAccessibilityIdentifier("newProjectButton")
        addSubview(newBtn)

        // ── Projects section ──────────────────────────────────────────
        let label = NSTextField(labelWithString: "Recent Projects")
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        label.textColor = WFDesign.text3
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        projectsList.translatesAutoresizingMaskIntoConstraints = false
        projectsList.setAccessibilityIdentifier("projectsList")
        addSubview(projectsList)

        // ── Footer link ─ quiet, centered "webframes.pro" pinned to the
        //   bottom. Clicking opens the marketing site in the default
        //   browser; no underline until hover, so it doesn't compete with
        //   the recent-projects list visually.
        let siteLink = SiteLinkButton()
        siteLink.target = self
        siteLink.action = #selector(openSite(_:))
        siteLink.translatesAutoresizingMaskIntoConstraints = false
        addSubview(siteLink)

        NSLayoutConstraint.activate([
            logoView.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            logoView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            // SVG is 20x13 — render at 26x17 so it reads cleanly next to
            // the 14pt mono wordmark without squishing its aspect ratio.
            logoView.widthAnchor.constraint(equalToConstant: 26),
            logoView.heightAnchor.constraint(equalToConstant: 17),

            wordmark.leadingAnchor.constraint(equalTo: logoView.trailingAnchor, constant: 10),
            wordmark.centerYAnchor.constraint(equalTo: logoView.centerYAnchor),

            newBtn.centerYAnchor.constraint(equalTo: wordmark.centerYAnchor),
            newBtn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            newBtn.widthAnchor.constraint(equalToConstant: 140),
            newBtn.heightAnchor.constraint(equalToConstant: 32),

            label.topAnchor.constraint(equalTo: logoView.bottomAnchor, constant: 48),
            label.leadingAnchor.constraint(equalTo: logoView.leadingAnchor),

            projectsList.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            projectsList.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32),
            projectsList.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32),
            projectsList.bottomAnchor.constraint(equalTo: siteLink.topAnchor, constant: -16),

            siteLink.centerXAnchor.constraint(equalTo: centerXAnchor),
            siteLink.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
        ])
    }

    @objc private func openSite(_ sender: Any?) {
        guard let url = URL(string: "https://webframes.pro") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Loads the shared `logo.svg` from the Renderer bundle directory — same
    /// asset the canvas uses — so the native surface and web surface stay
    /// visually identical.
    private static func loadRendererLogo() -> NSImage? {
        let url = Bundle.main.url(forResource: "logo",
                                  withExtension: "svg",
                                  subdirectory: "Renderer")
            ?? Bundle.main.url(forResource: "logo", withExtension: "svg")
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    // MARK: - Actions

    /// Create a new document, drive its window out ourselves, and retire
    /// the Start panel. We avoid `NSDocumentController.newDocument(_:)` so
    /// errors can be surfaced to the user directly instead of getting
    /// swallowed behind `presentError:`.
    @objc private func newProjectAction(_ sender: Any?) {
        Log.doc.info("StartWindow: New Project clicked")
        do {
            let doc = try NSDocumentController.shared.openUntitledDocumentAndDisplay(false)
            Log.doc.info("StartWindow: created untitled document \(String(describing: doc), privacy: .private)")

            doc.makeWindowControllers()
            Log.doc.info("after makeWindowControllers: \(doc.windowControllers.count) controller(s)")

            guard let newWin = doc.windowControllers.first?.window else {
                Log.doc.error("no window after makeWindowControllers")
                return
            }

            NSApp.activate(ignoringOtherApps: true)
            newWin.makeKeyAndOrderFront(nil)
            newWin.orderFrontRegardless()

            window?.orderOut(nil)
        } catch {
            Log.doc.error("StartWindow: openUntitledDocumentAndDisplay failed — \(error.localizedDescription, privacy: .private)")
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't create a new project"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

// MARK: - Buttons

/// Primary CTA — orange filled button, white label.
private final class AccentButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .rounded
        wantsLayer = true
        layer?.cornerRadius = WFDesign.Radius.medium
        setButtonType(.momentaryChange)
        contentTintColor = .white
        font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = (isHighlighted ? WFDesign.accent.withAlphaComponent(0.85)
                                                : WFDesign.accent).cgColor
    }
}

/// Borderless text-only button styled as a footer hyperlink. Underlines
/// on hover so it reads as a link without shouting on first glance, and
/// uses mono to match the product wordmark.
private final class SiteLinkButton: NSButton {

    private let label = "webframes.pro"
    private var hovered = false { didSet { restyle() } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        wantsLayer = true
        alignment = .center
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent)  { hovered = false }

    private func restyle() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: hovered ? WFDesign.text : WFDesign.text3,
            .underlineStyle: hovered ? NSUnderlineStyle.single.rawValue : 0,
        ]
        attributedTitle = NSAttributedString(string: label, attributes: attrs)
    }
}

// MARK: - Projects list

/// NSStackView variant pinned to top-down layout inside an NSScrollView.
/// Default `NSClipView` places non-flipped document views at the bottom
/// when they're shorter than the clip; marking the stack flipped flips
/// its own coordinate space and lines it up with the clip's top edge.
private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class ProjectsListView: NSView {

    private let scroll = NSScrollView()
    private let stack = FlippedStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Refresh when the Start window becomes key again — after closing a
        // doc window, it's likely the list needs new modification-date sort
        // order, and freshly-created projects should appear without relaunch.
        if let w = window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(reload),
                name: NSWindow.didBecomeKeyNotification,
                object: w
            )
        }
    }

    private func buildLayout() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor),
        ])
    }

    @objc private func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let entries = ProjectStorage.listProjects()
        if entries.isEmpty {
            let empty = NSTextField(labelWithString: "No projects yet — click New Project to start.")
            empty.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            empty.textColor = WFDesign.text3
            stack.addArrangedSubview(empty)
            return
        }
        for entry in entries {
            let row = ProjectRowView(entry: entry, owner: self)
            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            if let sv = row.superview {
                row.widthAnchor.constraint(equalTo: sv.widthAnchor).isActive = true
            }
        }
    }

    // MARK: - Row callbacks

    fileprivate func open(_ entry: ProjectStorage.Entry) {
        let url = entry.url
        NSDocumentController.shared.openDocument(
            withContentsOf: url,
            display: true,
            completionHandler: { [weak self] _, _, err in
                if let err {
                    Log.doc.error("open project failed: \(err.localizedDescription, privacy: .private)")
                    let alert = NSAlert(error: err)
                    alert.messageText = "Couldn't open project"
                    alert.informativeText = [err.localizedDescription, (err as NSError).localizedRecoverySuggestion]
                        .compactMap { $0 }.joined(separator: "\n\n")
                    alert.runModal()
                    return
                }
                self?.window?.orderOut(nil)
            }
        )
    }

    fileprivate func confirmDelete(_ entry: ProjectStorage.Entry) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \u{201C}\(entry.displayName)\u{201D}?"
        alert.informativeText = "This permanently removes the project file. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        // Make Cancel the default (Return key) so accidental Enter doesn't
        // delete; the destructive button stays clearly styled.
        alert.buttons.first?.hasDestructiveAction = true
        alert.buttons.last?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalent = ""

        guard let win = self.window else { return }
        alert.beginSheetModal(for: win) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try ProjectStorage.delete(entry.url)
            } catch {
                Log.doc.error("delete project failed: \(error.localizedDescription, privacy: .private)")
                let err = NSAlert(error: error)
                err.messageText = "Couldn't delete project"
                err.beginSheetModal(for: win, completionHandler: nil)
            }
            self?.reload()
        }
    }
}

// MARK: - Project row

/// One row in the projects list. Mirrors the `.ffile` glass-row look; shows
/// a delete icon (❌/trash) on hover which triggers a confirmation alert.
private final class ProjectRowView: NSView {

    private let entry: ProjectStorage.Entry
    private weak var owner: ProjectsListView?

    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let deleteButton = DeleteIconButton()

    private var hovered = false {
        didSet {
            deleteButton.isHidden = !hovered
            needsDisplay = true
        }
    }

    init(entry: ProjectStorage.Entry, owner: ProjectsListView) {
        self.entry = entry
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = WFDesign.Radius.medium
        layer?.borderWidth = 1

        nameLabel.stringValue = entry.displayName
        nameLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = WFDesign.text
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        metaLabel.stringValue = Self.relativeDate(entry.modifiedAt)
        metaLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        metaLabel.textColor = WFDesign.text3
        metaLabel.alignment = .right
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        // The date is fixed-width content — hug tighter than the name so
        // the name yields first when space is scarce.
        metaLabel.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
        metaLabel.setContentHuggingPriority(.defaultHigh + 1, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(metaLabel)

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.isHidden = true
        deleteButton.target = self
        deleteButton.action = #selector(deletePressed(_:))
        addSubview(deleteButton)

        heightAnchor.constraint(equalToConstant: 44).isActive = true
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: metaLabel.leadingAnchor, constant: -12),

            metaLabel.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            metaLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            // Square hit-target. The trash glyph's silhouette is narrower than
            // it is tall, so at smaller sizes the button visually reads as a
            // vertical rectangle even with equal width/height — 30×30 gives
            // enough padding around the icon for the background to read
            // unambiguously square on hover.
            deleteButton.widthAnchor.constraint(equalToConstant: 30),
            deleteButton.heightAnchor.constraint(equalToConstant: 30),
        ])

    }

    // Handling clicks via mouseDown/mouseUp rather than a gesture recognizer:
    // on macOS, a parent's NSClickGestureRecognizer can still fire when the
    // user clicks a subview button. Here, delegating via hit-testing means
    // the delete button swallows its own click naturally (it's a subview
    // NSButton), while a click on the row body lands on this view and
    // triggers `open`. Drag-to-scroll is preserved — mouseUp fires only if
    // the pointer is still inside the row's bounds.

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = (hovered ? WFDesign.bg3 : WFDesign.bg2).cgColor
        layer?.borderColor     = (hovered ? WFDesign.border2 : WFDesign.border).cgColor
    }

    // MARK: - Hover tracking

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent)  { hovered = false }

    // MARK: - Clicks

    /// No-op; we need to consume mouseDown here so the window's
    /// `isMovableByWindowBackground` doesn't start dragging the Start window
    /// when the user clicks a row.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        owner?.open(entry)
    }

    @objc private func deletePressed(_ sender: Any?) {
        owner?.confirmDelete(entry)
    }

    /// "Today 13:05" / "Yesterday 09:12" / "Mar 12, 2026" — whichever fits
    /// the relative distance best. Matches the common macOS file-browser feel.
    private static func relativeDate(_ date: Date) -> String {
        let f = DateFormatter()
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            f.dateFormat = "'Today' HH:mm"
        } else if cal.isDateInYesterday(date) {
            f.dateFormat = "'Yesterday' HH:mm"
        } else if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
            f.dateFormat = "MMM d"
        } else {
            f.dateFormat = "MMM d, yyyy"
        }
        return f.string(from: date)
    }
}

// MARK: - Delete icon button (trash glyph)

/// Small borderless button with an SF Symbols trash icon. Visible only
/// while its row is hovered. Dims to accent-red when hovered itself so
/// the destructive intent is legible without needing a label.
private final class DeleteIconButton: NSButton {

    private var hovered = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = WFDesign.Radius.small
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        // SF Symbols — falls back to a literal "×" if unavailable (e.g. older
        // macOS SDK at build time), which still reads as "delete".
        let sym = NSImage(systemSymbolName: "trash", accessibilityDescription: "Delete project")
        self.image = sym
        contentTintColor = WFDesign.text2
        toolTip = "Delete project"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = (hovered ? NSColor(white: 1, alpha: 0.06) : .clear).cgColor
        contentTintColor = hovered ? WFDesign.danger : WFDesign.text2
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent)  { hovered = false }
}
