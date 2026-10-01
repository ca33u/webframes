import Foundation
import os

nonisolated enum ConnectionProvider: String, CaseIterable, Sendable {
    case github, openai, anthropic, gemini
    var title: String {
        switch self { case .github: return "GitHub"; case .openai: return "OpenAI"; case .anthropic: return "Anthropic"; case .gemini: return "Google Gemini" }
    }
    var keychainKey: String { self == .github ? "gh_token" : "api_\(rawValue)_key" }
    var endpoint: URL {
        switch self {
        case .github: return URL(string: "https://api.github.com/user")!
        case .openai: return URL(string: "https://api.openai.com/v1/models")!
        case .anthropic: return URL(string: "https://api.anthropic.com/v1/models?limit=1")!
        case .gemini: return URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")!
        }
    }
    var purpose: String {
        self == .github ? "Access private repositories when adding GitHub frames." : "Save an API key and verify access. Canvas AI actions currently use Codex."
    }
    func request(token: String) throws -> URLRequest {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 8192,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw ConnectionSettingsError.message("Enter a valid key without spaces or line breaks.")
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch self {
        case .github, .openai: request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(value, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .gemini: request.setValue(value, forHTTPHeaderField: "x-goog-api-key")
        }
        if self == .github { request.setValue("WebFrames", forHTTPHeaderField: "User-Agent") }
        return request
    }
}

nonisolated enum ConnectionSettingsError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

/// Credentials are sent only to the selected provider's fixed HTTPS endpoint.
/// Refuse all redirects, including ones that would forward nonstandard API-key headers.
nonisolated final class ConnectionRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

nonisolated enum ConnectionProbe {
    static func check(_ provider: ConnectionProvider, token: String) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: ConnectionRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: provider.request(token: token))
        return try result(provider, data: data, response: response)
    }
    static func result(_ provider: ConnectionProvider, data: Data, response: URLResponse) throws -> String {
        guard let http = response as? HTTPURLResponse else { throw ConnectionSettingsError.message("Invalid response. Try again.") }
        switch http.statusCode {
        case 200..<300: break
        case 401: throw ConnectionSettingsError.message("Key rejected. Replace it and try again.")
        case 403: throw ConnectionSettingsError.message("Access denied. Check the key’s permissions and account access.")
        case 429: throw ConnectionSettingsError.message("Rate limit reached. Try again later.")
        case 300..<400: throw ConnectionSettingsError.message("Unexpected redirect. The key was not forwarded.")
        default: throw ConnectionSettingsError.message("Provider returned HTTP \(http.statusCode). Try again later.")
        }
        guard data.count <= 2_000_000, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectionSettingsError.message("Unexpected response from provider.")
        }
        if provider == .github {
            guard let login = json["login"] as? String, !login.isEmpty else { throw ConnectionSettingsError.message("GitHub account could not be verified.") }
            return "Verified · \(String(login.prefix(80)))"
        }
        let key = provider == .gemini ? "models" : "data"
        guard json[key] is [[String: Any]] else { throw ConnectionSettingsError.message("Provider did not return a model list.") }
        return "Verified · API access available"
    }
}

