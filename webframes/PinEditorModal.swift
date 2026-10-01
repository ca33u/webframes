import AppKit

// MARK: - Data

/// Payload pushed from the canvas JS to open the editor. The canvas keeps
/// the annotations array as the source of truth (same pattern as the
/// annotation panel): it hands the modal a snapshot of what the user
/// clicked, the modal collects edits, and the result comes back through
/// `PinEditorDelegate` as intent envelopes the canvas translates into
/// mutations.
struct PinEditPayload {
    let id: String
    let num: Int
    let color: String                 // "blue" | "red" | "amber" | "green" | "purple"
    let comment: String
    let elementLabel: String          // componentName || tagName || "element"
    let screenshot: NSImage?
    let computedStyles: [String: String]
    let edits: [String: String]
    /// First-time open — the pin was just dropped. Cancel removes it; save
    /// persists it. If false, cancel preserves the pin (user re-opened an
    /// existing annotation).
    let isNew: Bool
    var resolved: Bool = false

    static func parse(_ dict: [String: Any]) -> PinEditPayload? {
        guard let id = dict["id"] as? String else { return nil }
        let num = (dict["num"] as? Int) ?? Int((dict["num"] as? String) ?? "0") ?? 0
        let color = (dict["color"] as? String) ?? "blue"
        let comment = (dict["comment"] as? String) ?? ""
        let elementLabel = (dict["elementLabel"] as? String) ?? "element"
        let styles = stringDict(dict["computedStyles"])
        let edits = stringDict(dict["edits"])
        let isNew = (dict["isNew"] as? Bool) ?? false

        var image: NSImage?
        if let dataURL = dict["screenshot"] as? String,
           let comma = dataURL.firstIndex(of: ","),
           let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) {
            image = NSImage(data: data)
        }

        return PinEditPayload(
            id: id, num: num, color: color, comment: comment,
            elementLabel: elementLabel, screenshot: image,
            computedStyles: styles, edits: edits, isNew: isNew, resolved: dict["resolved"] as? Bool ?? false
        )
    }

    /// JSON values for `computedStyles` / `edits` may arrive as mixed-type
    /// dicts (mostly strings, occasionally numbers). Coerce to a uniform
    /// `[String: String]` so downstream reads don't have to keep branching.
    private static func stringDict(_ v: Any?) -> [String: String] {
        guard let d = v as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, vv) in d {
            if let s = vv as? String { out[k] = s }
            else if let n = vv as? NSNumber { out[k] = "\(n)" }
        }
        return out
    }
}

// MARK: - Delegate

/// Intents the modal sends back to its host. The host (CanvasHost) wraps
/// each call into a `pin-editor-action` envelope that the canvas JS
/// translates into the same mutations the old HTML editor made against
/// the annotations array.
protocol PinEditorDelegate: AnyObject {
    func pinEditorDidSave(id: String, comment: String, color: String,
                          edits: [String: String])
    /// `isNew` propagates from the payload so the canvas knows whether to
    /// drop the pin or just revert its comment/edits.
    func pinEditorDidCancel(id: String, isNew: Bool)
    func pinEditorDidRequestCopy(id: String, comment: String,
                                 edits: [String: String])
    func pinEditorDidSetResolved(id: String, resolved:Bool)
    func pinEditorDidRequestDelete(id: String)
    /// Fired the moment a color swatch is clicked so the pin tint updates
    /// immediately without waiting for save.
    func pinEditorDidChangeColor(id: String, color: String)
}

// MARK: - Modal

/// Native replacement for the HTML `.pin-editor` modal. Sits above every
/// other CanvasHost subview (including the annotation panel) as a full-
/// bounds overlay: backdrop fills the host, the card floats centered.
///
/// Lifecycle:
///   - `present(_ payload:)` — sets working state, renders, animates in
///   - `dismiss()` — removes from superview after fade-out (caller-driven)
///
/// Working state:
///   - `workingComment` — mirrors the Note textarea
///   - `workingColor`   — last swatch clicked
///   - `workingEdits`   — per-key overrides; empty string or equal-to-
///                        -original drops the key (mirrors the old
///                        `commitEdit` semantics)
final class PinEditorModal: NSView {

    weak var delegate: PinEditorDelegate?

