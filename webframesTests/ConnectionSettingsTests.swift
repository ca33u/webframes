import AppKit
import Testing
@testable import Web_Frames

@Suite("Connection settings") struct ConnectionSettingsTests {
    @Test func providerRequestsKeepSecretsOutOfURLs() throws {
        for provider in ConnectionProvider.allCases {
            let request = try provider.request(token: " test-key-123 ")
            #expect(request.url?.scheme == "https")
            #expect(request.url?.absoluteString.contains("test-key-123") == false)
            #expect(request.httpMethod == "GET")
            #expect(request.httpBody == nil)
            let header = provider == .gemini ? "x-goog-api-key" : (provider == .anthropic ? "x-api-key" : "Authorization")
            #expect(request.value(forHTTPHeaderField: header)?.contains("test-key-123") == true)
        }
        #expect(ConnectionProvider.github.keychainKey == "gh_token")
        #expect(Set(ConnectionProvider.allCases.map(\.keychainKey)).count == 4)
    }
    @Test func rejectsEmptyAndHeaderInjection() {
        for token in ["", "   ", "key\r\nX-Fake: yes", "bad key", "bad\u{0}key"] {
            #expect(throws: (any Error).self) { try ConnectionProvider.github.request(token: token) }
        }
    }
    @Test func checksResponseInsteadOfTrustingHTTP200() throws {
        let provider = ConnectionProvider.github
        let response = HTTPURLResponse(url: provider.endpoint, statusCode: 200, httpVersion: nil, headerFields: nil)!
        #expect(try ConnectionProbe.result(provider, data: Data("{\"login\":\"octocat\"}".utf8), response: response) == "Verified · octocat")
        #expect(throws: (any Error).self) { try ConnectionProbe.result(provider, data: Data("{}".utf8), response: response) }
        #expect(throws: (any Error).self) { try ConnectionProbe.result(.openai, data: Data("<html>login</html>".utf8), response: response) }
        #expect(try ConnectionProbe.result(.openai, data: Data("{\"data\":[]}".utf8), response: response).contains("Verified"))
        #expect(try ConnectionProbe.result(.gemini, data: Data("{\"models\":[]}".utf8), response: response).contains("Verified"))
    }
    @Test func errorsDoNotEchoProviderBodies() {
        for status in [301, 401, 403, 429, 500] {
            let response = HTTPURLResponse(url: ConnectionProvider.openai.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
            do {
                _ = try ConnectionProbe.result(.openai, data: Data("{\"error\":\"echoed-secret\"}".utf8), response: response)
                Issue.record("Expected a provider error")
            } catch { #expect(!error.localizedDescription.contains("echoed-secret")) }
        }
    }
    @Test func claudeConfigurationIsProjectScopedAndEscaped() throws {
        let config = ClaudeMCPConfiguration(nodePath: "/opt/node", scriptPath: "/Applications/Web Frames.app/helper.mjs", projectPath: "/tmp/John's project/123.webframes")
        let data = Data(try config.desktopJSON().utf8)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let servers = try #require(json["mcpServers"] as? [String: [String: Any]])
        let server = try #require(servers[config.serverName])
        #expect(server["command"] as? String == "/opt/node")
        #expect(server["args"] as? [String] == [config.scriptPath, "--project", config.projectPath!])
        #expect(config.codeCommand.contains("--scope local"))
        #expect(config.codeCommand.contains("John'\\''s"))
        #expect(throws: (any Error).self) { try ClaudeMCPConfiguration.resolve(projectURL: URL(fileURLWithPath: "/missing/project.webframes")) }
    }
    @Test func privateGitHubPreviewKeepsTokenOutOfFrameAndRequestURL() throws {
        let frame = GitHubFrameSource.frameURL(owner: "acme", repo: "private", branch: "feature/my-branch", path: "docs/my page.html")
        let url = try #require(URL(string: frame))
        let source = try #require(GitHubFrameSource(url: url))
        let request = try source.request(for: url, token: "secret-value")
        #expect(request.url?.host == "api.github.com")
        #expect(request.url?.path == "/repos/acme/private/contents/docs/my page.html")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "feature/my-branch")
        #expect(!frame.contains("secret-value"))
        #expect(request.url?.absoluteString.contains("secret-value") == false)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-value")
        let asset = try #require(URL(string: "../style.css", relativeTo: url)?.absoluteURL)
        #expect(try source.request(for: asset, token: "secret-value").url?.path == "/repos/acme/private/contents/style.css")
        #expect(throws: (any Error).self) { try source.request(for: URL(string: "https://example.com/steal")!, token: "secret-value") }
    }
    @Test func appWideClaudeConfigurationHasNoProjectDependency() throws {
        let config = ClaudeMCPConfiguration(nodePath: "/opt/node", scriptPath: "/Applications/Web Frames.app/helper.mjs", projectPath: nil)
        let json = try #require(JSONSerialization.jsonObject(with: Data(try config.desktopJSON().utf8)) as? [String: Any])
        let servers = try #require(json["mcpServers"] as? [String: [String: Any]])
        #expect(servers["webframes"]?["args"] as? [String] == [config.scriptPath])
        #expect(config.codeCommand.contains("--scope user"))
        #expect(!config.codeCommand.contains("--project"))
    }
    @MainActor @Test func settingsWindowIsIndependentOfDocuments() {
        let settings = AppSettingsWindowController()
        #expect(settings.document == nil)
        #expect(settings.window?.contentViewController === settings.settingsViewController)
        #expect(settings.window?.identifier?.rawValue == "webframes.appSettings")
        #expect(AppSettingsWindowController.shared === AppSettingsWindowController.shared)
        let document = makeTestDocument()
        let controller = DocumentWindowController(document: document)
        let original = document.workspace.viewport
        controller.showComponentCatalogue()
        let dockHidden = controller.canvasHost.dock.isHidden
        settings.settingsViewController.refresh()
        #expect(controller.canvasHost.dock.isHidden == dockHidden)
        #expect(document.workspace.viewport == original)
        let toolbar = NSToolbar(identifier: "test")
        let item = controller.toolbar(toolbar, itemForItemIdentifier: .init("workspaceMode"), willBeInsertedIntoToolbar: false)
        let modes = item?.view as? NSSegmentedControl
        #expect(modes?.segmentCount == 2)
        #expect(modes?.label(forSegment: 0) == "Flow")
        #expect(modes?.label(forSegment: 1) == "Library")
        controller.close()
        #expect(settings.window?.contentViewController === settings.settingsViewController)
        settings.close()
    }
}
