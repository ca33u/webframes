import AppKit

@MainActor final class SimulatorRecordingPreview: NSView {
    var image: SimulatorCapturedImage? { didSet { needsDisplay = true } }
    var enabled = false
    var onAction: ((SimulatorRecordingAction) -> Void)?
    private var pressed: CGPoint?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    var imageRect: CGRect {
        guard let image, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return .init(
            x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width,
            height: size.height)
    }
    func point(for normalized: CGPoint) -> CGPoint {
        .init(
            x: imageRect.minX + normalized.x * imageRect.width,
            y: imageRect.minY + normalized.y * imageRect.height)
    }
    func normalized(_ point: CGPoint) -> CGPoint? {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        return .init(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }
    static func action(from start: CGPoint, to end: CGPoint) -> SimulatorRecordingAction? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        if abs(dy) >= 0.12 && abs(dy) > abs(dx) * 1.3 { return dy < 0 ? .swipeUp : .swipeDown }
        if hypot(dx, dy) < 0.04 { return .tap(end) }
        return nil
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let image, let bitmap = NSImage(data: image.data) else { return }
        bitmap.draw(
            in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
            hints: nil)
    }
    override func mouseDown(with event: NSEvent) {
        pressed = enabled ? normalized(convert(event.locationInWindow, from: nil)) : nil
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard enabled, let pressed, let end = normalized(convert(event.locationInWindow, from: nil)),
            let action = Self.action(from: pressed, to: end)
        else { return }
        onAction?(action)
    }
}

@MainActor final class SimulatorRecordingWindowController: NSWindowController, NSWindowDelegate {
    let session: SimulatorRecordingSession
    let preview = SimulatorRecordingPreview()
    let textInput = NSTextField()
    let sendTextButton = NSButton(title: "Type Text", target: nil, action: nil)
    let useButton = NSButton(title: "Use Recording", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh Screen", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Preparing recorder…")
    private let actions = NSTextView()
    private let complete: (SimulatorCaptureRecipe?) -> Void
    private var task: Task<Void, Never>?
    private var finished = false

    init(
        recipe: SimulatorCaptureRecipe, service: SimulatorCapture = .shared,
        complete: @escaping (SimulatorCaptureRecipe?) -> Void
    ) {
        self.session = .init(recipe: recipe, service: service)
        self.complete = complete
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Record Actions · \(recipe.deviceName)"
        window.minSize = NSSize(width: 640, height: 580)
        super.init(window: window)
        window.delegate = self
        let root = NSView()
        window.contentView = root
        let hint = NSTextField(
            wrappingLabelWithString:
                "Click and swipe the device screen. Tap a field, then enter text below. Use Recording replaces the action list; Cancel keeps it. Actions run on the device now."
        )
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        preview.setAccessibilityLabel("Simulator recording screen")
        preview.setAccessibilityIdentifier("capture.recorder.preview")
        preview.onAction = { [weak self] action in self?.perform(action) }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        actions.isEditable = false
        actions.isSelectable = true
        actions.font = .systemFont(ofSize: 12)
        actions.textContainerInset = NSSize(width: 8, height: 8)
        actions.isVerticallyResizable = true
        actions.isHorizontallyResizable = false
        actions.autoresizingMask = [.width]
        actions.textContainer?.widthTracksTextView = true
        actions.setAccessibilityLabel("Recorded actions")
        scroll.documentView = actions
        textInput.placeholderString = "Text for the selected field (avoid secrets)"
        textInput.setAccessibilityLabel("Text to record")
        textInput.target = self
        textInput.action = #selector(sendText)
        sendTextButton.target = self
        sendTextButton.action = #selector(sendText)
        useButton.target = self
        useButton.action = #selector(useRecording)
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelRecording))
        cancel.keyEquivalent = "\u{1b}"
        let screenRow = NSStackView(views: [preview, scroll])
        screenRow.orientation = .horizontal
        screenRow.spacing = 12
        let textRow = NSStackView(views: [textInput, sendTextButton])
        textRow.orientation = .horizontal
        textRow.spacing = 8
        let spacer = NSView()
        let buttons = NSStackView(views: [refreshButton, spacer, cancel, useButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [hint, screenRow, textRow, status, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.alignment = .leading
        root.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            scroll.widthAnchor.constraint(equalToConstant: 220),
            scroll.heightAnchor.constraint(equalTo: preview.heightAnchor),
            preview.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            screenRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 350),
            textInput.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
        ])
        for view in [hint, screenRow, textRow, status, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        screenRow.setContentHuggingPriority(.defaultLow, for: .vertical)
        preview.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        session.onChange = { [weak self] in self?.render() }
        render()
    }
    required init?(coder: NSCoder) { nil }
    func start(parent: NSWindow? = nil) {
        if let parent, let window { parent.addChildWindow(window, ordered: .above) }
        window?.center()
        showWindow(nil)
        task = Task { [weak self] in
            guard let self else { return }
            do { try await session.start() } catch {
                render()
                status.stringValue = error.localizedDescription
            }
        }
    }
    private func render() {
        preview.image = session.snapshot?.image
        let ready = session.phase == .ready
        preview.enabled = ready
        textInput.isEnabled = ready
        sendTextButton.isEnabled = ready
        refreshButton.isEnabled = ready
        useButton.isEnabled = ready && !session.steps.isEmpty
        status.stringValue = session.status
        actions.string = session.steps.enumerated().map { index, step in
            "\(index+1). \(step.action.title)"
                + (step.action == .type
                    ? " (\(step.value.count) characters)" : (step.value.isEmpty ? "" : " · \(step.value)"))
        }.joined(separator: "\n\n")
    }
    private func perform(_ action: SimulatorRecordingAction) {
        guard session.phase == .ready else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await session.perform(action)
                if case .type = action { textInput.stringValue = "" }
            } catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc private func sendText() { perform(.type(textInput.stringValue)) }
    @objc private func refresh() { perform(.refresh) }
    @objc private func useRecording() {
        guard session.phase == .ready else { return }
        task = Task { [weak self] in
            guard let self else { return }
            do { finish(try await session.finish()) } catch {
                status.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func cancelRecording() { close() }
    private func finish(_ recipe: SimulatorCaptureRecipe?) {
        guard !finished else { return }
        finished = true
        complete(recipe)
        if let window { window.parent?.removeChildWindow(window) }
        close()
    }
    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        session.cancel()
        if !finished {
            finished = true
            complete(nil)
        }
    }
}
