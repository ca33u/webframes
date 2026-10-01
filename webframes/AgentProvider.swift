import Foundation

/// The coding agent behind Compare and Fix comments. Web Frames never holds
/// an API key for it: each provider runs its own CLI with the user's saved
/// sign-in, through the same local connector and guard rails.
enum AgentProvider: String, CaseIterable {
    case codex
    case claude

    nonisolated static let defaultsKey = "webframes.agentProvider"
    nonisolated static let changed = Notification.Name("WebFramesAgentProviderChanged")

    nonisolated static var current: AgentProvider {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(AgentProvider.init(rawValue:)) ?? .codex }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Short name used in buttons and messages: "Fix with Claude".
    nonisolated var name: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    /// Product name for Settings: which app the user installs and signs in to.
    nonisolated var productName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        }
    }

    /// The model used when the user has not chosen one; nil means the CLI's default.
    nonisolated var defaultModel: String? {
        switch self {
        case .codex: return "gpt-6-astra"
        case .claude: return nil
        }
    }

    nonisolated private var modelKey: String { "webframes.agentModel." + rawValue }

    /// The model passed to the CLI: the user's choice, else the default.
    nonisolated var model: String? {
        let chosen = UserDefaults.standard.string(forKey: modelKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (chosen?.isEmpty == false) ? chosen : defaultModel
    }

    nonisolated var customModel: String { UserDefaults.standard.string(forKey: modelKey) ?? "" }

    nonisolated func setModel(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { UserDefaults.standard.removeObject(forKey: modelKey) }
        else { UserDefaults.standard.set(trimmed, forKey: modelKey) }
    }

    nonisolated var signInHint: String {
        switch self {
        case .codex:
            return "Install Codex and sign in, then connect here. No API key needed."
        case .claude:
            return "Install Claude Code and run `claude` once in Terminal to sign in, then connect here. No API key needed."
        }
    }

    /// Environment variable that overrides where the CLI is looked up.
    nonisolated var binaryOverrideKey: String {
        switch self {
        case .codex: return "WEBFRAMES_CODEX_BINARY"
        case .claude: return "WEBFRAMES_CLAUDE_BINARY"
        }
    }
}
