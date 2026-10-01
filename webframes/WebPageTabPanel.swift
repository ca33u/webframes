import AppKit
import Network
import os
import UniformTypeIdentifiers

// MARK: - WebPageTabPanel

/// Adds any single web page. Localhost discovery lives here because a local
/// page and a deployed page produce the same frame; only address discovery
/// and the default scheme differ.
final class WebPageTabPanel: NSView, AddFrameTabPanel {

    var view: NSView { self }

    private let discovery: LocalServerDiscovery
    private var scanGeneration = 0
    private let urlField   = NSTextField()
    private let labelField = NSTextField()
    private lazy var sizeRow = SizeControlRow(onChange: onValidityChange)
    private let onValidityChange: () -> Void

    // Scanner controls — the header row is [label][flex][status][button].
    // Chips render inside an inner horizontal stack that lives in a wrapper
    // (`scanResultsRow`) so we can hide/show the whole row and still allow
    // the inner stack to stretch (NSStackView in a parent `.fill` stack
    // gets full width for free).
    private let scanBtn = NSButton(image: NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "Find running web servers")!, target: nil, action: nil)
    private let scanStatusLabel = NSTextField(labelWithString: "")
    private let serverSuggestions = NSPopUpButton()
    private var scanTask: Task<Void, Never>?

    init(discovery: LocalServerDiscovery, onValidityChange: @escaping () -> Void) {
        self.discovery = discovery
        self.onValidityChange = onValidityChange
        super.init(frame: .zero)
        build()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        urlField.placeholderString = "https://example.com or http://localhost:3000"
        urlField.font = .systemFont(ofSize: 13)
        urlField.delegate = self
        urlField.translatesAutoresizingMaskIntoConstraints = false

        labelField.placeholderString = "Frame name"
        labelField.font = .systemFont(ofSize: 13)
        labelField.translatesAutoresizingMaskIntoConstraints = false

        scanBtn.target = self
        scanBtn.action = #selector(scanTapped)
        scanBtn.bezelStyle = .rounded
        scanBtn.toolTip = "Find running web servers"
        let urlHeader = makeFieldLabel("Page URL")
        let addressIcon = NSImageView(image: NSImage(systemSymbolName: "globe", accessibilityDescription: "Web page")!)
        addressIcon.contentTintColor = WFDesign.text2
        addressIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
        let address = NSStackView(views: [addressIcon, urlField, scanBtn])
        address.spacing = 8; address.alignment = .centerY
        serverSuggestions.target = self; serverSuggestions.action = #selector(useSuggestedServer(_:))
        serverSuggestions.isHidden = true
        scanStatusLabel.font = .systemFont(ofSize: 11)
        scanStatusLabel.textColor = WFDesign.text2
        scanStatusLabel.isHidden = true

        let root = NSStackView(views: [
            urlHeader, address, serverSuggestions, scanStatusLabel,
            makeFieldLabel("Frame name (optional)"), labelField,
            sizeRow,
        ])
        root.orientation = .vertical
        // AppKit NSStackView has no `.fill` alignment value — use `.leading`
        // and pin child widths to the stack explicitly (done below).
        root.alignment = .leading
        root.spacing = 10
        // Tighten the gap between the URL header and the field so the scan
        // button reads as belonging to the URL row, and tighten the gap
        // between the URL field and the chip strip so the chips read as
        // "suggestions for the field above".
        root.setCustomSpacing(4, after: urlHeader)
        root.setCustomSpacing(6, after: address)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Stretch each row to the stack's full width.
            urlHeader.widthAnchor.constraint(equalTo: root.widthAnchor),
            address.widthAnchor.constraint(equalTo: root.widthAnchor),
            labelField.widthAnchor.constraint(equalTo: root.widthAnchor),
            sizeRow.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
    }

    func currentSpec() -> [String: Any]? {
        let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "kind":  "web",
            "url":   url,
            "label": label,
            "w":     sizeRow.width,
            "h":     sizeRow.height,
        ]
    }

    func reset() {
        scanGeneration += 1
        scanTask?.cancel()
        scanTask = nil
        urlField.stringValue = ""
        labelField.stringValue = ""
        sizeRow.applyPreset(index: 1)
        scanBtn.isEnabled = true
        scanStatusLabel.stringValue = ""
        scanStatusLabel.isHidden = true
        clearChips()
        serverSuggestions.isHidden = true
    }

    func willAppear() {
        refreshServers(force: false)
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self?.urlField)
        }
    }

    // MARK: - Scanner

    @objc private func scanTapped() { refreshServers(force: true) }

    private func refreshServers(force: Bool) {
        scanGeneration += 1
        let generation = scanGeneration
        scanTask?.cancel()
        scanBtn.isEnabled = false
        populateChips(ports: discovery.ports)
        scanStatusLabel.stringValue = "Searching…"
        scanStatusLabel.isHidden = false
        scanTask = Task { [weak self] in
            guard let self else { return }
            let found = await discovery.discover(address: urlField.stringValue, force: force)
            guard !Task.isCancelled, generation == scanGeneration else { return }
            scanBtn.isEnabled = true
            scanStatusLabel.stringValue = found.isEmpty ? "No local web servers found" : "\(found.count) running web servers"
            populateChips(ports: found)
        }
    }

    private func clearChips() { serverSuggestions.removeAllItems() }

    private func populateChips(ports: [Int]) {
        clearChips()
        serverSuggestions.addItem(withTitle: "Use a running server…")
        if let address = discovery.projectAddress {
            serverSuggestions.addItem(withTitle: "Project · \(address)")
            serverSuggestions.lastItem?.representedObject = address
        }
        for port in ports {
            let address = "http://localhost:\(port)"
            serverSuggestions.addItem(withTitle: address)
            serverSuggestions.lastItem?.representedObject = address
        }
        serverSuggestions.isHidden = serverSuggestions.numberOfItems <= 1
    }

    @objc private func useSuggestedServer(_ sender: NSPopUpButton) {
        guard let address = sender.selectedItem?.representedObject as? String else { return }
        urlField.stringValue = address
        sender.selectItem(at: 0)
        onValidityChange()
    }

    /// Probes `ports` in parallel and returns those that returned any HTTP
    /// response (including 4xx/5xx — the server is listening, which is all
    /// we need). The returned array is sorted so chip order is stable.
    nonisolated static func scanLocalhost(ports: [Int], timeout: TimeInterval) async -> [Int] {
        await withTaskGroup(of: Int?.self) { group in
            for port in ports {
                group.addTask {
                    guard await probePort(port, timeout: timeout) else { return nil }
                    return await LocalServerDiscovery.responds("http://127.0.0.1:\(port)", timeout: 2) ? port : nil
                }
            }
            var open: [Int] = []
            for await maybe in group {
                if let p = maybe { open.append(p) }
            }
            return open.sorted()
        }
    }

    /// TCP preflight distinguishes an unused port from a listening service.
    /// Discovery additionally requires an HTTP response before suggesting it.
    nonisolated static func probePort(_ port: Int, timeout: TimeInterval) async -> Bool {
        guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
            let queue = DispatchQueue.global(qos: .userInitiated)
            let done = OSAllocatedUnfairLock(initialState: false)

            let finish: @Sendable (Bool) -> Void = { result in
                let shouldResume = done.withLock { settled -> Bool in
                    guard !settled else { return false }
                    settled = true
                    return true
                }
                if shouldResume {
                    conn.cancel()
                    cont.resume(returning: result)
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:        finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

extension WebPageTabPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { onValidityChange() }
    func controlTextDidEndEditing(_ obj: Notification) {
        if obj.object as? NSTextField === urlField { refreshServers(force: false) }
    }
}
