import Foundation

/// What Codex may see and what an approved fix may write.
enum SourcePolicy {
    /// Files that run code at install or build time or change dependencies.
    /// A fix may still edit them, but only after a separate confirmation:
    /// combined with prompt injection through page content, an approved
    /// diff to one of these is a path to code execution.
    static func isBuildOrConfigFile(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if ["package.json", "package-lock.json", "npm-shrinkwrap.json"].contains(name) { return true }
        if name.hasPrefix("postcss") || name.hasPrefix("tsconfig") || name.hasPrefix("jsconfig") { return true }
        // next.config.js, vite.config.ts, tailwind.config.cjs, eslint.config.mjs…
        return name.split(separator: ".").dropLast().contains("config")
    }

    /// Typical credential files are never read, searched or sent to Codex.
    /// Hidden files (.env*, .npmrc) are already excluded by the workspace.
    static func isLikelySecret(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        let markers = ["credential", "secret", "service-account", "service_account", "serviceaccount",
                       "firebase-adminsdk", "private-key", "private_key", "privatekey"]
        return markers.contains { name.contains($0) }
    }
}

/// Removes credentials from URLs before they leave the Mac: userinfo and
/// query parameters that look like tokens. Mirrors `contextURL` in
/// Tools/comments-mcp.mjs.
enum URLRedaction {
    static func redact(_ string: String) -> String {
        guard var parts = URLComponents(string: string), parts.scheme != nil else {
            return string.replacingOccurrences(
                of: #"([?&](?:token|access_token|api_key)=)[^&#]*"#, with: "$1[redacted]",
                options: [.regularExpression, .caseInsensitive])
        }
        parts.user = nil
        parts.password = nil
        if let items = parts.queryItems {
            let kept = items.filter { $0.name.range(of: #"token|api.?key|authorization|secret|password"#,
                                                    options: [.regularExpression, .caseInsensitive]) == nil }
            parts.queryItems = kept.isEmpty ? nil : kept
        }
        return parts.string ?? string
    }
}
