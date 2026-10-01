import AppKit

/// A catalogue attached to the existing workspace, not a second app window.
@MainActor final class ProjectMapController: NSObject, NSTextFieldDelegate, AddFrameTabPanel {
    private weak var owner: DocumentWindowController?
    private weak var project: WebFramesDocument?
    private let content = NSViewController()
    private let rows = ProjectCatalogueStack()
    private let status = NSTextField(wrappingLabelWithString: "Choose a web project to discover its pages and inventory.")
    private let base = NSTextField(string: "http://localhost:3000")
    private let siteStatusDot = NSImageView()
    private let dropView = ImageDropView(folderMode: true)
    private let projectName = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let serverProgress = NSProgressIndicator()
    private let startServer = NSButton(checkboxWithTitle: "Start dev server when adding (runs project scripts)", target: nil, action: nil)
    private let serverSuggestions = NSPopUpButton()
    private var projectViews: [NSView] = []
    private var discoveryTask: Task<Void, Never>?
    private var generation = 0
    private let search = NSSearchField()
    var onConfirmationChange: (() -> Void)?
    var view: NSView { content.view }
    func currentSpec() -> [String: Any]? { nil }
    var canConfirm: Bool {
        guard !busy, let snapshot else { return false }
        let selected = snapshot.routes.filter { $0.selected && !$0.missing }
        return (1...10).contains(selected.count)
    }
    var confirmationTitle: String { "Add Frames" }
    func performConfirmation() -> Bool { buildMap(); return true }
    func willAppear() { _ = embeddedView() }
    private let scanButton = NSButton()
    private var snapshot: ProjectMapSnapshot?
    private var busy = false
    private var siteProbeTask: Task<Void, Never>?
    func embeddedView() -> NSView {
        snapshot = project?.workspace.projectMap ?? snapshot
        base.stringValue = snapshot?.baseURL ?? "http://localhost:3000"
        render()
        if snapshot != nil { checkSiteStatus(); discoverServers(force: false) }
        return content.view
    }
    var isPresented: Bool { content.view.window != nil }
    private var exampleFields: [Int: NSTextField] = [:]

