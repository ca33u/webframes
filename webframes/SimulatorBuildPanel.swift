import AppKit

/// Local project selection and narrowly scoped build consent, shared by capture and recording.
@MainActor final class SimulatorBuildPanel: NSStackView, NSTextFieldDelegate {
    private let enabled = NSButton(checkboxWithTitle: "Build and install before capture", target: nil, action: nil)
    private let choose = NSButton(title: "Choose Project…", target: nil, action: nil)
    private let revoke = NSButton(title: "Revoke Build Permission", target: nil, action: nil)
    private let path = NSTextField(wrappingLabelWithString: "No source project selected")
    private let scheme = NSTextField()
    private let configuration = NSTextField()
    private let module = NSTextField()
    private let variant = NSTextField()
    private let bundle = NSTextField()
    private let fields = NSStackView()
    private var project: URL?
    var onChange: (() -> Void)?
    var platform: SimulatorCaptureRecipe.Platform = .iOS {
        didSet {
            if platform != oldValue {
                project = nil
                enabled.state = .off
                scheme.stringValue = ""
                bundle.stringValue = ""
            }
            update()
        }
    }
    var isEnabled: Bool { enabled.state == .on }
    var appID: String { bundle.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    init(recipe: SimulatorCaptureRecipe?) {
        super.init(frame: .zero)
        platform = recipe?.platform ?? .iOS
        project = recipe?.build?.project
        orientation = .vertical
        alignment = .leading
        spacing = 5
        enabled.state = recipe?.build == nil ? .off : .on
        enabled.target = self
        enabled.action = #selector(toggle)
        enabled.setAccessibilityIdentifier("capture.buildEnabled")
        choose.target = self
        choose.action = #selector(chooseProject)
        choose.setAccessibilityIdentifier("capture.buildProject")
        revoke.target = self
        revoke.action = #selector(revokePermission)
        scheme.stringValue = recipe?.build?.scheme ?? ""
        configuration.stringValue = recipe?.build?.configuration ?? "Debug"
        module.stringValue = recipe?.build?.module ?? "app"
        variant.stringValue = recipe?.build?.variant ?? "Debug"
        bundle.stringValue = recipe?.appBundleID ?? ""
        let labels = ["Scheme", "Configuration", "Module", "Variant", "Bundle / Application ID"]
        for (field, label) in zip([scheme, configuration, module, variant, bundle], labels) {
            field.placeholderString = label
            field.setAccessibilityLabel("Build " + label)
            field.delegate = self
            field.toolTip = label
        }
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 5
        let ios = NSStackView(views: [scheme, configuration])
        ios.spacing = 6
        let android = NSStackView(views: [module, variant])
        android.spacing = 6
        fields.addArrangedSubview(ios)
        fields.addArrangedSubview(android)
        fields.addArrangedSubview(bundle)
        let buttons = NSStackView(views: [choose, revoke])
        buttons.spacing = 8
        addArrangedSubview(enabled)
        addArrangedSubview(buttons)
        addArrangedSubview(path)
        addArrangedSubview(fields)
        for view in [path, fields, ios, android, bundle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        scheme.widthAnchor.constraint(equalTo: configuration.widthAnchor).isActive = true
        module.widthAnchor.constraint(equalTo: variant.widthAnchor).isActive = true
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        update()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func settings() throws -> SimulatorAppBuild? {
        guard isEnabled else { return nil }
        guard let project else {
            throw SimulatorCapture.failure("Choose and authorize a source project before building.")
        }
        let result = SimulatorAppBuild(
            projectPath: project.path,
            scheme: scheme.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            configuration: configuration.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            module: module.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            variant: variant.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        try result.validate(platform: platform)
        return result
    }
    func controlTextDidChange(_ obj: Notification) { onChange?() }
    @objc private func toggle() {
        update()
        onChange?()
    }
    private func update() {
        choose.isHidden = !isEnabled
        path.isHidden = !isEnabled
        fields.isHidden = !isEnabled
        fields.arrangedSubviews[0].isHidden = platform != .iOS
        fields.arrangedSubviews[1].isHidden = platform != .android
        revoke.isHidden = !isEnabled || project.map { !SimulatorBuildTrust.isTrusted($0) } != false
        path.stringValue =
            project.map {
                $0.path + (SimulatorBuildTrust.isTrusted($0) ? " · Builds allowed" : " · Build permission required")
            } ?? "No source project selected"
    }
    @objc private func revokePermission() {
        if let project { SimulatorBuildTrust.revoke(project) }
        update()
        onChange?()
    }
    @objc private func chooseProject() {
        guard let window else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = platform == .android
        picker.canChooseFiles = platform == .iOS
        picker.treatsFilePackagesAsDirectories = false
        picker.message =
            platform == .iOS
            ? "Choose the .xcodeproj or .xcworkspace for the simulator app."
            : "Choose the Android project folder containing gradlew."
        picker.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = picker.url else { return }
            Task { @MainActor in
                guard self.platform == .android || ["xcodeproj", "xcworkspace"].contains(url.pathExtension) else {
                    return
                }
                guard await SimulatorBuildTrust.approve(url, window: window) else { return }
                self.project = url.standardizedFileURL.resolvingSymlinksInPath()
                if self.platform == .iOS { self.scheme.stringValue = url.deletingPathExtension().lastPathComponent }
                self.update()
                self.onChange?()
            }
        }
    }
}
