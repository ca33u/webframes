import Foundation

/// Release helpers resolve exclusively inside the installed app, never the developer checkout.
nonisolated enum BundledTools {
    static func script(_ relativePath: String) throws -> URL {
        let fm = FileManager.default
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Tools").appendingPathComponent(relativePath),
           fm.fileExists(atPath: url.path) { return url }
        #if DEBUG
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools").appendingPathComponent(relativePath)
        if fm.fileExists(atPath: source.path) { return source }
        #endif
        throw ConnectionSettingsError.message("A helper is missing from this build. Reinstall Web Frames.")
    }

    static func node() throws -> URL {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/node")
        if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        #if DEBUG
        if let path = executable("node") { return URL(fileURLWithPath: path) }
        #endif
        throw ConnectionSettingsError.message("The bundled runtime is missing. Reinstall Web Frames.")
    }

    /// Project PostCSS plugins may contain native modules signed by other teams.
    /// Run those project tools with the user's existing Node, as with their dev server.
    /// The bundled runtime keeps library validation enabled.
    static func catalogueNode(projectRoot: String) throws -> URL {
        let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
        let configNames = ["postcss.config.mjs", "postcss.config.cjs", "postcss.config.js",
                           "postcss.config.ts", ".postcssrc", ".postcssrc.json", ".postcssrc.yml",
                           ".postcssrc.yaml", ".postcssrc.js", ".postcssrc.cjs", ".postcssrc.mjs"]
        let hasConfig = configNames.contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        let package = (try? Data(contentsOf: root.appendingPathComponent("package.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if hasConfig || package?["postcss"] != nil {
            if let path = executable("node"), !path.hasPrefix(Bundle.main.bundleURL.path + "/") {
                return URL(fileURLWithPath: path)
            }
            throw ConnectionSettingsError.message("This project's CSS plugins need its own Node.js (22.12+). Install the project's runtime, then refresh Library.")
        }
        return try node()
    }

    static func executable(_ name: String) -> String? {
        let fm = FileManager.default, home = FileManager.default.homeDirectoryForCurrentUser
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let nvmBins = ((try? fm.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .map { $0.appendingPathComponent("bin").path }
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", home.appendingPathComponent(".volta/bin").path,
               home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".cargo/bin").path,
               "/usr/bin", "/bin"] + nvmBins
        return paths.map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) }
    }

    static func codex() throws -> URL {
        let fm = FileManager.default
        var paths = [ProcessInfo.processInfo.environment["WEBFRAMES_CODEX_BINARY"]].compactMap { $0 }
        for folder in [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            for app in ["Codex.app", "ChatGPT.app"] {
                paths.append(folder.appendingPathComponent(app + "/Contents/Resources/codex").path)
            }
        }
        if let path = executable("codex") { paths.append(path) }
        guard let path = paths.first(where: { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) }) else {
            throw ConnectionSettingsError.message("Install Codex and sign in, then click Connect Codex again.")
        }
        return URL(fileURLWithPath: path)
    }

    static func claude() throws -> URL {
        let fm = FileManager.default
        var paths = [ProcessInfo.processInfo.environment["WEBFRAMES_CLAUDE_BINARY"]].compactMap { $0 }
        paths.append(fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/local/claude").path)
        if let path = executable("claude") { paths.append(path) }
        guard let path = paths.first(where: { $0.hasPrefix("/") && fm.isExecutableFile(atPath: $0) }) else {
            throw ConnectionSettingsError.message("Install Claude Code and run `claude` once to sign in, then click Connect Claude again.")
        }
        return URL(fileURLWithPath: path)
    }

    static func agent(_ provider: AgentProvider) throws -> URL {
        switch provider {
        case .codex: return try codex()
        case .claude: return try claude()
        }
    }
}
