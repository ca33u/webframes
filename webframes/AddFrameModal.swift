import AppKit
import Network
import os
import UniformTypeIdentifiers

// MARK: - Delegate

/// Contract back to the host (CanvasHost). The modal reports tab-agnostic
/// user intents — forward a confirmed spec, or dismiss without one. All
/// spec-to-URL/spec-to-frame conversion is done on the canvas JS side so
/// `spawnFrame()` remains the single source of truth for frame creation.
protocol AddFrameModalDelegate: AnyObject {
    func addFrameModal(_ modal: AddFrameModal,
                       didConfirmSpec spec: [String: Any])
    func addFrameModalDidCancel(_ modal: AddFrameModal)
}

// MARK: - AddFrameModal

/// Native Add-frame modal. Replaces the HTML `.mb/.md` modal that lived
/// in index.html. Each tab body is a separate panel implementing
/// `AddFrameTabPanel`; switching tabs swaps the installed body view.
final class AddFrameModal: NSView {

    private let serverDiscovery: LocalServerDiscovery
    weak var delegate: AddFrameModalDelegate?
    var projectImportView: ((@escaping () -> Void) -> AddFrameTabPanel?)?
    var onOpenSettings: (() -> Void)?

    // MARK: Subviews
    private let backdrop = NSView()
    // macOS 26 Tahoe: the card is a Liquid Glass surface. `card` is the
    // glass pane; `cardContent` is its `contentView` and parents every
    // subview (title, tab bar, body, footer). Apple's guidance on
    // NSGlassEffectView: subviews go into `contentView` only, never as
    // siblings of the glass — so all setup methods below anchor to
    // `cardContent.{top,leading,trailing,bottom}Anchor`.
    private let card = WFGlassEffectView()
    private let cardContent = NSView()
    private let titleLabel = NSTextField(labelWithString: "Add Frames")
    private let tabControl = NSSegmentedControl(
        labels: ["Project", "Web Page", "GitHub", "Image"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let bodyContainer = AddFrameFormView()
    private let bodyScroll = NSScrollView()
    private let cancelBtn = NSButton(title: "Cancel", target: nil, action: nil)
    private let confirmBtn = NSButton(title: "Add Frames", target: nil, action: nil)

    private let tabIDs = ["project", "web", "github", "image"]
    private var activeTabId: String = "web"

    private lazy var webPanel:    AddFrameTabPanel = WebPageTabPanel(discovery: serverDiscovery, onValidityChange:  { [weak self] in self?.refreshConfirmState() })
    private lazy var githubPanel: AddFrameTabPanel = GitHubTabPanel(onValidityChange: { [weak self] in self?.refreshConfirmState() }, onOpenSettings: { [weak self] in self?.onOpenSettings?() })
    private lazy var imagePanel:  ImageTabPanel = ImageTabPanel(onValidityChange:    { [weak self] in self?.refreshConfirmState() })

    private var currentPanel: AddFrameTabPanel?

    // MARK: Init

    init(discovery: LocalServerDiscovery) {
        self.serverDiscovery = discovery
        super.init(frame: .zero)
        setupBackdrop()
        setupCard()
        setupTitle()
        setupTabBar()
        setupBody()
        setupFooter()
        selectTab("web")

        confirmBtn.keyEquivalent = "\r"
        cancelBtn.keyEquivalent  = "\u{1b}"

        setAccessibilityIdentifier("webframes.addFrameModal")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Public

    /// Called by the host before (re)presenting, so state from the
    /// previous open doesn't leak into the new one.
    func reset() {
        webPanel.reset()
        githubPanel.reset()
        imagePanel.reset()
        selectTab("web")
    }

    // MARK: Setup

    private func setupBackdrop() {
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        let tap = NSClickGestureRecognizer(target: self, action: #selector(backdropClicked))
        backdrop.addGestureRecognizer(tap)
    }

    private func setupCard() {
        // NSGlassEffectView provides the Liquid Glass pane + chrome. No
        // material / blendingMode / explicit border needed.
        card.cornerRadius = WFDesign.Radius.large
        card.translatesAutoresizingMaskIntoConstraints = false

        cardContent.translatesAutoresizingMaskIntoConstraints = false
        card.contentView = cardContent

        addSubview(card)
        let preferredWidth = card.widthAnchor.constraint(equalToConstant: 520)
        let preferredHeight = card.heightAnchor.constraint(equalToConstant: 540)
        preferredWidth.priority = .defaultHigh
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredWidth, preferredHeight,
            card.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.94),
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor,
                                         multiplier: 0.92),
        ])
    }

