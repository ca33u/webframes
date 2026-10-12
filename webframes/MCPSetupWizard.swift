import AppKit

@MainActor final class MCPSetupWizard: NSObject {
    private weak var parent: NSWindow?
    private let client = NSPopUpButton()
    private let project = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "Choose the client and which saved boards it can read.")
    private let check = NSButton(title: "Test connection", target: nil, action: nil)
    private let entries: [ProjectStorage.Entry]
    private var checkTask: Task<Void, Never>?

    init(parent: NSWindow, entries: [ProjectStorage.Entry]? = nil) {
        let entries = entries ?? ProjectStorage.listProjects()
        self.parent = parent; self.entries = entries
        super.init()
        client.addItems(withTitles: MCPClient.allCases.map(\.rawValue))
        project.addItem(withTitle: "All saved projects on this Mac")
        project.addItems(withTitles: entries.map(\.displayName))
        if !entries.isEmpty { project.selectItem(at: 1) }
        client.setAccessibilityLabel("MCP client")
        project.setAccessibilityLabel("Boards available to the client")
        client.setAccessibilityIdentifier("mcp.setup.client")
        project.setAccessibilityIdentifier("mcp.setup.project")
        project.target = self; project.action = #selector(scopeChanged)
        check.target = self; check.action = #selector(testConnection)
        check.bezelStyle = .rounded; check.setAccessibilityIdentifier("mcp.setup.test")
        status.font = .systemFont(ofSize: 12)
    }

    private func configuration() throws -> ClaudeMCPConfiguration {
        let index = project.indexOfSelectedItem - 1
        return try ClaudeMCPConfiguration.resolve(projectURL: entries.indices.contains(index) ? entries[index].url : nil)
    }

    func selectionAlert() -> NSAlert {
        let stack = NSStackView(views: [NSTextField(labelWithString: "Client"), client,
            NSTextField(labelWithString: "Access to saved boards"), project, check, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        // Text fields extend two points beyond their alignment rect. Leave room
        // for those drawing bounds rather than clipping them at the alert edge.
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.widthAnchor.constraint(equalToConstant: 500).isActive = true
        status.widthAnchor.constraint(equalToConstant: 492).isActive = true
        // NSAlert sizes an accessory from its frame, not its Auto Layout constraints.
        stack.frame = NSRect(origin: .zero, size: NSSize(width: 500, height: stack.fittingSize.height))
        stack.layoutSubtreeIfNeeded()
        let alert = NSAlert()
        alert.messageText = "Set up Web Frames MCP · 1 of 2"
        alert.informativeText = "Your client can read comments, screenshots and section tasks. Writing remains controlled by the existing Web Frames permissions."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Review setup"); alert.addButton(withTitle: "Cancel")
        return alert
    }

    func show() {
        guard let parent else { return }
        checkTask?.cancel(); project.isEnabled = true; check.isEnabled = true
        let alert = selectionAlert()
        alert.beginSheetModal(for: parent) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.checkTask?.cancel()
            DispatchQueue.main.async { self.review() }
        }
    }

    @objc private func scopeChanged() {
        checkTask?.cancel(); check.isEnabled = true
        status.stringValue = "Scope changed. Test this connection before installing."
    }

    @objc private func testConnection() {
        do {
            let config = try configuration()
            project.isEnabled = false; check.isEnabled = false
            status.stringValue = "Checking the bundled helper locally…"
            checkTask = Task { [weak self] in
                do {
                    let result = try await MCPConnectionProbe.check(config)
                    guard !Task.isCancelled else { return }
                    self?.status.stringValue = result
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.status.stringValue = error.localizedDescription
                }
                self?.project.isEnabled = true; self?.check.isEnabled = true
            }
        } catch { status.stringValue = error.localizedDescription }
    }

    private func review() {
        guard let parent else { return }
        do {
            let config = try configuration()
            let selectedClient = MCPClient.allCases[max(0, client.indexOfSelectedItem)]
            let destination = selectedClient.configurationURL()
            let plan = try destination.map { try MCPInstallPlan.prepare(configuration: config, at: $0) }
            let alert = NSAlert()
            alert.messageText = "Review MCP setup · 2 of 2"
            let scope = config.projectPath == nil ? "All saved Web Frames boards on this Mac" : project.titleOfSelectedItem ?? "Selected board"
            alert.informativeText = "Client: \(selectedClient.rawValue)\nAccess: \(scope)\n\n" + (destination.map {
                "Install or update only \(config.serverName) in:\n\($0.path)\nOther settings and servers stay intact. An existing file is backed up beside it."
            } ?? "Copy this stdio configuration into your client's MCP settings.")
                + "\n\nKeep Web Frames at the location shown below. Installation does not enable comment or image writes."
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 170))
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.isRichText = false
            text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            text.string = try config.desktopJSON(); text.setAccessibilityLabel("MCP configuration preview")
            scroll.documentView = text; alert.accessoryView = scroll
            alert.addButton(withTitle: plan == nil ? "Copy config" : "Install")
            alert.addButton(withTitle: "Back"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: parent) { [weak self] response in
                guard let self else { return }
                if response == .alertSecondButtonReturn { DispatchQueue.main.async { self.show() }; return }
                guard response == .alertFirstButtonReturn else { return }
                do {
                    if let plan {
                        let backup = try plan.install()
                        let next = selectedClient == .desktop ? "Restart Claude Desktop, then find Web Frames in its MCP tools." : "Run claude mcp get \(config.serverName), then open /mcp in Claude Code."
                        self.finish("MCP configuration saved", detail: next + (backup == nil ? "" : "\nA backup of your previous config is beside the config file."))
                    } else {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(try config.desktopJSON(), forType: .string)
                        self.finish("MCP configuration copied", detail: "Paste it into your client's stdio MCP settings, then reconnect the client.")
                    }
                } catch { self.finish("MCP setup could not be saved", detail: error.localizedDescription) }
            }
        } catch { finish("MCP setup unavailable", detail: error.localizedDescription) }
    }

    private func finish(_ title: String, detail: String) {
        guard let parent else { return }
        DispatchQueue.main.async {
            let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
            alert.addButton(withTitle: "Done"); alert.beginSheetModal(for: parent)
        }
    }
}
