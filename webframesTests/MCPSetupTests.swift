import AppKit
import Testing
@testable import Web_Frames

@Suite("MCP setup") struct MCPSetupTests {
    @MainActor @Test func wizardAccessoryFitsInsideAlertAndCanBeLaidOutAgain() throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        let wizard = MCPSetupWizard(parent: parent, entries: [ProjectStorage.Entry(url: URL(fileURLWithPath: "/tmp/board.webframes"), displayName: "WF-06 — QA board", modifiedAt: Date())])
        for _ in 0..<2 {
            let alert = wizard.selectionAlert()
            alert.layout()
            let accessory = try #require(alert.accessoryView)
            accessory.layoutSubtreeIfNeeded()
            #expect(accessory.frame.width == 500)
            #expect(accessory.frame.height > 150)
            let content = try #require(alert.window.contentView)
            #expect(content.bounds.contains(accessory.convert(accessory.bounds, to: content)))
            #expect(accessory.subviews.allSatisfy { accessory.bounds.contains($0.frame) }, "Accessory \(accessory.bounds); controls \(accessory.subviews.map(\.frame))")
            if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/wf06-wizard-layout.png"))
            }
        }
    }
    func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wf-mcp-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    let config = ClaudeMCPConfiguration(nodePath: "/opt/node", scriptPath: "/Applications/Web Frames.app/helper.mjs", projectPath: "/tmp/one.webframes")

    @Test func installPreservesOtherServersSettingsAndCreatesPrivateExactBackup() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("client.json")
        let original = Data((#"{"theme":"dark","mcpServers":{"other":{"command":"other","env":{"TOKEN":"private-fixture"}},"webframes-one":{"command":"old"}}}"#.replacingOccurrences(of: "webframes-one", with: config.serverName)).utf8)
        try original.write(to: file)
        let plan = try MCPInstallPlan.prepare(configuration: config, at: file)
        let installedBackup = try plan.install()
        let backup = try #require(installedBackup)
        #expect(try Data(contentsOf: backup) == original)
        let saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(saved["theme"] as? String == "dark")
        let servers = try #require(saved["mcpServers"] as? [String: [String: Any]])
        #expect(servers["other"]?["command"] as? String == "other")
        #expect(servers[config.serverName]?["args"] as? [String] == config.arguments)
        for url in [backup, file] {
            #expect((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        }
        #expect(try MCPInstallPlan.prepare(configuration: config, at: file).install() == nil)
    }

    @Test func refusesMalformedSymlinkAndConcurrentEditsWithoutOverwriting() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("client.json")
        for value in ["not json", "[]", #"{"mcpServers":[]}"#] {
            try Data(value.utf8).write(to: file)
            #expect(throws: (any Error).self) { try MCPInstallPlan.prepare(configuration: config, at: file) }
            #expect(try String(contentsOf: file, encoding: .utf8) == value)
        }
        try Data("{}".utf8).write(to: file)
        let plan = try MCPInstallPlan.prepare(configuration: config, at: file)
        try Data(#"{"changed":true}"#.utf8).write(to: file)
        #expect(throws: (any Error).self) { try plan.install() }
        #expect(try String(contentsOf: file, encoding: .utf8) == #"{"changed":true}"#)
        let link = root.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: (any Error).self) { try MCPInstallPlan.prepare(configuration: config, at: link) }
    }

    @Test func clientsUseTheirOwnPathsAndNewConfigIsPrivate() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(MCPClient.desktop.configurationURL(home: root)?.path.hasSuffix("Claude/claude_desktop_config.json") == true)
        #expect(MCPClient.code.configurationURL(home: root, environment: [:]) == root.appendingPathComponent(".claude.json"))
        #expect(MCPClient.code.configurationURL(home: root, environment: ["CLAUDE_CONFIG_DIR": root.path]) == root.appendingPathComponent(".claude.json"))
        #expect(MCPClient.other.configurationURL(home: root) == nil)
        let file = root.appendingPathComponent("nested/client.json")
        #expect(try MCPInstallPlan.prepare(configuration: config, at: file).install() == nil)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func probeConnectsToBundledHelperAndRejectsMissingBoard() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("one.webframes")
        try Data(#"{"name":"MCP QA","frames":[],"annotations":[]}"#.utf8).write(to: file)
        let configuration = try ClaudeMCPConfiguration.resolve(projectURL: file)
        let status = try await MCPConnectionProbe.check(configuration)
        #expect(status.contains("Connected") && status.contains("10 tools") && status.contains("1 saved projects"))
        try FileManager.default.removeItem(at: file)
        await #expect(throws: (any Error).self) { try await MCPConnectionProbe.check(configuration) }
    }

    @Test(.enabled(if: BundledTools.executable("claude") != nil))
    func installedClaudeCodeConnectsUsingInstallerInAnIsolatedProfile() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let board = root.appendingPathComponent("QA board's variants.webframes")
        try Data(#"{"name":"Client QA","frames":[],"annotations":[]}"#.utf8).write(to: board)
        let configuration = try ClaudeMCPConfiguration.resolve(projectURL: board)
        #expect(configuration.serverName.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        let file = try #require(MCPClient.code.configurationURL(home: root, environment: ["CLAUDE_CONFIG_DIR": root.path]))
        try MCPInstallPlan.prepare(configuration: configuration, at: file).install()
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: try #require(BundledTools.executable("claude")))
        process.arguments = ["mcp", "get", configuration.serverName]
        process.currentDirectoryURL = root
        process.environment = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": root.path,
                               "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
        defer { timeout.cancel(); if process.isRunning { process.terminate() } }
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let result = String(decoding: output, as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(result.contains("Connected"), "Claude Code did not report a connected MCP server: \(result)")
    }

    @Test func probeRejectsMalformedRepliesAndTimesOut() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let node = try BundledTools.node().path
        for source in ["process.stdin.resume(); process.stdin.on('end',()=>process.stdout.write('broken reply\\n'));",
                       "process.stdin.resume(); setInterval(()=>{},1000);"] {
            let script = root.appendingPathComponent(UUID().uuidString + ".mjs")
            try Data(source.utf8).write(to: script)
            let config = ClaudeMCPConfiguration(nodePath: node, scriptPath: script.path, projectPath: nil)
            let start = Date()
            await #expect(throws: (any Error).self) { try await MCPConnectionProbe.check(config, timeout: 0.3) }
            #expect(Date().timeIntervalSince(start) < 5)
        }
    }
}
