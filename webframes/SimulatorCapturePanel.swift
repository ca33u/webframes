import AppKit

/// Native form shared by Add Image and an existing image's capture settings.
final class SimulatorCapturePanel: NSView {
    private let buildPanel: SimulatorBuildPanel
    private var testState: SimulatorTestState?
    private let stateButton = NSButton(title: "Test State…", target: nil, action: nil)
    private let stateSummary = NSTextField(wrappingLabelWithString: "Existing app state")
    private let devicePopup = NSPopUpButton()
    private let platformPopup = NSPopUpButton()
    private let sdkButton = NSButton(title: "Choose Android SDK…", target: nil, action: nil)
    private let appPopup = NSPopUpButton()
    private let startDevice = NSButton(title: "Start Simulator", target: nil, action: nil)
    private let recordButton = NSButton(title: "Record Actions…", target: nil, action: nil)
    private(set) var recordingWindow: SimulatorRecordingWindowController?
    private let restart = NSButton(checkboxWithTitle: "Restart app before each capture", target: nil, action: nil)
    private let link = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "Finding devices…")
    private let rows = NSStackView()
    private var steps: [StepRow] = []
    private var devices: [SimulatorCapture.Device] = []
    private var apps: [SimulatorCapture.App] = []
    private let saved: SimulatorCaptureRecipe?
    private var discovery: Task<Void, Never>?
    private var loading = true
    var onValidityChange: ((Bool) -> Void)?

    init(recipe: SimulatorCaptureRecipe?) {
        saved = recipe
        testState = recipe?.testState
        buildPanel = SimulatorBuildPanel(recipe: recipe)
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 660))
        buildPanel.onChange = { [weak self] in
            guard let self else { return }; appChanged(); onValidityChange?((try? self.recipe()) != nil)
        }
        stateButton.target = self; stateButton.action = #selector(editTestState)
        stateButton.setAccessibilityIdentifier("capture.testState")
        stateSummary.font = .systemFont(ofSize: 11); stateSummary.textColor = .secondaryLabelColor
        stateSummary.stringValue = testState.map { "State: " + $0.name } ?? "Existing app state"
        stateSummary.lineBreakMode = .byTruncatingTail
        stateSummary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stateRow = NSStackView(views: [stateButton, stateSummary]); stateRow.spacing = 8
        devicePopup.setAccessibilityLabel("Capture simulator")
        appPopup.setAccessibilityLabel("Capture app")
        platformPopup.addItems(withTitles: ["iOS Simulator", "Android Emulator"])
        platformPopup.selectItem(at: recipe?.platform == .android ? 1 : 0)
        platformPopup.setAccessibilityLabel("Capture platform")
        platformPopup.target = self; platformPopup.action = #selector(platformChanged)
        sdkButton.target = self; sdkButton.action = #selector(chooseSDK)
        sdkButton.isHidden = platform != .android
        link.placeholderString = "Optional: myapp://screen"
        link.stringValue = recipe?.deeplink ?? ""
        link.setAccessibilityLabel("Capture deeplink")
        restart.state = recipe?.restartApp == true ? .on : .off
        devicePopup.target = self; devicePopup.action = #selector(deviceChanged)
        startDevice.target = self; startDevice.action = #selector(bootSelectedDevice)
        startDevice.isHidden = true
        appPopup.target = self; appPopup.action = #selector(appChanged)
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 6
        let add = NSButton(title: "Add action", target: self, action: #selector(addStep))
        recordButton.target = self; recordButton.action = #selector(recordActions)
        recordButton.isEnabled = false
        recordButton.setAccessibilityIdentifier("capture.recordActions")
        let actionButtons = NSStackView(views: [recordButton, add]); actionButtons.spacing = 8
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let content = NSView()
        scroll.documentView = content
        content.translatesAutoresizingMaskIntoConstraints = false
        rows.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rows)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            rows.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -6),
            rows.topAnchor.constraint(equalTo: content.topAnchor, constant: 6),
            rows.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        let hint = NSTextField(wrappingLabelWithString: "Capture the current screen, or choose an app and add actions by label / accessibility or resource id. iOS needs Xcode; Android needs Android SDK and a JDK (included with Android Studio). No account or external service.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [platformPopup, sdkButton, makeFieldLabel("Device"), devicePopup, startDevice, makeFieldLabel("App"), appPopup,
            buildPanel, stateRow, restart, link, makeFieldLabel("Screen actions (in order)"), scroll, actionButtons, status, hint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 130),
        ])
        for view in [platformPopup, devicePopup, appPopup, buildPanel, stateRow, link, scroll, status, hint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        for step in recipe?.steps ?? [] { appendStep(step) }
        discoverDevices()
    }
    private var platform: SimulatorCaptureRecipe.Platform { platformPopup.indexOfSelectedItem == 1 ? .android : .iOS }
    @objc private func platformChanged() { sdkButton.isHidden = platform != .android; buildPanel.platform = platform; discoverDevices() }
    private func discoverDevices() {
        discovery?.cancel(); loading = true; onValidityChange?(false)
        devicePopup.removeAllItems(); appPopup.removeAllItems()
        let selectedPlatform = platform
        discovery = Task { [weak self] in
            guard let self else { return }
            do {
                devices = try await SimulatorCapture.shared.devices(platform: selectedPlatform)
                try Task.checkCancellation()
                devicePopup.removeAllItems()
                for device in devices { devicePopup.addItem(withTitle: device.name + " · " + device.runtime + (device.booted ? " · Running" : "")) }
                if let saved, saved.platform == selectedPlatform, let i = devices.firstIndex(where: { $0.id == saved.deviceID }) { devicePopup.selectItem(at: i) }
                if let saved, saved.platform == selectedPlatform, !devices.contains(where: { $0.id == saved.deviceID }) {
                    status.stringValue = "Saved simulator is unavailable. Choose a replacement."
                    devicePopup.select(nil); loading = false; onValidityChange?(false); return
                }
                await loadApps()
            } catch is CancellationError { } catch { show(error) }
        }
    }
    @objc private func chooseSDK() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose the Android SDK folder containing platform-tools/adb."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard FileManager.default.isExecutableFile(atPath: url.appendingPathComponent("platform-tools/adb").path) else {
                self?.show(SimulatorCapture.failure("This folder does not contain platform-tools/adb.")); return
            }
            UserDefaults.standard.set(url.path, forKey: AndroidEmulatorCapture.sdkPreference)
            self?.discoverDevices()
        }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func cancelDiscovery() { discovery?.cancel(); recordingWindow?.close() }

    func recipe(ignoringActions: Bool = false) throws -> SimulatorCaptureRecipe {
        guard !loading, devices.indices.contains(devicePopup.indexOfSelectedItem) else { throw SimulatorCapture.failure("Choose an available simulator.") }
        let device = devices[devicePopup.indexOfSelectedItem]
        guard buildPanel.isEnabled || appPopup.indexOfSelectedItem >= 0 else { throw SimulatorCapture.failure("Choose an installed app or Current screen.") }
        let index = appPopup.indexOfSelectedItem - 1
        let bundle = buildPanel.isEnabled ? buildPanel.appID : (apps.indices.contains(index) ? apps[index].id : "")
        let deeplink = link.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let recipe = SimulatorCaptureRecipe(deviceID: device.id, deviceName: device.name, appBundleID: bundle,
            restartApp: !bundle.isEmpty && restart.state == .on, deeplink: deeplink.isEmpty ? nil : deeplink,
            steps: ignoringActions ? [] : steps.map { $0.step }, platform: platform, build: try buildPanel.settings(), testState: testState)
        try recipe.validate()
        return recipe
    }
    @objc private func editTestState() {
        guard let window else { return }
        let editor = SimulatorTestStatePanel(state: testState), alert = NSAlert()
        alert.messageText = "Test State"; alert.informativeText = "Prepare account, data and appearance before opening this screen."
        alert.accessoryView = editor; alert.addButton(withTitle: "Use State"); alert.addButton(withTitle: "Cancel")
        editor.onRecord = { [weak self, weak editor, weak alert] in
            guard let self, let editor, let alert, self.recordingWindow == nil else { return }
            do {
                var base = try self.recipe(ignoringActions: true); base.testState = nil; base.deeplink = nil; base.restartApp = true
                alert.buttons.forEach { $0.isEnabled = false }; editor.record.isEnabled = false
                let recorder = SimulatorRecordingWindowController(recipe: base) { [weak self, weak editor, weak alert] recorded in
                    self?.recordingWindow = nil
                    if let recorded { editor?.useRecording(recorded.steps) }
                    editor?.record.isEnabled = true; alert?.buttons.forEach { $0.isEnabled = true }
                }
                self.recordingWindow = recorder; recorder.start(parent: alert.window)
            } catch { SimulatorCaptureUI.presentError(error, window: alert.window) }
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            do {
                self.testState = try editor.settings()
                self.stateSummary.stringValue = self.testState.map { "State: " + $0.name } ?? "Existing app state"
                self.onValidityChange?((try? self.recipe()) != nil); self.appChanged()
            } catch { SimulatorCaptureUI.presentError(error, window: window) }
        }
    }

    @objc private func deviceChanged() {
        discovery?.cancel()
        discovery = Task { [weak self] in await self?.loadApps() }
    }
    private func loadApps() async {
        guard devices.indices.contains(devicePopup.indexOfSelectedItem) else { show(SimulatorCapture.failure(platform == .android ? "No Android emulators found. Create an AVD in Android Studio." : "No iOS simulators found. Create one in Xcode.")); return }
        loading = true; onValidityChange?(false); appPopup.isEnabled = false
        appPopup.removeAllItems(); appPopup.addItem(withTitle: "Current screen (no app actions)")
        apps = []
        let device = devices[devicePopup.indexOfSelectedItem]
        startDevice.isHidden = device.booted
        startDevice.isEnabled = !device.booted
        do {
            // Listing apps requires a booted simulator. A cold device still supports current-screen capture.
            if device.booted { apps = try await SimulatorCapture.shared.apps(deviceID: device.id, platform: device.platform) }
            try Task.checkCancellation()
            for app in apps { appPopup.addItem(withTitle: "\(app.name) · \(app.id)") }
            if let saved, saved.platform == platform, let i = apps.firstIndex(where: { $0.id == saved.appBundleID }) { appPopup.selectItem(at: i + 1) }
            loading = false; appPopup.isEnabled = true
            status.stringValue = device.booted ? "Ready. Your frame keeps its size, comments and links." : "Start this simulator to choose an app, or capture its current screen."
            if !buildPanel.isEnabled, let saved, saved.platform == platform, !saved.appBundleID.isEmpty, saved.deviceID == device.id,
               !apps.contains(where: { $0.id == saved.appBundleID }) {
                appPopup.select(nil)
                status.stringValue = device.booted ? "Saved app is not installed. Choose another app, or Current screen." : "Start this simulator to restore the saved app recipe."
            }
            if buildPanel.isEnabled { status.stringValue = "Ready. The source app will be built and installed before capture." }
            onValidityChange?(true); appChanged()
        } catch is CancellationError { } catch { show(error) }
    }
    @objc private func bootSelectedDevice() {
        guard devices.indices.contains(devicePopup.indexOfSelectedItem) else { return }
        let id = devices[devicePopup.indexOfSelectedItem].id
        let selectedPlatform = platform
        startDevice.isEnabled = false; status.stringValue = "Starting simulator…"
        loading = true; onValidityChange?(false)
        discovery?.cancel()
        discovery = Task { [weak self] in
            guard let self else { return }
            do {
                try await SimulatorCapture.shared.startDevice(id: id, platform: selectedPlatform)
                devices = try await SimulatorCapture.shared.devices(platform: selectedPlatform)
                devicePopup.removeAllItems()
                for device in devices { devicePopup.addItem(withTitle: device.name + " · " + device.runtime + (device.booted ? " · Running" : "")) }
                if let index = devices.firstIndex(where: { $0.id == id }) { devicePopup.selectItem(at: index) }
                await loadApps()
            } catch is CancellationError { } catch { show(error) }
        }
    }
    private func show(_ error: Error) { loading = true; status.stringValue = error.localizedDescription; onValidityChange?(false) }
    @objc private func appChanged() {
        appPopup.isEnabled = !loading && !buildPanel.isEnabled
        restart.isEnabled = buildPanel.isEnabled || appPopup.indexOfSelectedItem > 0
        recordButton.isEnabled = !loading && (buildPanel.isEnabled || appPopup.indexOfSelectedItem > 0) && recordingWindow == nil && (try? recipe(ignoringActions: true)) != nil
    }
    @objc private func recordActions() {
        guard recordingWindow == nil else { return }
        do {
            let recipe = try recipe(ignoringActions: true)
            guard !recipe.appBundleID.isEmpty else { throw SimulatorCapture.failure("Choose an installed app before recording.") }
            func enabled(_ view: NSView, _ value: Bool) {
                (view as? NSControl)?.isEnabled = value
                for child in view.subviews { enabled(child, value) }
            }
            enabled(self, false); onValidityChange?(false)
            let recorder = SimulatorRecordingWindowController(recipe: recipe) { [weak self] recorded in
                guard let self else { return }
                if let recorded {
                    for row in steps { row.removeFromSuperview() }
                    steps.removeAll()
                    for step in recorded.steps { appendStep(step) }
                }
                recordingWindow = nil; enabled(self, true); appChanged()
                onValidityChange?((try? self.recipe()) != nil)
            }
            recordingWindow = recorder; recorder.start(parent: window)
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func addStep() {
        guard steps.count < 30 else { return }
        appendStep(.init(action: .tap, value: ""))
    }
    private func appendStep(_ step: SimulatorCaptureRecipe.Step) {
        let row = StepRow(step: step)
        row.onRemove = { [weak self, weak row] in
            guard let self, let row else { return }
            steps.removeAll { $0 === row }; row.removeFromSuperview()
        }
        steps.append(row); rows.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }
    private final class StepRow: NSStackView {
        private let actionPopup = NSPopUpButton()
        private let value = NSTextField()
        var onRemove: (() -> Void)?
        var step: SimulatorCaptureRecipe.Step {
            .init(action: SimulatorCaptureRecipe.Step.Action.allCases[actionPopup.indexOfSelectedItem], value: value.stringValue)
        }
        init(step: SimulatorCaptureRecipe.Step) {
            super.init(frame: .zero)
            orientation = .horizontal; spacing = 6
            for action in SimulatorCaptureRecipe.Step.Action.allCases { actionPopup.addItem(withTitle: action.title) }
            actionPopup.selectItem(at: SimulatorCaptureRecipe.Step.Action.allCases.firstIndex(of: step.action) ?? 0)
            actionPopup.setAccessibilityLabel("Screen action")
            value.stringValue = step.value; value.placeholderString = "Label or accessibility identifier"
            value.setAccessibilityLabel("Screen action value")
            let remove = NSButton(title: "−", target: self, action: #selector(removeRow))
            remove.setAccessibilityLabel("Remove screen action")
            addArrangedSubview(actionPopup); addArrangedSubview(value); addArrangedSubview(remove)
            actionPopup.widthAnchor.constraint(equalToConstant: 110).isActive = true
            value.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        @objc private func removeRow() { onRemove?() }
    }
}

enum SimulatorCaptureUI {
    static func settings(window: NSWindow, recipe: SimulatorCaptureRecipe?, save: @escaping (SimulatorCaptureRecipe) -> Void,
                         allowSaveOnly: Bool = true, capture: @escaping (SimulatorCaptureRecipe) -> Void) {
        let editor = SimulatorCapturePanel(recipe: recipe)
        let alert = NSAlert()
        alert.messageText = "Simulator Capture"
        alert.informativeText = "Save a screen recipe and refresh this frame whenever the app changes."
        alert.accessoryView = editor
        alert.addButton(withTitle: "Capture")
        if allowSaveOnly { alert.addButton(withTitle: "Save Recipe") }
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].isEnabled = false
        if allowSaveOnly { alert.buttons[1].isEnabled = false }
        editor.onValidityChange = { valid in
            alert.buttons[0].isEnabled = valid
            if allowSaveOnly { alert.buttons[1].isEnabled = valid }
        }
        alert.beginSheetModal(for: window) { response in
            editor.cancelDiscovery()
            guard response == .alertFirstButtonReturn || (allowSaveOnly && response == .alertSecondButtonReturn) else { return }
            do {
                let recipe = try editor.recipe()
                save(recipe)
                if response == .alertFirstButtonReturn { capture(recipe) }
            } catch { presentError(error, window: window) }
        }
    }

    static func run(window: NSWindow, recipe: SimulatorCaptureRecipe,
                    complete: @escaping (SimulatorCapturedImage) throws -> Void) {
        let alert = NSAlert()
        alert.messageText = "Capturing \(recipe.deviceName)…"
        alert.informativeText = "Preparing simulator…"
        alert.addButton(withTitle: "Cancel")
        let spinner = NSProgressIndicator()
        spinner.style = .spinning; spinner.startAnimation(nil)
        spinner.frame = NSRect(x: 0, y: 0, width: 24, height: 24); alert.accessoryView = spinner
        var task: Task<Void, Never>?
        alert.beginSheetModal(for: window) { response in if response == .alertFirstButtonReturn { task?.cancel() } }
        task = Task {
            do {
                await SimulatorLivePreview.shared.stopCurrentAndWait()
                let image = try await SimulatorCapture.shared.capture(recipe) { alert.informativeText = $0 }
                try Task.checkCancellation()
                try complete(image)
                window.endSheet(alert.window, returnCode: .stop)
            } catch is CancellationError {
                if alert.window.sheetParent != nil { window.endSheet(alert.window, returnCode: .stop) }
            } catch {
                window.endSheet(alert.window, returnCode: .stop)
                presentError(error, window: window)
            }
        }
    }
    static func presentError(_ error: Error, window: NSWindow) {
        let alert = NSAlert(error: error)
        alert.beginSheetModal(for: window)
    }
}
