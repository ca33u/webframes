import Foundation
import Testing
@testable import Web_Frames

@Suite("Project trust", .serialized) @MainActor final class ProjectTrustTests {
    // The test host shares the app's UserDefaults domain: keep the
    // developer's real approvals intact around every test.
    private let approvalsKey = ProjectTrust.defaultsKey
    private let savedApprovals = UserDefaults.standard.stringArray(forKey: ProjectTrust.defaultsKey)
    deinit {
        if let savedApprovals { UserDefaults.standard.set(savedApprovals, forKey: approvalsKey) }
        else { UserDefaults.standard.removeObject(forKey: approvalsKey) }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wf-trust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func untrustedByDefaultAndTrustPersistsAcrossReads() throws {
        ProjectTrust.revokeAll()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!ProjectTrust.isTrusted(root))
        ProjectTrust.trust(root)
        #expect(ProjectTrust.isTrusted(root))
        #expect(UserDefaults.standard.stringArray(forKey: ProjectTrust.defaultsKey)?.contains(ProjectTrust.canonicalPath(root)) == true)
        ProjectTrust.revoke(root)
        #expect(!ProjectTrust.isTrusted(root))
    }

    @Test func symlinkAndTrailingSlashResolveToTheSameDecision() throws {
        ProjectTrust.revokeAll()
        let root = try temporaryRoot()
        let link = root.deletingLastPathComponent().appendingPathComponent("wf-trust-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: root) }
        ProjectTrust.trust(link)
        #expect(ProjectTrust.isTrusted(root))
        #expect(ProjectTrust.isTrusted(URL(fileURLWithPath: root.path + "/", isDirectory: true)))
        ProjectTrust.revokeAll()
        #expect(!ProjectTrust.isTrusted(link))
    }

    @Test func trustIsNotCarriedByTheDocument() throws {
        // The decision lives in UserDefaults only: nothing in a payload can grant it.
        ProjectTrust.revokeAll()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var payload = DocumentPayload()
        payload.fixSource = FixSourceReference(path: root.path, bookmark: nil)
        #expect(!ProjectTrust.isTrusted(URL(fileURLWithPath: payload.fixSource!.path, isDirectory: true)))
    }

    @Test func settingsListShowsApprovedFoldersUntilRevoked() throws {
        ProjectTrust.revokeAll()
        let first = try temporaryRoot(), second = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        #expect(ProjectTrust.trustedFolders.isEmpty)
        ProjectTrust.trust(second); ProjectTrust.trust(first)
        #expect(ProjectTrust.trustedFolders == [ProjectTrust.canonicalPath(first), ProjectTrust.canonicalPath(second)].sorted())
        ProjectTrust.revoke(URL(fileURLWithPath: ProjectTrust.trustedFolders[0], isDirectory: true))
        #expect(ProjectTrust.trustedFolders.count == 1)
        ProjectTrust.revokeAll()
        #expect(ProjectTrust.trustedFolders.isEmpty)
    }
}
