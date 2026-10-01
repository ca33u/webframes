import Foundation
import Testing
@testable import Web_Frames

@Suite("Codex source policy") @MainActor struct SourcePolicyTests {
    @Test func buildAndDependencyFilesAreFlagged() {
        for path in ["package.json", "web/package-lock.json", "next.config.js", "vite.config.ts",
                     "tailwind.config.cjs", "postcss.config.mjs", "tsconfig.json", "tsconfig.app.json"] {
            #expect(SourcePolicy.isBuildOrConfigFile(path), "\(path)")
        }
        for path in ["styles.css", "src/app/page.tsx", "config/routes.ts", "data/settings.json"] {
            #expect(!SourcePolicy.isBuildOrConfigFile(path), "\(path)")
        }
    }

    @Test func credentialFilesAreNeverReadOrListed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("google-credentials.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("my-service-account.json"))
        try Data("a{}".utf8).write(to: root.appendingPathComponent("styles.css"))
        let workspace = try AstraWorkspace(root: root)
        #expect(workspace.files() == ["styles.css"])
        #expect(throws: (any Error).self) { _ = try workspace.read("google-credentials.json") }
    }

    @Test func configEditsNeedASeparateConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("package.json")
        try Data(#"{"scripts":{"dev":"next dev"}}"#.utf8).write(to: package)
        let workspace = try AstraWorkspace(root: root)
        let proposal = CodexCommentFixProposal(summary: "Change dev script", addressedCommentIDs: ["c"], files: [
            CodexFixFileProposal(path: "package.json", beforeHash: try workspace.read("package.json").hash,
                                 edits: [AstraEdit(oldText: "next dev", newText: "next dev --turbo")])])
        let service = CodexCommentFixService()
        let patch = try service.prepare(proposal, allowedCommentIDs: ["c"], workspace: workspace)
        #expect(patch.configEntries.map(\.path) == ["package.json"])
        #expect(patch.reviewText.contains("Build or dependency configuration"))
        #expect(throws: (any Error).self) { try service.apply(patch, approvedID: patch.id, workspace: workspace, artifacts: root) }
        #expect(try String(contentsOf: package, encoding: .utf8).contains("\"next dev\""))
        try service.apply(patch, approvedID: patch.id, configFilesConfirmed: true, workspace: workspace, artifacts: root)
        #expect(try String(contentsOf: package, encoding: .utf8).contains("--turbo"))
    }

    @Test func urlsLoseCredentialsBeforeLeavingTheMac() {
        #expect(URLRedaction.redact("https://user:pass@app.example/dash?token=abc&tab=2") == "https://app.example/dash?tab=2")
        #expect(URLRedaction.redact("http://localhost:3000/?api_key=1&access_token=2") == "http://localhost:3000/")
        #expect(URLRedaction.redact("http://localhost:3000/settings") == "http://localhost:3000/settings")
    }
}
