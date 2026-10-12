import Foundation
import Darwin

/// Both clients use mcpServers at the JSON root. Only our entry is replaced.
nonisolated enum MCPClient: String, CaseIterable {
    case desktop = "Claude Desktop", code = "Claude Code", other = "Other MCP client"
    func configurationURL(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        switch self {
        case .desktop: return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .code:
            if let custom = environment["CLAUDE_CONFIG_DIR"], custom.hasPrefix("/") {
                return URL(fileURLWithPath: custom).appendingPathComponent(".claude.json")
            }
            return home.appendingPathComponent(".claude.json")
        case .other: return nil
        }
    }
}

nonisolated struct MCPInstallPlan {
    let url: URL
    let previous: Data?
    let updated: Data

    static func prepare(configuration: ClaudeMCPConfiguration, at url: URL) throws -> Self {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values?.isSymbolicLink != true, (values?.fileSize ?? 0) <= 4_000_000 else {
            throw ConnectionSettingsError.message("The client config is a symbolic link or too large. Configure this client manually.")
        }
        let previous = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        var object: [String: Any] = [:]
        if let previous {
            guard let parsed = try JSONSerialization.jsonObject(with: previous) as? [String: Any] else {
                throw ConnectionSettingsError.message("The client config must contain a JSON object. It was not changed.")
            }
            object = parsed
        }
        if let existing = object["mcpServers"], !(existing is [String: Any]) {
            throw ConnectionSettingsError.message("The client's mcpServers must be a JSON object. It was not changed.")
        }
        var servers = object["mcpServers"] as? [String: Any] ?? [:]
        servers[configuration.serverName] = ["command": configuration.nodePath, "args": configuration.arguments]
        object["mcpServers"] = servers
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return Self(url: url, previous: previous, updated: updated)
    }

    /// Called only after the user reviews the destination and access scope.
    @discardableResult func install() throws -> URL? {
        let fm = FileManager.default
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw ConnectionSettingsError.message("The client config changed. Review setup again.")
        }
        let current = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
        guard current == previous else { throw ConnectionSettingsError.message("The client config changed. Review setup again; nothing was overwritten.") }
        if current == updated { return nil }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        if let previous {
            let destination = url.appendingPathExtension("webframes-backup-" + UUID().uuidString)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard fm.createFile(atPath: destination.path, contents: previous, attributes: [.posixPermissions: 0o600]) else {
                throw ConnectionSettingsError.message("Could not back up the client config. Nothing was changed.")
            }
            backup = destination
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".webframes-mcp-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw ConnectionSettingsError.message("Could not create a private client config. Nothing was changed.") }
        defer { try? fm.removeItem(at: temporary) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: updated); try handle.synchronize(); try handle.close()
        guard rename(temporary.path, url.path) == 0 else {
            throw ConnectionSettingsError.message("Could not replace the client config. Your previous config and backup are intact.")
        }
        return backup
    }
}

nonisolated enum MCPConnectionProbe {
    static func check(_ configuration: ClaudeMCPConfiguration, timeout: TimeInterval = 8) async throws -> String {
        try await Task.detached {
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: configuration.nodePath)
            process.arguments = configuration.arguments
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            defer { watchdog.cancel(); if process.isRunning { process.terminate() } }
            let messages: [[String: Any]] = [
                ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2024-11-05", "capabilities": [:], "clientInfo": ["name": "Web Frames setup", "version": "1"]]],
                ["jsonrpc": "2.0", "method": "notifications/initialized"],
                ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
                ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "list_projects", "arguments": ["limit": 1]]],
            ]
            var request = Data()
            for message in messages { request.append(try JSONSerialization.data(withJSONObject: message)); request.append(10) }
            try input.fileHandleForWriting.write(contentsOf: request)
            try input.fileHandleForWriting.close()
            // Drain continuously, keeping bounded output even for a broken helper.
            var data = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty {
                guard data.count + chunk.count <= 256_000 else { throw ConnectionSettingsError.message("The MCP helper returned too much data. Reinstall Web Frames.") }
                data.append(chunk)
            }
            process.waitUntilExit()
            let replies = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            let byID = Dictionary(replies.compactMap { r -> (Int, [String: Any])? in
                guard let id = r["id"] as? Int, let result = r["result"] as? [String: Any] else { return nil }; return (id, result)
            }, uniquingKeysWith: { _, last in last })
            guard process.terminationStatus == 0,
                  let info = byID[1]?["serverInfo"] as? [String: Any], info["name"] as? String == "webframes-comments",
                  let tools = byID[2]?["tools"] as? [[String: Any]],
                  Set(tools.compactMap { $0["name"] as? String }).isSuperset(of: ["list_projects", "list_comments", "list_sections", "get_frame"]),
                  byID[3]?["isError"] as? Bool != true,
                  let content = byID[3]?["content"] as? [[String: Any]], let text = content.first?["text"] as? String,
                  let page = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let pagination = page["pagination"] as? [String: Any], let total = pagination["total"] as? Int,
                  configuration.projectPath == nil || total == 1 else {
                throw ConnectionSettingsError.message("MCP check failed or timed out. Reinstall Web Frames or check that the selected board still exists.")
            }
            return "Connected · \(tools.count) tools · \(total) saved projects"
        }.value
    }
}
