import AppKit
import WebKit

/// One in-workspace component browser. Static inventory is always available; live previews are optional.
@MainActor final class ComponentCatalogueController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private weak var owner: DocumentWindowController?
    private weak var project: WebFramesDocument?
    private var overlay: NSView?
    private var web: WKWebView?
    private var connection: URL?
    private var projectID: String?
    private var componentIDs = Set<String>()
    private var connecting = false
    private var generation = 0
    private var helperProcess: Process?
    private var helperPipe: Pipe?
    private var helperScopedURL: URL?
    private var helperOutput = ""
    private let address = NSTextField(string: "http://127.0.0.1:4319")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let setup = NSStackView()
    private let sections = NSSegmentedControl(labels: ["Components", "Variables"], trackingMode: .selectOne, target: nil, action: nil)
    private let components = NSScrollView()
    private let componentRows = LibraryRows()
    private let componentSearch = NSSearchField()
    private let variables = NSScrollView()
    private let variableRows = LibraryRows()
    private let variableSearch = NSSearchField()
    private var librarySubscription: WorkspaceStore.Subscription?
    var isPresented: Bool { overlay != nil }

    init(owner: DocumentWindowController, project: WebFramesDocument) {
        self.owner = owner; self.project = project
        super.init()
    }
    func present() {
        guard overlay == nil, let owner else { return }
        let host = owner.canvasHost
        let map = project?.workspace.projectMap
        connection = nil; projectID = nil; componentIDs = []
        address.stringValue = map?.catalogURL ?? "http://127.0.0.1:4319"
        let panel = NSView(); panel.wantsLayer = true; panel.layer?.backgroundColor = WFDesign.bg.cgColor
        panel.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(panel, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([panel.leadingAnchor.constraint(equalTo: host.leadingAnchor), panel.trailingAnchor.constraint(equalTo: host.trailingAnchor), panel.topAnchor.constraint(equalTo: host.topAnchor, constant: 44), panel.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
        overlay = panel; owner.canvasHost.dock.isHidden = true
        owner.canvasHost.bridge.setAllFramesVisible(false)
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; panel.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16)])
        sections.target = self; sections.action = #selector(changeSection); sections.selectedSegment = 0
        sections.segmentStyle = .rounded; sections.selectedSegmentBezelColor = WFDesign.accent
        sections.setAccessibilityLabel("Library section")
        let header = NSStackView(views: [sections, NSView(), icon("gearshape", "Preview connection", #selector(toggleSetup)), icon("arrow.clockwise", "Reconnect previews", #selector(refreshCatalogue))]); header.spacing = 10
        stack.addArrangedSubview(header)
        setup.arrangedSubviews.forEach { setup.removeArrangedSubview($0); $0.removeFromSuperview() }
        setup.orientation = .vertical; setup.alignment = .leading; setup.spacing = 8; setup.isHidden = true
        let description = NSTextField(wrappingLabelWithString: "Connect the local preview server for this project.")
        description.textColor = .secondaryLabelColor; description.font = .systemFont(ofSize: 12)
        let row = NSStackView(views: [address, icon("link", "Connect previews", #selector(connect)), icon("doc.on.doc", "Copy start command", #selector(copyCommand))]); row.spacing = 8
        setup.addArrangedSubview(description); setup.addArrangedSubview(row); stack.addArrangedSubview(setup)
        status.textColor = .secondaryLabelColor; status.font = .systemFont(ofSize: 12); status.maximumNumberOfLines = 3
        status.stringValue = componentStatus(for: map)
        status.isHidden = false; stack.addArrangedSubview(status)
        componentSearch.placeholderString = "Find a component"; componentSearch.target = self; componentSearch.action = #selector(renderComponents); componentSearch.sendsSearchStringImmediately = true
        stack.addArrangedSubview(componentSearch)
        components.hasVerticalScroller = true; components.drawsBackground = false
        componentRows.orientation = .vertical; componentRows.alignment = .leading; componentRows.spacing = 12; componentRows.translatesAutoresizingMaskIntoConstraints = false
        components.documentView = componentRows
        NSLayoutConstraint.activate([componentRows.leadingAnchor.constraint(equalTo: components.contentView.leadingAnchor), componentRows.trailingAnchor.constraint(equalTo: components.contentView.trailingAnchor), componentRows.topAnchor.constraint(equalTo: components.contentView.topAnchor), componentRows.bottomAnchor.constraint(greaterThanOrEqualTo: components.contentView.bottomAnchor)])
        stack.addArrangedSubview(components)
        variableSearch.placeholderString = "Find a variable"; variableSearch.target = self; variableSearch.action = #selector(renderVariables); variableSearch.sendsSearchStringImmediately = true
        stack.addArrangedSubview(variableSearch)
        variables.hasVerticalScroller = true; variables.drawsBackground = false
        variableRows.orientation = .vertical; variableRows.alignment = .leading; variableRows.spacing = 12; variableRows.translatesAutoresizingMaskIntoConstraints = false
        variables.documentView = variableRows
        NSLayoutConstraint.activate([variableRows.leadingAnchor.constraint(equalTo: variables.contentView.leadingAnchor), variableRows.trailingAnchor.constraint(equalTo: variables.contentView.trailingAnchor), variableRows.topAnchor.constraint(equalTo: variables.contentView.topAnchor), variableRows.bottomAnchor.constraint(greaterThanOrEqualTo: variables.contentView.bottomAnchor)])
        stack.addArrangedSubview(variables)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(WeakCatalogueHandler(self), name: "componentCatalog")
        let browser = WKWebView(frame: .zero, configuration: configuration); browser.navigationDelegate = self
        browser.underPageBackgroundColor = WFDesign.bg
        browser.isHidden = true
        web = browser; stack.addArrangedSubview(browser)
        for view in [header, setup, status, componentSearch, components, variableSearch, variables, browser] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        row.widthAnchor.constraint(equalTo: setup.widthAnchor).isActive = true
        browser.setContentHuggingPriority(.defaultLow, for: .vertical)
        components.setContentHuggingPriority(.defaultLow, for: .vertical)
        variables.setContentHuggingPriority(.defaultLow, for: .vertical)
        changeSection()
        librarySubscription = project?.workspace.observe { [weak self] in
            self?.renderComponents()
            self?.renderVariables()
        }
        if map != nil {
            refreshStaticInventory()
            startLocalCatalogue()
        }
    }
    @objc private func changeSection() {
        let showVariables = sections.selectedSegment == 1
        let showLivePreview = !showVariables && connection != nil
        web?.isHidden = !showLivePreview
        components.isHidden = showVariables || showLivePreview
        componentSearch.isHidden = showVariables || showLivePreview
        variables.isHidden = !showVariables; variableSearch.isHidden = !showVariables
        setup.isHidden = true
        status.isHidden = showLivePreview
        if showVariables {
            let count = project?.workspace.projectMap?.tokens.count ?? 0
            status.stringValue = "\(count) visual variables and explicit values found in this project."
        } else if !showLivePreview && helperProcess == nil {
            status.stringValue = componentStatus(for: project?.workspace.projectMap)
        }
        renderComponents()
        renderVariables()
    }
    private func componentStatus(for map: ProjectMapSnapshot?) -> String {
        guard let map else { return "Import a web project with + → Project to see its components and variables." }
        return "\(map.components.count) components found in this project. Live previews are optional."
    }
    @objc private func renderComponents() {
        guard overlay != nil else { return }
        componentRows.arrangedSubviews.forEach { componentRows.removeArrangedSubview($0); $0.removeFromSuperview() }
        let query = componentSearch.stringValue.lowercased()
        let found = (project?.workspace.projectMap?.components ?? []).filter {
            query.isEmpty || ($0.name + $0.source + $0.pages.joined(separator: " ")).lowercased().contains(query)
        }
        for item in found {
            let symbol = NSImageView(image: NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Component")!)
            symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
            symbol.contentTintColor = WFDesign.accent
            symbol.imageScaling = .scaleProportionallyDown
            symbol.widthAnchor.constraint(equalToConstant: 44).isActive = true
            symbol.heightAnchor.constraint(equalToConstant: 44).isActive = true

            let name = NSTextField(labelWithString: item.name)
            name.font = .systemFont(ofSize: 14, weight: .semibold); name.textColor = WFDesign.text; name.isSelectable = true
            let source = NSTextField(wrappingLabelWithString: "\(item.source):\(item.line)")
            source.font = .monospacedSystemFont(ofSize: 11, weight: .regular); source.textColor = .secondaryLabelColor; source.isSelectable = true
            let usageText = item.pages.isEmpty ? "No page usage found" : "Used on " + item.pages.prefix(4).joined(separator: ", ") + (item.pages.count > 4 ? " +\(item.pages.count - 4)" : "")
            let usage = NSTextField(wrappingLabelWithString: usageText)
            usage.font = .systemFont(ofSize: 11); usage.textColor = .tertiaryLabelColor; usage.isSelectable = true
            let text = NSStackView(views: [name, source, usage]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 5

            let card = NSStackView(views: [symbol, text, NSView()]); card.orientation = .horizontal; card.alignment = .centerY; card.spacing = 14
            card.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
            card.wantsLayer = true; card.layer?.backgroundColor = WFDesign.bg2.cgColor; card.layer?.cornerRadius = 12
            card.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor; card.layer?.borderWidth = 1
            componentRows.addArrangedSubview(card); card.widthAnchor.constraint(equalTo: componentRows.widthAnchor, constant: -8).isActive = true
        }
        if found.isEmpty {
            let text: String
            if project?.workspace.projectMap == nil { text = "Import a project with + → Project." }
            else if !query.isEmpty { text = "No matching components found." }
            else { text = "No component candidates were found in this project." }
            let empty = NSTextField(wrappingLabelWithString: text); empty.textColor = .secondaryLabelColor
            componentRows.addArrangedSubview(empty)
        }
    }
    @objc private func renderVariables() {
        guard overlay != nil else { return }
        variableRows.arrangedSubviews.forEach { variableRows.removeArrangedSubview($0); $0.removeFromSuperview() }
        let query = variableSearch.stringValue.lowercased()
        let tokens = (project?.workspace.projectMap?.tokens ?? []).filter { query.isEmpty || ($0.name + $0.value + $0.source).lowercased().contains(query) }
        for token in tokens {
            let name = NSTextField(labelWithString: token.name); name.font = .monospacedSystemFont(ofSize: 13, weight: .medium); name.textColor = WFDesign.text; name.isSelectable = true
            let value = NSTextField(wrappingLabelWithString: token.value); value.font = .systemFont(ofSize: 13); value.textColor = WFDesign.text; value.isSelectable = true
            let source = NSTextField(wrappingLabelWithString: "\(token.source):\(token.line)"); source.font = .systemFont(ofSize: 11); source.textColor = .secondaryLabelColor; source.isSelectable = true
            let text = NSStackView(views: [name, value, source]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 6
            let swatch = NSView(); swatch.wantsLayer = true; swatch.layer?.cornerRadius = 10
            swatch.layer?.backgroundColor = Self.color(token.value)?.cgColor ?? WFDesign.bg4.cgColor
            swatch.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor; swatch.layer?.borderWidth = 1
            swatch.widthAnchor.constraint(equalToConstant: 44).isActive = true; swatch.heightAnchor.constraint(equalToConstant: 44).isActive = true
            if Self.color(token.value) == nil {
                let sample = NSTextField(labelWithString: token.name.contains("font") ? "Aa" : "{}")
                sample.font = .systemFont(ofSize: 16, weight: .medium); sample.textColor = WFDesign.text
                sample.translatesAutoresizingMaskIntoConstraints = false; swatch.addSubview(sample)
                sample.centerXAnchor.constraint(equalTo: swatch.centerXAnchor).isActive = true; sample.centerYAnchor.constraint(equalTo: swatch.centerYAnchor).isActive = true
            }
            let card = NSStackView(views: [swatch, text, NSView()]); card.orientation = .horizontal; card.alignment = .centerY; card.spacing = 16
            card.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
            card.wantsLayer = true; card.layer?.backgroundColor = WFDesign.bg2.cgColor; card.layer?.cornerRadius = 12
            card.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor; card.layer?.borderWidth = 1
            variableRows.addArrangedSubview(card); card.widthAnchor.constraint(equalTo: variableRows.widthAnchor, constant: -8).isActive = true
        }
        if tokens.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: project?.workspace.projectMap == nil ? "Import a project with + → Project." : "No matching CSS variables found in this project.")
            empty.textColor = .secondaryLabelColor; variableRows.addArrangedSubview(empty)
        }
    }
    nonisolated private static func color(_ raw: String) -> NSColor? {
        var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.hasPrefix("#") else { return nil }; hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let number = UInt32(hex, radix: 16) else { return nil }
        return NSColor(red: CGFloat((number >> 16) & 255) / 255, green: CGFloat((number >> 8) & 255) / 255, blue: CGFloat(number & 255) / 255, alpha: 1)
    }
    private func icon(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .rounded; button.toolTip = label; return button
    }
    @objc func close() {
        generation += 1; connecting = false; librarySubscription = nil
        stopLocalCatalogue()
        web?.stopLoading(); web?.configuration.userContentController.removeScriptMessageHandler(forName: "componentCatalog")
        web?.navigationDelegate = nil; web?.removeFromSuperview(); web = nil
        overlay?.removeFromSuperview(); overlay = nil; owner?.canvasHost.bridge.setAllFramesVisible(true); owner?.canvasHost.dock.isHidden = false; owner?.window?.makeFirstResponder(owner?.canvasHost)
    }
    @objc private func toggleSetup() {
        setup.isHidden.toggle()
        if !setup.isHidden {
            status.isHidden = false
            status.stringValue = "Optional: connect the local helper to render live component previews."
        } else {
            changeSection()
        }
    }
    @objc private func copyCommand() {
        guard let map = project?.workspace.projectMap else { return }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        do {
            let helper = try BundledTools.script("component-catalog/server.mjs")
            let node = try BundledTools.catalogueNode(projectRoot: map.rootPath)
            let command = quote(node.path) + " " + quote(helper.path) + " " + quote(map.rootPath)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
            status.stringValue = "Start command copied."
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func refreshCatalogue() {
        refreshStaticInventory()
        guard let previous = helperProcess else {
            if connection != nil { connect() } else { startLocalCatalogue() }
            return
        }
        generation += 1
        let attempt = generation
        connecting = false; connection = nil; projectID = nil; componentIDs = []
        stopLocalCatalogue()
        changeSection()
        status.stringValue = "Restarting component previews…"
        Task { [weak self] in
            for _ in 0..<30 {
                if !previous.isRunning { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, self.generation == attempt, self.overlay != nil else { return }
            guard !previous.isRunning else {
                self.status.stringValue = "The preview server is still stopping. Try Refresh again in a moment."
                return
            }
            self.startLocalCatalogue()
        }
    }
    @objc private func connect() {
        guard !connecting, let map = project?.workspace.projectMap,
              let url = Self.localOrigin(address.stringValue) else { status.stringValue = "Use a local catalogue address such as http://127.0.0.1:4319."; return }
        connecting = true; generation += 1; let attempt = generation
        connection = nil; projectID = nil; componentIDs = []
        status.stringValue = "Connecting…"; status.isHidden = sections.selectedSegment == 1
        Task { [weak self] in
            do {
                var request = URLRequest(url: url.appendingPathComponent("catalog.json")); request.timeoutInterval = 8
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count < 4_000_000,
                      let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      manifest["protocol"] as? String == "webframes-catalog-v1",
                      let root = manifest["root"] as? String,
                      URL(fileURLWithPath: root).standardizedFileURL.path == URL(fileURLWithPath: map.rootPath).standardizedFileURL.path,
                      let id = manifest["projectId"] as? String,
                      let components = manifest["components"] as? [[String: Any]] else {
                    throw NSError(domain: "ComponentCatalogue", code: 1, userInfo: [NSLocalizedDescriptionKey: "This server is not a Web Frames catalogue for the selected project. Start the helper with the correct project folder."])
                }
                guard let self, self.generation == attempt, self.overlay != nil, self.project?.workspace.projectMap?.rootPath == map.rootPath else { return }
                self.activateCatalogue(url: url, id: id, components: components)
            } catch {
                guard let self, self.generation == attempt else { return }
                self.connecting = false; self.connection = nil
                self.web?.isHidden = true
                self.components.isHidden = self.sections.selectedSegment == 1
                self.componentSearch.isHidden = self.sections.selectedSegment == 1
                self.setup.isHidden = self.sections.selectedSegment == 1; self.status.isHidden = self.sections.selectedSegment == 1
                self.status.stringValue = "Could not connect. " + error.localizedDescription
            }
        }
    }
    private func activateCatalogue(url: URL, id: String, components: [[String: Any]]) {
        connecting = false; connection = url; projectID = id
        componentIDs = Set(components.compactMap { $0["id"] as? String })
        var updated = project?.workspace.projectMap; updated?.catalogURL = url.absoluteString
        if let updated { project?.workspace.setProjectMap(updated) }
        setup.isHidden = true; status.isHidden = true
        status.stringValue = "\(components.count) components · rendered from project source"
        web?.load(URLRequest(url: url)); changeSection()
    }
    private func refreshStaticInventory() {
        // Resolve first: a stale bookmark rewrites the map's root path.
        guard let root = project?.resolvedProjectRoot(), let existing = project?.workspace.projectMap else { return }
        let granted = root.startAccessingSecurityScopedResource()
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Result { try WebProjectScanner.scan(root: root) } }.value
            if granted { root.stopAccessingSecurityScopedResource() }
            guard let self, self.overlay != nil, case .success(var scan) = result,
                  self.project?.workspace.projectMap?.rootPath == existing.rootPath else { return }
            scan.bookmark = existing.bookmark
            let merged = ProjectMapBuilder.merged(scan, previous: self.project?.workspace.projectMap)
            self.project?.workspace.setProjectMap(merged)
            self.status.stringValue = self.sections.selectedSegment == 1
                ? "\(merged.tokens.count) visual variables and explicit values found in this project."
                : self.componentStatus(for: merged)
            self.renderComponents(); self.renderVariables()
        }
    }
    private func startLocalCatalogue() {
        guard helperProcess == nil, let map = project?.workspace.projectMap else { return }
        let projectRoot = URL(fileURLWithPath: map.rootPath, isDirectory: true)
        guard ProjectTrust.isTrusted(projectRoot) else {
            status.isHidden = false
            status.stringValue = "Library needs permission to run this project’s build tooling."
            ProjectTrust.confirm(projectRoot, purpose: .library, in: overlay?.window) { [weak self] approved in
                guard let self, self.overlay != nil, self.project?.workspace.projectMap?.rootPath == map.rootPath else { return }
                if approved { self.startLocalCatalogue() }
                else { self.status.stringValue = "Live previews are off for this project. Click Refresh to allow them." }
            }
            return
        }
        let runtime: URL, node: String
        do {
            runtime = try BundledTools.script("component-catalog/server.mjs").deletingLastPathComponent()
            node = try BundledTools.catalogueNode(projectRoot: map.rootPath).path
        } catch { status.stringValue = error.localizedDescription; return }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = URL(fileURLWithPath: node).deletingLastPathComponent().path
            + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        environment.removeValue(forKey: "NODE_OPTIONS")
        environment.removeValue(forKey: "NODE_PATH")
        let checksum = map.rootPath.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 1800 }
        let port = 4400 + checksum
        address.stringValue = "http://127.0.0.1:\(port)"
        let root = URL(fileURLWithPath: map.rootPath, isDirectory: true).standardizedFileURL
        let scoped = root.startAccessingSecurityScopedResource()
        let pipe = Pipe(), process = Process()
        let supervised = ChildProcessWatchdog.wrap(executable: URL(fileURLWithPath: node),
                                                   arguments: [runtime.appendingPathComponent("server.mjs").path, root.path, String(port)])
        process.executableURL = supervised.executable
        process.arguments = supervised.arguments
        process.environment = environment; process.currentDirectoryURL = root
        process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
        helperOutput = ""; helperPipe = pipe; helperScopedURL = scoped ? root : nil
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.helperOutput = String(((self?.helperOutput ?? "") + text).suffix(12_000)) }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            guard let process else { return }
            Task { @MainActor [weak self] in
                guard let self, self.helperProcess === process else { return }
                self.helperPipe?.fileHandleForReading.readabilityHandler = nil
                self.helperPipe = nil; self.helperProcess = nil
                if let scoped = self.helperScopedURL { scoped.stopAccessingSecurityScopedResource() }
                self.helperScopedURL = nil
                if self.overlay != nil {
                    self.generation += 1
                    self.connecting = false; self.connection = nil; self.projectID = nil; self.componentIDs = []
                    self.changeSection()
                    self.status.isHidden = false
                    let detail = self.helperOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.status.stringValue = detail.isEmpty ? "Live previews stopped. Click Refresh to restart." : "Live previews stopped. Click Refresh to restart. " + String(detail.suffix(500))
                }
            }
        }
        do {
            try process.run(); helperProcess = process
            status.isHidden = false; status.stringValue = "Found \(map.components.count) candidates. Rendering components from project source…"
            generation += 1; let attempt = generation
            Task { [weak self] in
                for _ in 0..<24 {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard let self, self.generation == attempt, self.overlay != nil, self.helperProcess?.isRunning == true else { return }
                    // The helper moves to a nearby port when this one is taken
                    // and reports the one it bound first on stdout.
                    guard let actual = Self.reportedPort(in: self.helperOutput) else { continue }
                    let url = URL(string: "http://127.0.0.1:\(actual)")!
                    self.address.stringValue = url.absoluteString
                    do {
                        var request = URLRequest(url: url.appendingPathComponent("catalog.json")); request.timeoutInterval = 1
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                              let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                              manifest["protocol"] as? String == "webframes-catalog-v1",
                              let rootPath = manifest["root"] as? String,
                              URL(fileURLWithPath: rootPath).standardizedFileURL.path == root.path,
                              let id = manifest["projectId"] as? String,
                              let items = manifest["components"] as? [[String: Any]] else { continue }
                        self.activateCatalogue(url: url, id: id, components: items); return
                    } catch { continue }
                }
                guard let self, self.generation == attempt else { return }
                self.status.stringValue = "Component renderer did not start. " + String(self.helperOutput.trimmingCharacters(in: .whitespacesAndNewlines).suffix(500))
            }
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            if scoped { root.stopAccessingSecurityScopedResource() }
            helperPipe = nil; helperScopedURL = nil
            status.stringValue = "Could not start component renderer. \(error.localizedDescription)"
        }
    }
    nonisolated static func reportedPort(in output: String) -> Int? {
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("WEBFRAMES_CATALOG_PORT=") }),
              let port = Int(line.dropFirst("WEBFRAMES_CATALOG_PORT=".count)), (1024...65535).contains(port) else { return nil }
        return port
    }
    private func stopLocalCatalogue() {
        helperPipe?.fileHandleForReading.readabilityHandler = nil
        helperPipe = nil
        if let process = helperProcess, process.isRunning {
            process.interrupt()
            // Vite can ignore SIGINT while a build is in flight.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak process] in
                if let process, process.isRunning { process.terminate() }
            }
        }
        helperProcess = nil
        if let scoped = helperScopedURL { scoped.stopAccessingSecurityScopedResource() }
        helperScopedURL = nil
    }
    nonisolated static func localOrigin(_ raw: String) -> URL? {
        guard let parts = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "http", parts.host == "127.0.0.1", let port = parts.port, (1024...65535).contains(port),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let origin = connection, let source = message.frameInfo.request.url,
              source.host == origin.host, source.port == origin.port, source.scheme == origin.scheme,
              let body = message.body as? [String: Any], body["projectId"] as? String == projectID else { return }
        if body["action"] as? String == "catalogLoaded", let ids = body["ids"] as? [String], ids.count <= 10_000,
           ids.allSatisfy({ $0.count == 16 && $0.allSatisfy({ $0.isHexDigit }) }) {
            componentIDs = Set(ids)
            return
        }
        guard body["action"] as? String == "addComponent",
              let raw = body["url"] as? String, raw.utf8.count < 64_000,
              let url = URL(string: raw), url.host == origin.host, url.port == origin.port, url.scheme == origin.scheme,
              url.user == nil, url.password == nil, url.path == "/preview.html",
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              componentIDs.contains(id),
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "project" })?.value == projectID,
              let project else { return }
        let name = String((body["name"] as? String ?? "Component").prefix(120))
        let width = CGFloat(min(1280, max(320, body["width"] as? Double ?? 640)))
        let frame = FrameModel(id: UUID().uuidString, url: raw, label: name, x: 80,
                               y: (project.workspace.frames.map { $0.y + $0.h }.max() ?? -80) + 160,
                               w: width, h: 480, num: project.workspace.nextFrameNum, isImage: false, filePath: nil)
        project.workspace.createFrame(frame)
        owner?.canvasHost.bridge.setAllFramesVisible(false)
        owner?.canvasHost.selectFrame(frame.id)
        status.stringValue = "Added \(name) to the canvas. Close the catalogue to see it."
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == true || navigationAction.targetFrame == nil {
            guard let url = navigationAction.request.url, let connection, url.scheme == connection.scheme, url.host == connection.host, url.port == connection.port else { decisionHandler(.cancel); return }
        }
        decisionHandler(.allow)
    }
}
@MainActor private final class WeakCatalogueHandler: NSObject, WKScriptMessageHandler {
    private weak var target: ComponentCatalogueController?
    init(_ target: ComponentCatalogueController) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { target?.userContentController(userContentController, didReceive: message) }
}

private final class LibraryRows: NSStackView { override var isFlipped: Bool { true } }
