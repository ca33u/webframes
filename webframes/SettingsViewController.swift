import AppKit
import UniformTypeIdentifiers

@MainActor final class SettingsViewController: NSViewController {
    private let codexStatus = NSTextField(wrappingLabelWithString: "")
    private let claudeStatus = NSTextField(wrappingLabelWithString: "")
    private var resolveCommentsToggle: NSButton?
    private var codexButtons: [NSButton] = []
    private var keyCards: [ProviderKeyCard] = []
    private var task: Task<Void, Never>?
    private let trustedList = NSStackView()
    private let evidenceStatus = NSTextField(wrappingLabelWithString: "")
    private var revokeAllButton: NSButton?

    init() {
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshCodex), name: CodexConnectionStore.changed, object: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = WFDesign.bg.cgColor
        view.setAccessibilityIdentifier("webframes.settings")
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let document = SettingsFlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        let content = NSStackView(); content.orientation = .vertical; content.alignment = .leading; content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(content)
        let preferred = content.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -48); preferred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: document.topAnchor, constant: 26),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -32),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 780), preferred,
        ])
        let title = SettingsUI.label("Settings", size: 25, weight: .semibold, color: WFDesign.text)
        let subtitle = SettingsUI.label("App-wide connections on this Mac, shared by all your projects.", size: 12)
        content.addArrangedSubview(title); content.addArrangedSubview(subtitle)
        content.setCustomSpacing(24, after: subtitle)
        func add(_ element: NSView) { content.addArrangedSubview(element); element.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        add(SettingsUI.label("CONNECTED TOOLS", size: 10, weight: .semibold))
        let github = ProviderKeyCard(provider: .github); keyCards.append(github); add(github)
        add(makeCodexCard()); add(makeClaudeCard())
        // OpenAI / Anthropic / Gemini key cards are hidden until a feature
        // uses those keys; ConnectionSettings keeps their storage intact.
        add(SettingsUI.label("Tokens stay in macOS Keychain and are excluded from project files.", size: 11))
        let privacyTitle = SettingsUI.label("PROJECT FOLDERS", size: 10, weight: .semibold)
        add(privacyTitle); content.setCustomSpacing(22, after: content.arrangedSubviews[content.arrangedSubviews.count - 2])
        add(makeTrustCard())
        add(makeEvidenceCard())
        refreshCodex()
    }
    func refresh() {
        _ = view
        keyCards.forEach { $0.refreshPresence() }; refreshCodex(); reloadTrustedFolders(); refreshEvidence()
        resolveCommentsToggle?.state = CommentsMCPInbox.isAllowed ? .on : .off
        if let reason = CommentsMCPInbox.unavailableReason {
            claudeStatus.stringValue = "MCP inbox unavailable: " + reason
            claudeStatus.textColor = .systemOrange
        }
    }
    func clearInputs() { keyCards.forEach { $0.clearInput() } }
    private func makeEvidenceCard() -> NSView {
        let card = SettingsUI.card("Local evidence", subtitle: "Compare and Fix with \(AgentProvider.current.name) keep screenshots, page structure and source before/after on this Mac for review and manual recovery. The 20 most recent runs are kept, none older than 30 days.", symbol: "internaldrive")
        evidenceStatus.font = .systemFont(ofSize: 11); evidenceStatus.textColor = WFDesign.text2
        card.addRow(evidenceStatus)
        card.addRow(NSStackView(views: [SettingsUI.button("Clear Evidence", target: self, action: #selector(clearEvidence), id: "settings.evidence.clear")]))
        refreshEvidence()
        return card
    }
    private func refreshEvidence() {
        let bytes = EvidenceStore.diskUsage()
        evidenceStatus.stringValue = "Using " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " on disk."
    }
    @objc private func clearEvidence() {
        EvidenceStore.clearAll(excludingConnector: CodexConnectorProcess.shared.runDirectory)
        refreshEvidence()
    }
    private func makeTrustCard() -> NSView {
        let card = SettingsUI.card("Trusted folders", subtitle: "Web Frames asks once per project folder before running its dev server, building Library previews or sending its sources to \(AgentProvider.current.name). Revoke a folder to be asked again.", symbol: "checkmark.shield")
        trustedList.orientation = .vertical; trustedList.alignment = .leading; trustedList.spacing = 6
        card.addRow(trustedList)
        let revokeAll = SettingsUI.button("Revoke All", target: self, action: #selector(revokeAllFolders), id: "settings.trust.revokeAll")
        revokeAllButton = revokeAll
        card.addRow(NSStackView(views: [revokeAll]))
        reloadTrustedFolders()
        return card
    }
    private func reloadTrustedFolders() {
        trustedList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let folders = ProjectTrust.trustedFolders
        revokeAllButton?.isEnabled = !folders.isEmpty
        guard !folders.isEmpty else {
            trustedList.addArrangedSubview(SettingsUI.label("No folders approved yet.", size: 11))
            return
        }
        for path in folders {
            let label = NSTextField(labelWithString: (path as NSString).abbreviatingWithTildeInPath)
            label.font = .systemFont(ofSize: 12); label.textColor = WFDesign.text
            label.lineBreakMode = .byTruncatingMiddle; label.toolTip = path
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let revoke = SettingsUI.button("Revoke", target: self, action: #selector(revokeFolder(_:)), id: "settings.trust.revoke")
            revoke.cell?.representedObject = path
            revoke.setAccessibilityLabel("Revoke \(path)")
            let row = NSStackView(views: [label, revoke]); row.spacing = 10
            trustedList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: trustedList.widthAnchor).isActive = true
        }
    }
    @objc private func revokeFolder(_ sender: NSButton) {
        guard let path = sender.cell?.representedObject as? String else { return }
        ProjectTrust.revoke(URL(fileURLWithPath: path, isDirectory: true))
        reloadTrustedFolders()
    }
    @objc private func revokeAllFolders() {
        ProjectTrust.revokeAll()
        reloadTrustedFolders()
    }
    private func makeCodexCard() -> NSView {
        let card = SettingsUI.card("Coding agent", subtitle: "Compare and Fix comments run through your signed-in coding agent via the Web Frames local connector. No API key needed.", symbol: "terminal")
        providerPopup.removeAllItems()
        for provider in AgentProvider.allCases { providerPopup.addItem(withTitle: provider.productName) }
        providerPopup.target = self; providerPopup.action = #selector(changeProvider)
        providerPopup.setAccessibilityIdentifier("settings.agent.provider")
        modelField.placeholderString = "Default model"
        modelField.target = self; modelField.action = #selector(changeModel)
        modelField.setAccessibilityIdentifier("settings.agent.model")
        modelField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        card.addRow(NSStackView(views: [SettingsUI.label("Provider", size: 12, color: WFDesign.text), providerPopup,
                                        SettingsUI.label("Model", size: 12, color: WFDesign.text), modelField]))
        let connect = SettingsUI.button("Connect", target: self, action: #selector(connectCodex), id: "settings.codex.connect")
        let check = SettingsUI.button("Check", target: self, action: #selector(checkCodex), id: "settings.codex.check")
        let disconnect = SettingsUI.button("Disconnect", target: self, action: #selector(disconnectCodex), id: "settings.codex.disconnect")
        codexButtons = [connect, check, disconnect]
        card.addRow(NSStackView(views: codexButtons)); card.addRow(codexStatus)
        agentHelp.font = .systemFont(ofSize: 11); agentHelp.textColor = WFDesign.text2
        card.addRow(agentHelp)
        refreshAgentControls()
        return card
    }
    private let providerPopup = NSPopUpButton()
    private let modelField = NSTextField()
    private let agentHelp = NSTextField(wrappingLabelWithString: "")
    private func refreshAgentControls() {
        let provider = AgentProvider.current
        providerPopup.selectItem(at: AgentProvider.allCases.firstIndex(of: provider) ?? 0)
        modelField.stringValue = provider.customModel
        modelField.placeholderString = provider.defaultModel.map { "Default: \($0)" } ?? "Default: \(provider.productName)'s choice"
        codexButtons.first?.title = "Connect \(provider.name)"
        agentHelp.stringValue = provider.signInHint + " If the model is not available for your account, clear the field to use the default."
    }
    @objc private func changeProvider() {
        let chosen = AgentProvider.allCases[max(0, providerPopup.indexOfSelectedItem)]
        guard chosen != AgentProvider.current else { return }
        AgentProvider.current = chosen
        refreshAgentControls()
        CodexConnectionStore.shared.agentConfigurationChanged()
    }
    @objc private func changeModel() {
        let provider = AgentProvider.current
        guard modelField.stringValue.trimmingCharacters(in: .whitespaces) != provider.customModel else { return }
        provider.setModel(modelField.stringValue)
        refreshAgentControls()
        CodexConnectionStore.shared.agentConfigurationChanged()
    }
    private func makeClaudeCard() -> NSView {
        let card = SettingsUI.card("Claude · MCP", subtitle: "Connect Claude to Web Frames once, then choose a saved project and read its comments, selectors and screenshots.", symbol: "point.3.connected.trianglepath.dotted")
        let desktop = SettingsUI.button("Copy Desktop config", target: self, action: #selector(copyDesktop), id: "settings.claude.desktop")
        let code = SettingsUI.button("Copy Code command", target: self, action: #selector(copyCode), id: "settings.claude.code")
        card.addRow(NSStackView(views: [desktop, code]))
        claudeStatus.stringValue = "Not configured here · uses the existing Web Frames MCP server"
        claudeStatus.font = .systemFont(ofSize: 11); claudeStatus.textColor = WFDesign.text2
        card.addRow(claudeStatus)
        card.addRow(SettingsUI.label("Available to all saved projects on this Mac. Claude selects a project from the list and reads its latest saved context. Read-only by default; the required runtime is included.", size: 11))
        let toggle = NSButton(checkboxWithTitle: "Allow agents to resolve comments", target: self, action: #selector(changeMCPPermission(_:)))
        toggle.state = CommentsMCPInbox.isAllowed ? .on : .off
        toggle.setAccessibilityIdentifier("settings.mcp.allowResolve")
        resolveCommentsToggle = toggle
        card.addRow(toggle)
        card.addRow(SettingsUI.label("Allows local MCP clients on this Mac to resolve or reopen comments in open projects. Changes can be undone. Source edits still require review and Apply.", size: 11))
        return card
    }
    @objc private func changeMCPPermission(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: CommentsMCPInbox.permissionKey)
    }
    @objc private func refreshCodex() {
        guard isViewLoaded else { return }
        let store = CodexConnectionStore.shared
        codexStatus.stringValue = store.status; codexStatus.font = .systemFont(ofSize: 11)
        codexStatus.textColor = store.isVerified ? .systemGreen : WFDesign.text2
        codexButtons.forEach { $0.isEnabled = !store.isChecking }
        if codexButtons.count == 3 {
            codexButtons[1].isEnabled = !store.isChecking && store.client != nil
            codexButtons[2].isEnabled = !store.isChecking && store.client != nil
        }
    }
    @objc private func connectCodex() {
        task = Task {
            do { try await CodexConnectionStore.shared.connectManaged() }
            catch { codexStatus.stringValue = error.localizedDescription; codexStatus.textColor = .systemOrange }
        }
    }
    @objc private func checkCodex() {
        task = Task {
            do { try await CodexConnectionStore.shared.check() }
            catch { codexStatus.stringValue = error.localizedDescription; codexStatus.textColor = .systemOrange }
        }
    }
    @objc private func disconnectCodex() {
        do { try CodexConnectionStore.shared.disconnect() }
        catch { codexStatus.stringValue = "Could not remove the saved connection from Keychain."; codexStatus.textColor = .systemOrange }
    }
    @objc private func copyDesktop() { copyClaude(forDesktop: true) }
    @objc private func copyCode() { copyClaude(forDesktop: false) }
    private func copyClaude(forDesktop: Bool) {
        do {
            let config = try ClaudeMCPConfiguration.resolve()
            let text = forDesktop ? try config.desktopJSON() : config.codeCommand
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            claudeStatus.stringValue = forDesktop
                ? "Copied. Merge this entry into Claude Desktop → Settings → Developer → Edit Config, then restart Claude."
                : "Copied. Run in Terminal to add Web Frames for all Claude Code projects, then check /mcp."
            claudeStatus.textColor = WFDesign.text2
        } catch { claudeStatus.stringValue = error.localizedDescription; claudeStatus.textColor = .systemOrange }
    }

}

@MainActor private final class ProviderKeyCard: SettingsCard, NSTextFieldDelegate {
    private let provider: ConnectionProvider
    private let field = NSSecureTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var buttons: [NSButton] = []
    private var checkTask: Task<Void, Never>?
    init(provider: ConnectionProvider) {
        self.provider = provider
        super.init(title: provider.title, subtitle: provider.purpose, symbol: provider == .github ? "chevron.left.forwardslash.chevron.right" : "key.horizontal")
        field.placeholderString = provider == .github ? "Personal access token" : "API key"
        field.font = .systemFont(ofSize: 12); field.delegate = self
        field.setAccessibilityLabel("\(provider.title) key"); field.setAccessibilityIdentifier("settings.\(provider.rawValue).key")
        let save = SettingsUI.button("Save", target: self, action: #selector(saveKey), id: "settings.\(provider.rawValue).save")
        let check = SettingsUI.button("Check", target: self, action: #selector(checkKey), id: "settings.\(provider.rawValue).check")
        let remove = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Remove \(provider.title) key")!, target: self, action: #selector(removeKey))
        remove.bezelStyle = .rounded; remove.toolTip = "Remove saved key"; remove.setAccessibilityIdentifier("settings.\(provider.rawValue).remove")
        buttons = [save, check, remove]
        let row = NSStackView(views: [field, save, check, remove]); row.spacing = 8
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        addRow(row)
        status.font = .systemFont(ofSize: 11); status.textColor = WFDesign.text2
        status.setAccessibilityIdentifier("settings.\(provider.rawValue).status"); addRow(status)
        refreshPresence()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func refreshPresence() {
        guard checkTask == nil else { return }
        switch KeychainHelper.contains(key: provider.keychainKey) {
        case .success(let exists):
            status.stringValue = exists ? "Saved in Keychain · not checked" : "No key saved"
            field.placeholderString = exists ? "Enter a replacement key" : (provider == .github ? "Personal access token" : "API key")
            buttons.last?.isEnabled = exists
        case .failure: status.stringValue = "Keychain unavailable. Try saving or checking the key again."
        }
        status.textColor = WFDesign.text2
    }
    func clearInput() { field.stringValue = "" }
    func controlTextDidChange(_ obj: Notification) {
        status.stringValue = field.stringValue.isEmpty ? "No changes to saved key" : "Unsaved key · Save to keep it on this Mac"
        status.textColor = WFDesign.text2
    }
    private func showError(_ message: String) { status.stringValue = message; status.textColor = .systemOrange }
    @objc private func saveKey() {
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try provider.request(token: value)
            try KeychainHelper.save(key: provider.keychainKey, value: value).get()
            field.stringValue = ""; refreshPresence()
        } catch let error as ConnectionSettingsError { showError(error.localizedDescription) }
        catch { showError("Could not save to Keychain. The previous key has been kept.") }
    }
    @objc private func removeKey() {
        do { try KeychainHelper.delete(key: provider.keychainKey).get(); field.stringValue = ""; refreshPresence() }
        catch { showError("Could not remove the key from Keychain.") }
    }
    @objc private func checkKey() {
        guard checkTask == nil else { return }
        let entered = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String
        if !entered.isEmpty { token = entered }
        else {
            switch KeychainHelper.load(key: provider.keychainKey) {
            case .success(let value): token = value
            case .failure: showError("Enter or save a key before checking."); return
            }
        }
        buttons.forEach { $0.isEnabled = false }; field.isEnabled = false
        status.stringValue = "Checking \(provider.title)…"; status.textColor = WFDesign.text2
        checkTask = Task {
            defer { checkTask = nil; buttons.forEach { $0.isEnabled = true }; field.isEnabled = true }
            do {
                let result = try await ConnectionProbe.check(provider, token: token)
                status.stringValue = result + (entered.isEmpty ? "" : " · not saved")
                status.textColor = .systemGreen
            } catch let error as ConnectionSettingsError { showError(error.localizedDescription) }
            catch { showError("Could not reach \(provider.title). Check your network and try again.") }
        }
    }
}

@MainActor private class SettingsCard: NSView {
    private let stack = NSStackView()
    init(title: String, subtitle: String, symbol: String) {
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = WFDesign.bg2.cgColor; layer?.cornerRadius = 14
        layer?.borderWidth = 1; layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = WFDesign.accent; icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let header = NSStackView(views: [icon, SettingsUI.label(title, size: 14, weight: .semibold, color: WFDesign.text)]); header.spacing = 9
        addRow(header); addRow(SettingsUI.label(subtitle, size: 12))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func addRow(_ row: NSView) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
}
@MainActor private enum SettingsUI {
    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color ?? WFDesign.text2
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    static func button(_ title: String, target: AnyObject, action: Selector, id: String) -> NSButton {
        let button = NSButton(title: title, target: target, action: action); button.bezelStyle = .rounded; button.setAccessibilityIdentifier(id)
        button.setContentHuggingPriority(.required, for: .horizontal); return button
    }
    static func card(_ title: String, subtitle: String, symbol: String) -> SettingsCard { SettingsCard(title: title, subtitle: subtitle, symbol: symbol) }
}
private final class SettingsFlippedView: NSView { override var isFlipped: Bool { true } }

/// Shared application window, independent of any document or canvas mode.
@MainActor final class AppSettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = AppSettingsWindowController()
    let settingsViewController = SettingsViewController()
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.identifier = NSUserInterfaceItemIdentifier("webframes.appSettings")
        window.setAccessibilityIdentifier("webframes.appSettings")
        window.minSize = NSSize(width: 620, height: 500)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.backgroundColor = WFDesign.bg
        WFTheme.apply(to: window)
        super.init(window: window)
        window.contentViewController = settingsViewController
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("WebFramesApplicationSettings")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func present() {
        settingsViewController.refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { settingsViewController.clearInputs() }
}
