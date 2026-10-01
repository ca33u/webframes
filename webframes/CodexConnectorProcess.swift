import Foundation

/// App-owned loopback connector. Never installs Codex, reads login tokens or starts an AI run.
@MainActor final class CodexConnectorProcess {
    static let shared = CodexConnectorProcess()
    private var process: Process?
    private var pipe: Pipe?
    private(set) var runDirectory: URL?
    private var cached: AstraCodexConnection?

    /// Provider and model the running connector was started with.
    private var runningConfiguration: String?

    func start() async throws -> AstraCodexConnection {
        let configuration = AgentProvider.current.rawValue + "|" + (AgentProvider.current.model ?? "")
        if process?.isRunning == true, let cached, runningConfiguration == configuration { return cached }
        stop()
        let node = try BundledTools.node()
        let script = try BundledTools.script("codex-bridge.mjs")
        let provider = AgentProvider.current
        let agent = try BundledTools.agent(provider)
        try EvidenceStore.privateDirectory(EvidenceStore.connectorDirectory)
        let directory = try EvidenceStore.privateDirectory(
            EvidenceStore.connectorDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
        runDirectory = directory
        runningConfiguration = configuration
        let child = Process(), output = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["WEBFRAMES_BRIDGE_ROOT"] = directory.path
        environment["WEBFRAMES_AGENT_PROVIDER"] = provider.rawValue
        environment["WEBFRAMES_AGENT_MODEL"] = provider.model ?? ""
        environment[provider.binaryOverrideKey] = agent.path
        environment["PATH"] = node.deletingLastPathComponent().path + ":" + agent.deletingLastPathComponent().path
            + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        // Caller-provided Node injection flags must not alter the bundled connector.
        environment.removeValue(forKey: "NODE_OPTIONS")
        environment.removeValue(forKey: "NODE_PATH")
        child.executableURL = node; child.arguments = [script.path]
        child.currentDirectoryURL = directory; child.environment = environment
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = output; child.standardError = output
        // Drain output so a long-running helper cannot block on a full pipe. No credentials are logged.
        output.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        process = child; pipe = output
        child.terminationHandler = { [weak self] terminated in
            Task { @MainActor [weak self] in
                guard let self, self.process === terminated else { return }
                self.stop()
                CodexConnectionStore.shared.managedConnectorStopped()
            }
        }
        do {
            try child.run()
            let file = directory.appendingPathComponent("connection.json")
            for _ in 0..<80 {
                try Task.checkCancellation()
                guard child.isRunning else { throw ConnectionSettingsError.message("The \(provider.name) connector stopped. Try Connect \(provider.name) again.") }
                if let data = try? Data(contentsOf: file), data.count < 16_384,
                   let connection = try? JSONDecoder().decode(AstraCodexConnection.self, from: data) {
                    _ = try connection.validatedURL()
                    cached = connection
                    return connection
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ConnectionSettingsError.message("The \(provider.name) connector did not start. Try Connect \(provider.name) again.")
        } catch { stop(); throw error }
    }

    func stop() {
        let child = process
        process = nil; cached = nil
        child?.terminationHandler = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        pipe = nil
        if child?.isRunning == true { child?.terminate() }
        // The connector deletes each job's folder when it finishes; remove the
        // pairing credential and anything a killed run left behind.
        if let directory = runDirectory { try? FileManager.default.removeItem(at: directory) }
        runDirectory = nil
    }
}