    private func setupTitle() {
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = WFDesign.text
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        cardContent.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: cardContent.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor, constant: 20),
        ])
    }

    private func setupTabBar() {
        tabControl.segmentStyle = .rounded
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        cardContent.addSubview(tabControl)

        NSLayoutConstraint.activate([
            tabControl.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 14),
            tabControl.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor, constant: 20),
            tabControl.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor, constant: -20),
        ])
    }

    private func setupBody() {
        bodyScroll.drawsBackground = false
        bodyScroll.hasVerticalScroller = true
        bodyScroll.autohidesScrollers = true
        bodyScroll.scrollerStyle = .overlay
        bodyScroll.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyScroll.documentView = bodyContainer
        cardContent.addSubview(bodyScroll)
        NSLayoutConstraint.activate([
            bodyScroll.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 20),
            bodyScroll.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor, constant: 20),
            bodyScroll.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor, constant: -20),
            bodyScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            bodyContainer.topAnchor.constraint(equalTo: bodyScroll.contentView.topAnchor),
            bodyContainer.leadingAnchor.constraint(equalTo: bodyScroll.contentView.leadingAnchor),
            bodyContainer.widthAnchor.constraint(equalTo: bodyScroll.contentView.widthAnchor),
        ])
    }

    private func setupFooter() {
        cancelBtn.target = self
        cancelBtn.action = #selector(cancelClicked)
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.bezelStyle = .rounded
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false

        confirmBtn.target = self
        confirmBtn.action = #selector(confirmClicked)
        confirmBtn.bezelStyle = .rounded
        confirmBtn.keyEquivalent = "\r"
        confirmBtn.translatesAutoresizingMaskIntoConstraints = false

        let foot = NSStackView(views: [cancelBtn, confirmBtn])
        foot.orientation = .horizontal
        foot.alignment = .centerY
        foot.spacing = 8
        foot.translatesAutoresizingMaskIntoConstraints = false
        cardContent.addSubview(foot)

        NSLayoutConstraint.activate([
            foot.topAnchor.constraint(equalTo: bodyScroll.bottomAnchor, constant: 20),
            foot.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor, constant: -20),
            foot.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor, constant: -16),
        ])
    }

    // MARK: Tab switching

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        guard tabIDs.indices.contains(sender.selectedSegment) else { return }
        selectTab(tabIDs[sender.selectedSegment])
    }

    private func selectTab(_ id: String) {
        window?.makeFirstResponder(nil)
        activeTabId = id
        if let index = tabIDs.firstIndex(of: id) { tabControl.selectedSegment = index }
        installPanel(for: id)
        refreshConfirmState()
    }

    private func installPanel(for id: String) {
        currentPanel?.view.removeFromSuperview()
        titleLabel.stringValue = "Add Frames"
        let panel: AddFrameTabPanel
        switch id {
        case "project":
            guard let projectPanel = projectImportView?({ [weak self] in self?.refreshConfirmState() }) else { return }
            panel = projectPanel
        case "web": panel = webPanel
        case "github": panel = githubPanel
        case "image": panel = imagePanel
        default: panel = webPanel
        }
        currentPanel = panel
        let v = panel.view
        v.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            v.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
        ])
        bodyScroll.contentView.scroll(to: .zero)
        bodyScroll.reflectScrolledClipView(bodyScroll.contentView)
        panel.willAppear()
    }

    func pasteImage() -> Bool {
        guard activeTabId == "image" else { return false }
        return imagePanel.pasteImage()
    }

    private func refreshConfirmState() {
        confirmBtn.title = currentPanel?.confirmationTitle ?? "Add Frames"
        confirmBtn.isEnabled = currentPanel?.canConfirm ?? false
    }

    // MARK: Actions

    @objc private func backdropClicked() { delegate?.addFrameModalDidCancel(self) }
    @objc private func cancelClicked()   { delegate?.addFrameModalDidCancel(self) }
    @objc private func confirmClicked() {
        window?.makeFirstResponder(nil)
        guard currentPanel?.canConfirm == true else { return }
        if currentPanel?.performConfirmation() == true { return }
        guard let spec = currentPanel?.currentSpec() else { return }
        delegate?.addFrameModal(self, didConfirmSpec: spec)
    }
}

private final class AddFrameFormView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - AddFrameTabPanel

/// Contract between shell and tab body. `currentSpec` returns nil when
/// inputs are incomplete — the shell uses that to toggle the confirm
/// button's enabled state. Callback-driven validity is a trade-off: the
/// alternative (poll on every field change from the shell) would need
/// either a timer or tighter coupling — passing a closure in construction
/// keeps the shell → panel flow one-way.
protocol AddFrameTabPanel: AnyObject {
    var view: NSView { get }
    func currentSpec() -> [String: Any]?
    var canConfirm: Bool { get }
    var confirmationTitle: String { get }
    func performConfirmation() -> Bool
    func reset()
    func willAppear()
}

extension AddFrameTabPanel {
    var canConfirm: Bool { currentSpec() != nil }
    var confirmationTitle: String { "Add Frames" }
    func performConfirmation() -> Bool { false }
    func willAppear() {}
    func reset() {}
}

// MARK: - Shared: size row (presets + W/H inputs)