    init(owner: DocumentWindowController, project: WebFramesDocument) {
        self.owner = owner; self.project = project
        super.init()
        snapshot = project.workspace.projectMap
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 350))
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; content.view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.view.leadingAnchor, constant: 0), stack.trailingAnchor.constraint(equalTo: content.view.trailingAnchor, constant: 0), stack.topAnchor.constraint(equalTo: content.view.topAnchor, constant: 0), stack.bottomAnchor.constraint(equalTo: content.view.bottomAnchor, constant: 0)])
        let choose = icon("folder.badge.plus", "Choose project folder", #selector(chooseFolder))
        scanButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Rescan project")
        scanButton.toolTip = "Rescan project"; scanButton.bezelStyle = .rounded; scanButton.target = self; scanButton.action = #selector(rescan)
        
        dropView.onClick = { [weak self] in self?.chooseFolder() }
        dropView.onFiles = { [weak self] urls in if let url = urls.first { self?.scan(url) } }
        dropView.heightAnchor.constraint(equalToConstant: 160).isActive = true
        stack.addArrangedSubview(dropView)
        progress.style = .spinning; progress.controlSize = .small; progress.isDisplayedWhenStopped = false; progress.isHidden = true
        stack.addArrangedSubview(progress)
        projectName.font = .systemFont(ofSize: 13, weight: .semibold)
        projectName.lineBreakMode = .byTruncatingMiddle
        projectName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [projectName, NSView(), choose, scanButton]); header.spacing = 8
        stack.addArrangedSubview(header)
        search.placeholderString = "Find a page"; search.target = self; search.action = #selector(searchChanged); search.sendsSearchStringImmediately = true
        siteStatusDot.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Server status")
        siteStatusDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([siteStatusDot.widthAnchor.constraint(equalToConstant: 18), siteStatusDot.heightAnchor.constraint(equalToConstant: 18)])
        serverProgress.style = .spinning; serverProgress.controlSize = .small; serverProgress.isDisplayedWhenStopped = false
        let findServers = icon("antenna.radiowaves.left.and.right", "Find running web servers", #selector(refreshServers))
        let address = NSStackView(views: [siteStatusDot, base, serverProgress, findServers]); address.spacing = 8; address.alignment = .centerY
        let addressLabel = NSTextField(labelWithString: "Server address")
        addressLabel.font = .systemFont(ofSize: 11, weight: .medium); addressLabel.textColor = WFDesign.text2
        stack.addArrangedSubview(addressLabel)
        stack.setCustomSpacing(4, after: addressLabel)
        stack.addArrangedSubview(address)
        base.setAccessibilityLabel("Server address")
        base.toolTip = "Server address for the selected pages"
        serverSuggestions.target = self; serverSuggestions.action = #selector(useServer(_:))
        stack.addArrangedSubview(serverSuggestions)
        startServer.state = .on
        startServer.toolTip = "Run the project’s dev script when adding pages. Already running servers are reused."
        stack.addArrangedSubview(startServer)
        base.setContentHuggingPriority(.defaultLow, for: .horizontal)
        base.delegate = self
        base.placeholderString = "http://localhost:3000"; base.stringValue = snapshot?.baseURL ?? "http://localhost:3000"
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 10; rows.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rows; stack.addArrangedSubview(search); stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), rows.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor), rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), scroll.heightAnchor.constraint(equalToConstant: 150)])
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; status.maximumNumberOfLines = 3; stack.addArrangedSubview(status)
        projectViews = [header, search, addressLabel, address, scroll]
        for view in [dropView, header, search, address, scroll, status] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        render()
    }
    private func icon(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.toolTip = label; button.bezelStyle = .rounded; return button
    }
    private func saveDraft() {
        for (i, field) in exampleFields where snapshot?.routes.indices.contains(i) == true { snapshot?.routes[i].examplePath = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        snapshot?.baseURL = base.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        owner?.canvasHost.serverDiscovery.projectAddress = snapshot?.baseURL
        if let snapshot { project?.workspace.setProjectMap(snapshot) }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === base else { return }
        saveDraft(); updateStartOption(); checkSiteStatus(); discoverServers(force: false)
    }
    @objc private func searchChanged() { saveDraft(); render() }
    @objc private func chooseFolder() {
        guard !busy, let window = owner?.window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Choose a web project folder. Web Frames discovers pages and components. You can choose to start its server when adding pages."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }; self?.scan(url)
        }
    }
    @objc private func rescan() {
        guard !busy else { return }
        guard let snapshot else { chooseFolder(); return }
        saveDraft()
        if snapshot.bookmark != nil {
            // scan(_:) records a fresh bookmark for the resolved URL, so a
            // stale one is replaced on the next confirmation.
            let resolution = SecurityScopedAccess.resolve(bookmark: snapshot.bookmark, fallbackPath: snapshot.rootPath)
            if FileManager.default.fileExists(atPath: resolution.url.path) { scan(resolution.url); return }
        }
        chooseFolder()
    }
    private func scan(_ url: URL) {
        guard !busy else { return }
        saveDraft()
        let previous = snapshot
        busy = true; onConfirmationChange?(); scanButton.isEnabled = false
        dropView.isEnabled = false; progress.isHidden = false; progress.startAnimation(nil)
        serverProgress.stopAnimation(nil)
        base.isEnabled = false; search.isEnabled = false; startServer.isEnabled = false; serverSuggestions.isEnabled = false
        generation += 1; siteProbeTask?.cancel(); discoveryTask?.cancel()
        status.stringValue = "Reading pages and component imports…"
        let granted = url.startAccessingSecurityScopedResource()
        let bookmark = try? SecurityScopedAccess.makeBookmark(for: url)
        if bookmark == nil {
            status.stringValue = "macOS did not allow Web Frames to remember this folder; you may need to choose it again after relaunch."
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Result { try WebProjectScanner.scan(root: url) } }.value
            if granted { url.stopAccessingSecurityScopedResource() }
            guard let self else { return }
            self.busy = false; self.scanButton.isEnabled = true
            self.dropView.isEnabled = true; self.progress.stopAnimation(nil); self.progress.isHidden = true
            self.base.isEnabled = true; self.search.isEnabled = true; self.startServer.isEnabled = true; self.serverSuggestions.isEnabled = true
            switch result {
            case .success(var scan):
                scan.bookmark = bookmark
                self.exampleFields.removeAll()
                self.snapshot = ProjectMapBuilder.merged(scan, previous: self.snapshot)
                self.snapshot?.bookmark = bookmark
                self.base.stringValue = self.snapshot?.baseURL ?? "http://localhost:3000"
                if previous?.rootPath != scan.rootPath { self.startServer.state = .on }
                self.saveDraft(); self.render(); self.checkSiteStatus(); self.discoverServers(force: true)
                if previous?.rootPath == scan.rootPath {
                    let oldPaths = Set(previous?.routes.filter { !$0.missing }.map(\.path) ?? [])
                    let added = scan.routes.filter { !oldPaths.contains($0.path) }.count
                    self.status.stringValue = "Scan complete · \(added) new pages · \(scan.components.count) components · \(scan.tokens.count) CSS variables"
                }
            case .failure(let error): self.render(); self.status.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func toggleRoute(_ button: NSButton) {
        snapshot?.routes[button.tag].selected = button.state == .on
        saveDraft(); updateStatus()
    }
    @objc private func focusPage(_ button: NSButton) {
        guard let snapshot, snapshot.routes.indices.contains(button.tag), let id = snapshot.routes[button.tag].frameID,
              let owner, let frame = project?.workspace.frame(id: id) else { return }
        owner.canvasHost.dismissAddFrameModal()
        owner.canvasHost.selectFrame(id)
        project?.workspace.setViewport(ViewportModel(scale: 0.6, panX: 80 - frame.x * 0.6, panY: 100 - frame.y * 0.6))
    }
    private func label(_ text: String, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: secondary ? 11 : 13)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor; field.isSelectable = true
        return field
    }
    private func card(_ views: [NSView]) {
        let card = NSStackView(views: views); card.orientation = .vertical; card.alignment = .leading; card.spacing = 5
        card.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        card.wantsLayer = true; card.layer?.cornerRadius = 12; card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        rows.addArrangedSubview(card); card.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -6).isActive = true
        for view in views { view.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, constant: -24).isActive = true }
    }
    private func render() {
        let hasProject = snapshot != nil
        dropView.isHidden = hasProject
        projectViews.forEach { $0.isHidden = !hasProject }
        serverSuggestions.isHidden = !hasProject || serverSuggestions.numberOfItems <= 1
        projectName.stringValue = snapshot?.name ?? ""
        projectName.toolTip = snapshot?.rootPath
        owner?.canvasHost.serverDiscovery.projectAddress = snapshot?.baseURL
        updateStartOption()
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }; exampleFields.removeAll()
        guard let snapshot else { updateStatus(); return }
        let query = search.stringValue.lowercased()
        func includes(_ s: String) -> Bool { query.isEmpty || s.lowercased().contains(query) }
        do {
            for (i, route) in snapshot.routes.enumerated() where includes(route.path + route.source) {
                let check = NSButton(checkboxWithTitle: route.path + (route.missing ? " · missing" : ""), target: self, action: #selector(toggleRoute(_:)))
                check.tag = i; check.state = route.selected ? .on : .off; check.isEnabled = !route.missing
                var views: [NSView] = [check, label(route.source, secondary: true)]
                if route.dynamic && !route.missing {
                    let fieldLabel = label("Page URL to open", secondary: true)
                    let example = NSTextField(string: route.examplePath)
                    example.placeholderString = suggestedPath(for: route.path)
                    example.toolTip = "Enter a real URL path for this dynamic page."
                    exampleFields[i] = example
                    views.append(contentsOf: [fieldLabel, example])
                }
                if route.frameID.flatMap({ project?.workspace.frame(id: $0) }) != nil {
                    let focus = NSButton(title: "Show page", target: self, action: #selector(focusPage(_:))); focus.tag = i; focus.bezelStyle = .rounded; views.append(focus)
                }
                card(views)
            }
        }
        if rows.arrangedSubviews.isEmpty { card([label(snapshot.routes.isEmpty ? "No supported pages found. Components and variables are available in Library." : "No matching pages.")]) }
        updateStatus()
    }
    private func updateStatus() {
        onConfirmationChange?()
        guard let snapshot else { return }
        let count = snapshot.routes.filter { $0.selected && !$0.missing }.count

        let summary = "\(snapshot.name) · \(snapshot.routes.filter { !$0.missing }.count) pages · \(snapshot.components.count) component candidates · \(snapshot.tokens.count) CSS variables"
        status.stringValue = "\(count) of 10 pages selected\n" + summary
    }
    private func updateStartOption() {
        startServer.isHidden = snapshot.map { owner?.canvasHost.canStartImportedServer($0) != true } ?? true
    }

    @objc private func refreshServers() { guard !busy else { return }; checkSiteStatus(); discoverServers(force: true) }

    private func discoverServers(force: Bool) {
        guard let discovery = owner?.canvasHost.serverDiscovery, snapshot != nil else { return }
        discoveryTask?.cancel()
        let address = base.stringValue
        discoveryTask = Task { [weak self] in
            let ports = await discovery.discover(address: address, force: force)
            guard !Task.isCancelled, let self else { return }
            serverSuggestions.removeAllItems()
            serverSuggestions.addItem(withTitle: ports.isEmpty ? "No local web servers found" : "Use a running server…")
            for port in ports { serverSuggestions.addItem(withTitle: "http://localhost:\(port)") }
            serverSuggestions.isHidden = ports.isEmpty || snapshot == nil
        }
    }

    @objc private func useServer(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem > 0, let address = sender.titleOfSelectedItem else { return }
        base.stringValue = address
        sender.selectItem(at: 0)
        saveDraft(); updateStartOption(); checkSiteStatus()
    }

    @objc private func buildMap() {
        guard canConfirm else { return }
        content.view.window?.makeFirstResponder(nil)
        saveDraft()
        guard let snapshot, let project else { return }
        let shouldStart = !startServer.isHidden && startServer.state == .on
        finishBuild(snapshot, project: project, start: shouldStart)
    }

    private enum SiteStatus { case checking, online, offline }

    private func setSiteStatus(_ value: SiteStatus) {
        serverProgress.stopAnimation(nil)
        let description: String
        switch value {
        case .checking:
            siteStatusDot.contentTintColor = .secondaryLabelColor
            serverProgress.startAnimation(nil)
            description = "Checking server…"
        case .online:
            siteStatusDot.contentTintColor = .systemGreen
            description = "Server is online"
        case .offline:
            siteStatusDot.contentTintColor = .systemRed
            description = "Server is offline"
        }
        siteStatusDot.toolTip = description
        siteStatusDot.setAccessibilityLabel(description)
    }

    private func checkSiteStatus() {
        generation += 1
        let currentGeneration = generation
        siteProbeTask?.cancel()
        guard snapshot != nil else { return }
        let address = base.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? ProjectMapBuilder.pageURL(base: address, path: "/")) != nil else { setSiteStatus(.offline); return }
        setSiteStatus(.checking)
        siteProbeTask = Task { [weak self] in
            let online = await LocalServerDiscovery.responds(address)
            guard !Task.isCancelled, let self, generation == currentGeneration else { return }
            setSiteStatus(online ? .online : .offline)
        }
    }

    private func finishBuild(_ snapshot: ProjectMapSnapshot, project: WebFramesDocument, start: Bool) {
        do {
            let built = try ProjectMapBuilder.build(snapshot, store: project.workspace)
            self.snapshot = built
            siteProbeTask?.cancel(); discoveryTask?.cancel()
            let pageIDs = built.routes.compactMap { route in
                route.selected && !route.missing ? route.frameID : nil
            }
            owner?.canvasHost.dismissAddFrameModal()
            owner?.canvasHost.performDockAction(.zoomFit)
            // Frames are hidden while this modal is open. Reload once they are
            // back on the canvas so WebKit does not leave deferred localhost
            // navigations as blank white pages.
            DispatchQueue.main.async { [weak self] in
                guard let host = self?.owner?.canvasHost else { return }
                for id in pageIDs { host.reloadFrame(id: id) }
                if start { host.startImportedServer(built) }
            }
        } catch {
            updateStatus()
            status.stringValue = error.localizedDescription
        }
    }

    private func suggestedPath(for route: String) -> String {
        let parts = route.split(separator: "/", omittingEmptySubsequences: true).map { part -> String in
            guard part.hasPrefix("[") else { return String(part) }
            let token = part.lowercased()
            if token.contains("id") { return "42" }
            if token.contains("slug") { return token.contains("...") ? "example/page" : "example" }
            return "sample"
        }
        return "/" + parts.joined(separator: "/")
    }
}

private final class ProjectCatalogueStack: NSStackView {
    override var isFlipped: Bool { true }
}