    /// The modal must eat every click inside its bounds so annotation-mode
    /// clicks don't leak through to frames below. Default `hitTest` walks
    /// subviews, and any gap between backdrop / card / glass effect can
    /// return nil and let the click fall through. Overriding to always
    /// return `super.hitTest(...) ?? self` guarantees the click stops at
    /// the modal (the `annotation click monitor` gates on
    /// `isModalPresented` and returns the event unconsumed, so without
    /// this catch-all the event reached the frame underneath).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        return super.hitTest(point) ?? (bounds.contains(convert(point, from: superview)) ? self : nil)
    }

    // MARK: Views
    //
    // Built from stock AppKit controls on a glass card: a title bar with
    // icon buttons (resolve, a real NSMenu for Copy/Delete, close), a plain
    // text view with a placeholder, and a footer with color swatches and a
    // push button. No hand-drawn menus, fields or buttons.
    private let backdrop = NSView()
    private let card = WFGlassEffectView()
    private let cardContent = NSView()
    private let headerView = CommentDragHandleView()
    private let headerTitle = NSTextField(labelWithString: "")
    private let resolveBtn = PinEditorModal.iconButton("checkmark.circle", "Mark comment as resolved")
    private let menuBtn = PinEditorModal.iconButton("ellipsis", "More")
    private let closeBtn = PinEditorModal.iconButton("xmark", "Close")

    private let thumbView = NSImageView()
    private let thumbDivider = NSBox()
    private var thumbHeightConstraint: NSLayoutConstraint?

    private let noteScroll = NSScrollView()
    private let noteTextView = AutoResizingTextView()
    private var noteHeightConstraint: NSLayoutConstraint?

    private let footerView = NSView()
    private let colorStack = NSStackView()
    private var colorButtons: [ColorSwatchButton] = []
    private let saveBtn = NSButton(title: "Save", target: nil, action: nil)

    // MARK: State
    private var payload: PinEditPayload?
    private var workingComment: String = ""
    private var workingColor: String = "blue"
    private var workingEdits: [String: String] = [:]
    private var cardCenterXConstraint: NSLayoutConstraint?
    private var cardCenterYConstraint: NSLayoutConstraint?

    private static let padding: CGFloat = 16

    // MARK: Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        buildBackdrop()
        buildCard()
        buildHeader()
        buildThumb()
        buildBody()
        buildFooter()

        alphaValue = 0
        isHidden = true
        setAccessibilityIdentifier("webframes.pinEditorModal")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Public

    /// (Re)populate the modal from `payload` and animate in. Safe to call
    /// while already presented — state is fully reset each time.
    func present(_ payload: PinEditPayload) {
        self.payload = payload
        self.workingComment = payload.comment
        self.workingColor = payload.color
        self.workingEdits = payload.edits

        headerTitle.stringValue = "Comment #\(payload.num)"
        updateResolveButton()
        cardCenterXConstraint?.constant = 0
        cardCenterYConstraint?.constant = 0
        updateColorSelection()
        updateScreenshot(payload.screenshot, forId: payload.id)

        noteTextView.string = workingComment
        refreshSaveState()

        animateIn()
        // Focus the note after one run-loop pass, once the card is visible.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.noteTextView)
        }
    }

    /// Phase 6e Step 6: update the thumbnail for a specific annotation
    /// while the editor is open. The native annotation-click path opens
    /// the editor the moment the `wf-dom-context` reply arrives; the
    /// follow-up `wf-dom-screenshot` reply lands here and populates the
    /// thumb without a re-`present` (which would clobber any working
    /// comment/color/edits the user has already typed).
    ///
    /// `forId` is matched against the currently-presented payload so a
    /// stale screenshot from a previous draft can't overwrite a newer
    /// one the user just opened.
    func updateScreenshot(_ image: NSImage?, forId id: String) {
        guard let payload, payload.id == id else { return }
        thumbView.image = image
        let show = image != nil
        thumbView.isHidden = !show
        thumbDivider.isHidden = !show
        thumbHeightConstraint?.constant = show ? 180 : 0
        self.needsLayout = true
    }

    /// Animate out and remove from superview. The host re-adds the modal
    /// on next open.
    func dismiss(animated: Bool = true) {
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.isHidden = true
                self?.removeFromSuperview()
            })
        } else {
            alphaValue = 0
            isHidden = true
            removeFromSuperview()
        }
    }

    // MARK: Setup

    private func buildBackdrop() {
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // Dim only: a blurred backdrop hid the frames the comment is about.
        let tap = NSClickGestureRecognizer(target: self, action: #selector(backdropClicked))
        backdrop.addGestureRecognizer(tap)
    }

    private func buildCard() {
        card.appearance = NSAppearance(named: .darkAqua)
        // A light grey tint keeps the glass visibly lighter than the dark
        // canvas and dimmed backdrop; the old near-black tint made the card
        // disappear. macOS 15 draws the tint as an opaque surface instead.
        if #available(macOS 26.0, *) {
            card.tintColor = NSColor(calibratedWhite: 0.24, alpha: 0.55)
        } else {
            card.tintColor = NSColor(calibratedWhite: 0.14, alpha: 0.97)
        }
        card.cornerRadius = WFDesign.Radius.large
        card.translatesAutoresizingMaskIntoConstraints = false

        cardContent.translatesAutoresizingMaskIntoConstraints = false
        card.contentView = cardContent

        addSubview(card)
        let centerX = card.centerXAnchor.constraint(equalTo: centerXAnchor)
        let centerY = card.centerYAnchor.constraint(equalTo: centerYAnchor)
        cardCenterXConstraint = centerX
        cardCenterYConstraint = centerY
        NSLayoutConstraint.activate([
            centerX,
            centerY,
            card.widthAnchor.constraint(equalToConstant: 440),
            card.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.92),
        ])
        // Clicks on the card's empty areas must not reach the backdrop.
        let guardView = NSView()
        guardView.translatesAutoresizingMaskIntoConstraints = false
        cardContent.addSubview(guardView, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            guardView.topAnchor.constraint(equalTo: cardContent.topAnchor),
            guardView.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor),
            guardView.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            guardView.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
        ])
    }

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
        b.widthAnchor.constraint(equalToConstant: 28).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    private func buildHeader() {
        headerView.translatesAutoresizingMaskIntoConstraints = false
        cardContent.addSubview(headerView)

        headerTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        headerTitle.textColor = .labelColor
        headerTitle.maximumNumberOfLines = 1
        headerTitle.lineBreakMode = .byTruncatingTail
        headerTitle.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(headerTitle)

        resolveBtn.target = self
        resolveBtn.action = #selector(resolveClicked)
        resolveBtn.setAccessibilityIdentifier("commentStatus")
        menuBtn.target = self
        menuBtn.action = #selector(menuClicked(_:))
        closeBtn.target = self
        closeBtn.action = #selector(cancelClicked)

        let buttons = NSStackView(views: [resolveBtn, menuBtn, closeBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 2
        buttons.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(buttons)

        headerView.onDrag = { [weak self] delta in
            self?.moveCard(by: delta)
        }

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: cardContent.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 44),

            headerTitle.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: Self.padding),
            headerTitle.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            headerTitle.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -8),

            buttons.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -10),
            buttons.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
        ])
    }

    private func buildThumb() {
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        cardContent.addSubview(thumbView)

        thumbDivider.boxType = .separator
        thumbDivider.translatesAutoresizingMaskIntoConstraints = false
        cardContent.addSubview(thumbDivider)

        let topDivider = NSBox()
        topDivider.boxType = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        cardContent.addSubview(topDivider)

        let heightConstraint = thumbView.heightAnchor.constraint(equalToConstant: 180)
        thumbHeightConstraint = heightConstraint
        NSLayoutConstraint.activate([
            topDivider.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),

            thumbView.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            thumbView.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            thumbView.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
            heightConstraint,

            thumbDivider.topAnchor.constraint(equalTo: thumbView.bottomAnchor),
            thumbDivider.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            thumbDivider.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
        ])
    }

    private func buildBody() {
        noteScroll.translatesAutoresizingMaskIntoConstraints = false
        noteScroll.hasVerticalScroller = true
        noteScroll.scrollerStyle = .overlay
        noteScroll.borderType = .noBorder
        noteScroll.drawsBackground = false
        cardContent.addSubview(noteScroll)

        noteTextView.setAccessibilityLabel("Comment")
        noteTextView.setAccessibilityIdentifier("commentText")
        noteTextView.isRichText = false
        noteTextView.isEditable = true
        noteTextView.isSelectable = true
        noteTextView.allowsUndo = true
        noteTextView.drawsBackground = false
        noteTextView.font = .systemFont(ofSize: 13)
        noteTextView.textColor = .labelColor
        noteTextView.insertionPointColor = WFDesign.accent
        noteTextView.textContainerInset = NSSize(width: Self.padding - 5, height: 12)
        noteTextView.autoresizingMask = [.width]
        noteTextView.isVerticallyResizable = true
        noteTextView.isHorizontallyResizable = false
        noteTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        noteTextView.textContainer?.widthTracksTextView = true
        noteTextView.setPlaceholder("Add a comment")
        noteTextView.editorDelegate = self
        noteScroll.documentView = noteTextView

        let noteHeight = noteScroll.heightAnchor.constraint(equalToConstant: 96)
        noteHeightConstraint = noteHeight
        NSLayoutConstraint.activate([
            noteScroll.topAnchor.constraint(equalTo: thumbDivider.bottomAnchor),
            noteScroll.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            noteScroll.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
            noteHeight,
        ])
    }

    private func buildFooter() {
        footerView.translatesAutoresizingMaskIntoConstraints = false
        cardContent.addSubview(footerView)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(divider)

        colorStack.orientation = .horizontal
        colorStack.spacing = 6
        colorStack.alignment = .centerY
        colorStack.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(colorStack)
        for (key, label) in [("blue", "Blue"), ("red", "Red"), ("amber", "Yellow"), ("green", "Green"), ("purple", "Purple"), ("orange", "Orange")] {
            let b = ColorSwatchButton(color: PinColor.resolve(key))
            b.identifier = NSUserInterfaceItemIdentifier(key)
            b.setAccessibilityLabel("Comment color: " + label)
            b.setAccessibilityIdentifier("commentColor." + key)
            b.toolTip = label
            b.target = self
            b.action = #selector(colorSelected(_:))
            colorButtons.append(b)
            colorStack.addArrangedSubview(b)
        }

        saveBtn.bezelStyle = .push
        saveBtn.controlSize = .large
        saveBtn.bezelColor = WFDesign.accent
        saveBtn.keyEquivalent = "\r"
        saveBtn.keyEquivalentModifierMask = [.command]
        saveBtn.toolTip = "Save comment (⌘Return)"
        saveBtn.setAccessibilityLabel("Save comment")
        saveBtn.setAccessibilityIdentifier("commentSave")
        saveBtn.target = self
        saveBtn.action = #selector(saveClicked)
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        footerView.addSubview(saveBtn)

        NSLayoutConstraint.activate([
            footerView.topAnchor.constraint(equalTo: noteScroll.bottomAnchor),
            footerView.leadingAnchor.constraint(equalTo: cardContent.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: cardContent.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: cardContent.bottomAnchor),
            footerView.heightAnchor.constraint(equalToConstant: 56),

            divider.topAnchor.constraint(equalTo: footerView.topAnchor),
            divider.leadingAnchor.constraint(equalTo: footerView.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: footerView.trailingAnchor),

            colorStack.leadingAnchor.constraint(equalTo: footerView.leadingAnchor, constant: Self.padding - 2),
            colorStack.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
            saveBtn.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -Self.padding + 4),
            saveBtn.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
            colorStack.trailingAnchor.constraint(lessThanOrEqualTo: saveBtn.leadingAnchor, constant: -16),
        ])
    }

    // MARK: Save / Cancel logic

    private func refreshSaveState() {
        let filled = !workingComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        saveBtn.isEnabled = filled || payload?.isNew == false
        let width = 440 - 2 * Self.padding
        let textBounds = (workingComment as NSString).boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 13)])
        noteHeightConstraint?.constant = min(260, max(96, ceil(textBounds.height) + 28))
    }

    private func updateResolveButton() {
        let resolved = payload?.resolved ?? false
        resolveBtn.image = NSImage(systemSymbolName: resolved ? "checkmark.circle.fill" : "checkmark.circle",
                                   accessibilityDescription: resolved ? "Reopen" : "Resolve")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        resolveBtn.contentTintColor = resolved ? .systemGreen : .secondaryLabelColor
        resolveBtn.toolTip = resolved ? "Reopen comment" : "Mark comment as resolved"
        resolveBtn.setAccessibilityLabel(resolved ? "Reopen comment" : "Mark comment as resolved")
    }

    // MARK: Actions

    @objc private func backdropClicked() { doCancel() }

    @objc private func cancelClicked() { doCancel() }

    @objc private func saveClicked() {
        guard let p = payload, saveBtn.isEnabled else { return }
        delegate?.pinEditorDidSave(
            id: p.id,
            comment: workingComment,
            color: workingColor,
            edits: workingEdits
        )
        dismiss()
    }

    @objc private func menuClicked(_ sender: NSButton) {
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: "Copy", action: #selector(menuCopyClicked), keyEquivalent: "")
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copy.target = self
        menu.addItem(.separator())
        let delete = menu.addItem(withTitle: "Delete", action: #selector(menuDeleteClicked), keyEquivalent: "")
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        delete.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func menuCopyClicked() {
        guard let p = payload else { return }
        delegate?.pinEditorDidRequestCopy(
            id: p.id, comment: workingComment, edits: workingEdits)
    }

    @objc private func menuDeleteClicked() {
        guard let p = payload else { return }
        delegate?.pinEditorDidRequestDelete(id: p.id)
        dismiss()
    }

    @objc private func resolveClicked() {
        guard var p = payload else { return }
        p.resolved.toggle()
        payload = p
        delegate?.pinEditorDidSetResolved(id: p.id, resolved: p.resolved)
        updateResolveButton()
    }

    private func moveCard(by delta: NSPoint) {
        guard let centerX = cardCenterXConstraint,
              let centerY = cardCenterYConstraint else { return }
        centerX.constant += delta.x
        centerY.constant += delta.y
        layoutSubtreeIfNeeded()

        let inset: CGFloat = 16
        let horizontalLimit = max(0, (bounds.width - card.frame.width) / 2 - inset)
        let verticalLimit = max(0, (bounds.height - card.frame.height) / 2 - inset)
        centerX.constant = min(horizontalLimit, max(-horizontalLimit, centerX.constant))
        centerY.constant = min(verticalLimit, max(-verticalLimit, centerY.constant))
    }

    private func updateColorSelection() {
        for b in colorButtons { b.isSelected = b.identifier?.rawValue == workingColor }
    }

    @objc private func colorSelected(_ sender: NSButton) {
        guard let p = payload, let color = sender.identifier?.rawValue else { return }
        workingColor = color
        updateColorSelection()
        delegate?.pinEditorDidChangeColor(id: p.id, color: color)
    }

    private func doCancel() {
        guard let p = payload else { dismiss(); return }
        delegate?.pinEditorDidCancel(id: p.id, isNew: p.isNew)
        dismiss()
    }

    // MARK: Animation

    private func animateIn() {
        isHidden = false
        alphaValue = 0
        card.layer?.transform = CATransform3DMakeScale(0.98, 0.98, 1)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().alphaValue = 1
            self.card.layer?.transform = CATransform3DIdentity
        }
    }

    // MARK: Keyboard shortcuts

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Escape → cancel. ⌘Return is the Save button's key equivalent.
        if event.keyCode == 53 {
            doCancel()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Round color swatch; the selected one gets a ring with a gap, like the
/// accent color choice in System Settings.
final class ColorSwatchButton: NSButton {
    private let color: NSColor
    var isSelected = false { didSet { needsDisplay = true; setAccessibilityValue(isSelected ? "selected" : nil) } }

    init(color: NSColor) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let dot = bounds.insetBy(dx: 4, dy: 4)
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()
        NSColor.black.withAlphaComponent(0.15).setStroke()
        let edge = NSBezierPath(ovalIn: dot.insetBy(dx: 0.25, dy: 0.25))
        edge.lineWidth = 0.5
        edge.stroke()
        if isSelected {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 1.5
            NSColor.labelColor.withAlphaComponent(0.85).setStroke()
            ring.stroke()
        }
    }
}

// MARK: - AutoResizingTextView (NSTextView with a binding-key + delegate dispatch)

/// NSTextView subclass that carries a `bindingKey` identifying which edit
/// key it writes to. The outer modal is registered as `editorDelegate` so
/// every keystroke routes through one place (`textDidChange`) — cleaner
/// than wiring per-view delegate methods.
protocol AutoResizingTextViewDelegate: AnyObject {
    func textViewDidChange(_ view: AutoResizingTextView, key: String?)
}

final class AutoResizingTextView: NSTextView {
    var bindingKey: String?
    weak var editorDelegate: AutoResizingTextViewDelegate?
    private var placeholder: NSAttributedString?

    /// Grey hint shown while the text is empty (NSTextView has no public
    /// placeholder API).
    func setPlaceholder(_ text: String) {
        placeholder = NSAttributedString(string: text, attributes: [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ])
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, let placeholder else { return }
        let padding = textContainer?.lineFragmentPadding ?? 5
        placeholder.draw(at: NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height))
    }

    override func didChangeText() {
        super.didChangeText()
        if placeholder != nil { needsDisplay = true }
        editorDelegate?.textViewDidChange(self, key: bindingKey)
    }
}

extension PinEditorModal: AutoResizingTextViewDelegate {
    func textViewDidChange(_ view: AutoResizingTextView, key: String?) {
        if view === noteTextView {
            workingComment = view.string
            refreshSaveState()
            return
        }
    }
}

/// Drag surface for the comment card. Buttons in the header keep their
/// normal hit targets; dragging the empty title area moves the card.
final class CommentDragHandleView: NSView {
    var onDrag: ((NSPoint) -> Void)?
    private var lastWindowPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        lastWindowPoint = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let previous = lastWindowPoint else { return }
        let current = event.locationInWindow
        onDrag?(NSPoint(x: current.x - previous.x, y: current.y - previous.y))
        lastWindowPoint = current
    }

    override func mouseUp(with event: NSEvent) {
        lastWindowPoint = nil
    }
}