/// Reusable size-control row — used by all four tab panels. Owns preset
/// buttons and manually-editable W/H fields. Preset click = overwrite
/// fields; manual edit = deselect preset.
final class SizeControlRow: NSView, NSTextFieldDelegate {

    struct Preset { let title: String; let w: Int; let h: Int }
    private static let presets: [Preset] = [
        .init(title: "iPhone",  w: 375,  h: 812),
        .init(title: "Desktop", w: 1280, h: 800),
        .init(title: "iPad",    w: 768,  h: 1024),
        .init(title: "XL",      w: 1440, h: 900),
    ]

    let wField = NSTextField()
    let hField = NSTextField()
    private let presetControl = NSSegmentedControl()
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        build()
        applyPreset(index: 1)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var width:  Int { max(16, Int(wField.stringValue) ?? 1280) }
    var height: Int { max(16, Int(hField.stringValue) ?? 800) }

    private func build() {
        let label = NSTextField(labelWithString: "Frame size")
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = WFDesign.text2
        label.translatesAutoresizingMaskIntoConstraints = false

        presetControl.segmentCount = Self.presets.count
        presetControl.trackingMode = .selectOne
        presetControl.segmentStyle = .rounded
        presetControl.target = self
        presetControl.action = #selector(presetClicked(_:))
        for (i, preset) in Self.presets.enumerated() { presetControl.setLabel(preset.title, forSegment: i) }
        presetControl.translatesAutoresizingMaskIntoConstraints = false

        wField.stringValue = "1280"
        hField.stringValue = "800"
        wField.formatter = Self.intFormatter()
        hField.formatter = Self.intFormatter()
        wField.delegate = self
        hField.delegate = self
        wField.translatesAutoresizingMaskIntoConstraints = false
        hField.translatesAutoresizingMaskIntoConstraints = false

        let wLab = Self.miniLabel("Width")
        let hLab = Self.miniLabel("Height")
        let whRow = NSStackView(views: [wLab, wField, hLab, hField])
        whRow.orientation = .horizontal
        whRow.alignment = .centerY
        whRow.spacing = 6
        whRow.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [label, presetControl, whRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            wField.widthAnchor.constraint(equalToConstant: 72),
            hField.widthAnchor.constraint(equalToConstant: 72),
        ])
    }

    @objc private func presetClicked(_ sender: NSSegmentedControl) {
        applyPreset(index: sender.selectedSegment)
        onChange()
    }

    func applyPreset(index: Int) {
        guard Self.presets.indices.contains(index) else { return }
        let p = Self.presets[index]
        wField.stringValue = String(p.w)
        hField.stringValue = String(p.h)
        presetControl.selectedSegment = index
    }

    func controlTextDidChange(_ obj: Notification) {
        presetControl.selectedSegment = -1
        onChange()
    }

    private static func miniLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 11, weight: .medium)
        l.textColor = WFDesign.text2
        return l
    }

    private static func intFormatter() -> NumberFormatter {
        let f = NumberFormatter()
        f.allowsFloats = false
        f.minimum = 16
        f.maximum = 8192
        return f
    }
}

// MARK: - Shared: field label helper

func makeFieldLabel(_ text: String) -> NSTextField {
    let l = NSTextField(labelWithString: text)
    l.font = .systemFont(ofSize: 11, weight: .medium)
    l.textColor = WFDesign.text2
    return l
}

// MARK: - Shared: file-row (checkbox + path)

final class FileRow: NSView {
    let path: String
    var isSelected: Bool {
        didSet { checkbox.state = isSelected ? .on : .off; layer?.backgroundColor = bgColor() }
    }
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let label = NSTextField(labelWithString: "")
    private let onToggle: (String, Bool) -> Void

    init(path: String, initiallySelected: Bool, onToggle: @escaping (String, Bool) -> Void) {
        self.path = path
        self.isSelected = initiallySelected
        self.onToggle = onToggle
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = WFDesign.Radius.small
        layer?.backgroundColor = bgColor()

        checkbox.state = initiallySelected ? .on : .off
        checkbox.target = self
        checkbox.action = #selector(toggled)
        checkbox.title = ""
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = path
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = WFDesign.text
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [checkbox, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
        ])

        // Click anywhere on the row toggles — mirrors HTML modal ergonomics
        // where the whole `.ffile` div was clickable, not just the checkbox.
        let tap = NSClickGestureRecognizer(target: self, action: #selector(rowTap))
        addGestureRecognizer(tap)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func bgColor() -> CGColor {
        isSelected
            ? WFDesign.accent.withAlphaComponent(0.14).cgColor
            : NSColor.clear.cgColor
    }

    @objc private func toggled() {
        isSelected = (checkbox.state == .on)
        onToggle(path, isSelected)
    }
    @objc private func rowTap() {
        isSelected.toggle()
        checkbox.state = isSelected ? .on : .off
        onToggle(path, isSelected)
    }
}

