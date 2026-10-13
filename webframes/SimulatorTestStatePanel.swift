import AppKit

@MainActor final class SimulatorTestStatePanel: NSView {
    private let enabled = NSButton(checkboxWithTitle: "Prepare a saved test state", target: nil, action: nil)
    private let name = NSTextField()
    private let account = NSTextField()
    private let ready = NSTextField()
    private let theme = NSPopUpButton()
    private let data = NSTextView()
    private let arguments = NSTextView()
    private let rows = NSStackView()
    private var actions: [StateStepRow] = []
    let record = NSButton(title: "Record Preparation…", target: nil, action: nil)
    var onRecord: (() -> Void)?
    init(state: SimulatorTestState?) {
        super.init(frame: .init(x: 0, y: 0, width: 520, height: 580))
        enabled.state = state == nil ? .off : .on
        enabled.target = self
        enabled.action = #selector(changed)
        enabled.setAccessibilityIdentifier("capture.state.enabled")
        name.stringValue = state?.name ?? ""
        name.placeholderString = "State name · e.g. Recovery — Alice"
        account.stringValue = state?.account ?? ""
        account.placeholderString = "Test account / username (optional)"
        ready.stringValue = state?.readySelector ?? ""
        ready.placeholderString = "Required ready label or accessibility ID"
        for (field, label) in [
            (name, "Test state name"), (account, "Test state account"), (ready, "Test state ready selector"),
        ] {
            field.setAccessibilityLabel(label)
        }
        theme.addItems(withTitles: ["Keep device theme", "Light", "Dark"])
        theme.selectItem(at: SimulatorTestState.Theme.allCases.firstIndex(of: state?.theme ?? .system) ?? 0)
        theme.setAccessibilityLabel("Test state theme")
        let bytes = try? JSONSerialization.data(
            withJSONObject: state?.data ?? [:], options: [.prettyPrinted, .sortedKeys])
        data.string = bytes.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        arguments.string = (state?.launchArguments ?? []).joined(separator: "\n")
        data.setAccessibilityLabel("Test state data JSON")
        arguments.setAccessibilityLabel("Test state launch arguments")
        func editor(_ view: NSTextView, height: CGFloat) -> NSScrollView {
            view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            view.isRichText = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            let scroll = NSScrollView()
            scroll.documentView = view
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.autoresizingMask = [.width]
            view.textContainer?.widthTracksTextView = true
            scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
            return scroll
        }
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 5
        let flow = NSScrollView()
        flow.documentView = rows
        flow.hasVerticalScroller = true
        flow.borderType = .bezelBorder
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.widthAnchor.constraint(equalTo: flow.contentView.widthAnchor).isActive = true
        flow.heightAnchor.constraint(equalToConstant: 110).isActive = true
        record.target = self
        record.action = #selector(recordPreparation)
        record.setAccessibilityIdentifier("capture.state.recordPreparation")
        let add = NSButton(title: "Add preparation action", target: self, action: #selector(addAction))
        let buttons = NSStackView(views: [record, add])
        buttons.spacing = 8
        let hint = NSTextField(
            wrappingLabelWithString:
                "Preparation runs before screen actions. Use {{account}} and {{data.key}} in action values. Data JSON contains string values. Launch arguments use one argument per line (iOS); test context is also passed as WEBFRAMES_TEST_* environment values / Android intent extras. Use test data, not passwords. Device theme is restored when capture or live preview ends."
        )
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [
            enabled, name, account, theme, makeFieldLabel("Test data (JSON object)"), editor(data, height: 70),
            makeFieldLabel("Optional iOS launch arguments"), editor(arguments, height: 42), ready,
            makeFieldLabel("Preparation actions"), flow, buttons, hint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for view in stack.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        for action in state?.preparation ?? [] { append(action) }
        changed()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func settings() throws -> SimulatorTestState? {
        guard enabled.state == .on else { return nil }
        guard let values = try JSONSerialization.jsonObject(with: Data(data.string.utf8)) as? [String: String] else {
            throw SimulatorCapture.failure("Test data must be a JSON object with string values.")
        }
        let state = SimulatorTestState(
            name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            account: account.stringValue, data: values,
            theme: SimulatorTestState.Theme.allCases[theme.indexOfSelectedItem],
            launchArguments: arguments.string.components(separatedBy: .newlines).filter { !$0.isEmpty },
            preparation: actions.map(\.step),
            readySelector: ready.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        try state.validate()
        _ = try state.expand(state.readySelector)
        for action in state.preparation { _ = try state.expand(action.value) }
        for argument in state.launchArguments { _ = try state.expand(argument) }
        return state
    }
    func useRecording(_ steps: [SimulatorCaptureRecipe.Step]) {
        for row in actions {
            rows.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        actions.removeAll()
        for step in steps { append(step) }
    }
    @objc private func changed() { record.isEnabled = enabled.state == .on }
    @objc private func recordPreparation() { onRecord?() }
    @objc private func addAction() { if actions.count < 30 { append(.init(action: .tap, value: "")) } }
    private func append(_ step: SimulatorCaptureRecipe.Step) {
        let row = StateStepRow(step: step)
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            actions.removeAll { $0 === row }
            rows.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        actions.append(row)
        rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }
    private final class StateStepRow: NSStackView {
        private let kind = NSPopUpButton(), value = NSTextField()
        var onRemove: (() -> Void)?
        var step: SimulatorCaptureRecipe.Step {
            .init(
                action: SimulatorCaptureRecipe.Step.Action.allCases[kind.indexOfSelectedItem], value: value.stringValue)
        }
        init(step: SimulatorCaptureRecipe.Step) {
            super.init(frame: .zero)
            orientation = .horizontal
            spacing = 6
            kind.addItems(withTitles: SimulatorCaptureRecipe.Step.Action.allCases.map(\.title))
            kind.selectItem(at: SimulatorCaptureRecipe.Step.Action.allCases.firstIndex(of: step.action) ?? 0)
            kind.setAccessibilityLabel("Preparation action")
            value.setAccessibilityLabel("Preparation action value")
            value.stringValue = step.value
            value.placeholderString = "Label, {{account}} or {{data.key}}"
            let remove = NSButton(title: "−", target: self, action: #selector(removeAction))
            addArrangedSubview(kind)
            addArrangedSubview(value)
            addArrangedSubview(remove)
            kind.widthAnchor.constraint(equalToConstant: 110).isActive = true
            value.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        @objc private func removeAction() { onRemove?() }
    }
}
