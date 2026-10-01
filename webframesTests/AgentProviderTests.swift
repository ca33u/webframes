import Foundation
import Testing
@testable import Web_Frames

@Suite("Agent provider", .serialized) final class AgentProviderTests {
    // The test host shares the app's defaults; keep the developer's choice.
    private let keys = [AgentProvider.defaultsKey, "webframes.agentModel.codex", "webframes.agentModel.claude"]
    private let saved: [String: Any?]
    init() { saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }) }
    deinit {
        for (key, value) in saved {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    @Test func namesAndModelsFollowTheChosenProvider() {
        UserDefaults.standard.removeObject(forKey: AgentProvider.defaultsKey)
        #expect(AgentProvider.current == .codex)
        AgentProvider.current = .claude
        #expect(AgentProvider.current.name == "Claude" && AgentProvider.current.productName == "Claude Code")
        AgentProvider.claude.setModel("  ")
        #expect(AgentProvider.claude.model == nil)          // Claude Code picks its default
        AgentProvider.claude.setModel("claude-sonnet-5")
        #expect(AgentProvider.claude.model == "claude-sonnet-5")
        AgentProvider.codex.setModel("")
        #expect(AgentProvider.codex.model == "gpt-6-astra")
    }
}