@MainActor final class CodexConnectionStore {
    static let shared = CodexConnectionStore()
    static let changed = Notification.Name("WebFramesCodexConnectionChanged")
    private let key = "codex_connector_connection"
    private(set) var client: AstraCodexClient?
    private(set) var status = "Not connected"
    private(set) var isChecking = false
    private(set) var isVerified = false
    private var connection: AstraCodexConnection?
    private init() {
        if case .success(let json) = KeychainHelper.load(key: key), let data = json.data(using: .utf8),
           let connection = try? JSONDecoder().decode(AstraCodexConnection.self, from: data),
           let client = try? AstraCodexClient(connection: connection) {
            self.connection = connection; self.client = client; status = "Saved · connection not checked"
        }
    }
    private let managedKey = "webframes.managedCodexConnection"
    private func notify() { NotificationCenter.default.post(name: Self.changed, object: nil) }
    private func establish(_ connection: AstraCodexConnection) async throws {
        let candidate = try AstraCodexClient(connection: connection)
        try await candidate.health()
        let data = try JSONEncoder().encode(connection)
        try KeychainHelper.save(key: key, value: String(decoding: data, as: UTF8.self)).get()
        self.connection = connection; client = candidate; isVerified = true; status = "Connected · \(AgentProvider.current.productName)" + (AgentProvider.current.model.map { " · \($0)" } ?? "")
    }
    func connect(_ connection: AstraCodexConnection) async throws {
        guard !isChecking else { return }
        isChecking = true; status = "Checking local connector…"; notify()
        defer { isChecking = false; notify() }
        do {
            try await establish(connection)
            UserDefaults.standard.set(false, forKey: managedKey)
            CodexConnectorProcess.shared.stop()
        } catch { isVerified = false; status = error.localizedDescription; throw error }
    }
    func connectManaged() async throws {
        guard !isChecking else { return }
        isChecking = true; status = "Starting \(AgentProvider.current.productName) connector…"; notify()
        defer { isChecking = false; notify() }
        do {
            let connection = try await CodexConnectorProcess.shared.start()
            try await establish(connection)
            UserDefaults.standard.set(true, forKey: managedKey)
        } catch {
            CodexConnectorProcess.shared.stop()
            client = nil; connection = nil; isVerified = false; status = error.localizedDescription
            throw error
        }
    }
    func restoreManagedConnection() {
        guard UserDefaults.standard.bool(forKey: managedKey) else { return }
        Task {
            do { try await connectManaged() }
            catch {
                Log.doc.error("Codex connector restore failed: \(error.localizedDescription, privacy: .public)")
                status = "Could not reconnect \(AgentProvider.current.name) at launch: " + error.localizedDescription + " Click Connect to retry."
                notify()
            }
        }
    }
    func managedConnectorStopped() {
        guard UserDefaults.standard.bool(forKey: managedKey) else { return }
        client = nil; connection = nil; isVerified = false
        status = "\(AgentProvider.current.name) connector stopped. Click Connect to reconnect."; notify()
    }
    func makeClient() -> AstraCodexClient? {
        guard let connection else { return nil }
        return try? AstraCodexClient(connection: connection)
    }
    func check() async throws {
        if UserDefaults.standard.bool(forKey: managedKey) { try await connectManaged(); return }
        guard let connection else { throw ConnectionSettingsError.message("Click Connect \(AgentProvider.current.name) first.") }
        try await connect(connection)
    }
    /// Switching provider or model restarts the managed connector so the next
    /// run uses the new choice; a manual (file-paired) connection is dropped.
    func agentConfigurationChanged() {
        let wasManaged = UserDefaults.standard.bool(forKey: managedKey)
        CodexConnectorProcess.shared.stop()
        client = nil; connection = nil; isVerified = false
        status = "Not connected"; notify()
        if wasManaged { Task { try? await connectManaged() } }
    }

    func disconnect() throws {
        guard !isChecking else { return }
        try KeychainHelper.delete(key: key).get()
        UserDefaults.standard.set(false, forKey: managedKey)
        let old = client
        connection = nil; client = nil; isVerified = false; status = "Not connected"; notify()
        CodexConnectorProcess.shared.stop()
        Task { await old?.cancel() }
    }
}

nonisolated struct ClaudeMCPConfiguration {
    let nodePath: String
    let scriptPath: String
    let projectPath: String?
    var serverName: String {
        projectPath.map { "webframes-" + URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased() } ?? "webframes"
    }
    var arguments: [String] { [scriptPath] + (projectPath.map { ["--project", $0] } ?? []) }
    func desktopJSON() throws -> String {
        let object: [String: Any] = ["mcpServers": [serverName: ["command": nodePath, "args": arguments]]]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
    var codeCommand: String {
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let scope = projectPath == nil ? "user" : "local"
        return "claude mcp add --transport stdio --scope \(scope) \(quote(serverName)) -- \(quote(nodePath)) " + arguments.map(quote).joined(separator: " ")
    }
    static func resolve(projectURL: URL? = nil) throws -> Self {
        let fm = FileManager.default
        if let projectURL, !fm.fileExists(atPath: projectURL.path) {
            throw ConnectionSettingsError.message("Add a frame or comment to save this project, then set up Claude.")
        }
        let script = try BundledTools.script("comments-mcp.mjs")
        let node = try BundledTools.node().path
        return Self(nodePath: node, scriptPath: script.path, projectPath: projectURL?.path)
    }
}
