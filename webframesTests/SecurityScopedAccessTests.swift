import Foundation
import Testing
@testable import Web_Frames

@Suite("Folder bookmarks") @MainActor struct SecurityScopedAccessTests {
    @Test func renamedProjectFolderRefreshesBookmarkAndPath() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let original = parent.appendingPathComponent("Palo", isDirectory: true)
        try fm.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        let document = makeTestDocument()
        #expect(document.setFixSource(original))
        let renamed = parent.appendingPathComponent("Palo-renamed", isDirectory: true)
        try fm.moveItem(at: original, to: renamed)

        let resolved = try #require(document.resolvedFixSource())
        #expect(resolved.lastPathComponent == "Palo-renamed")
        #expect(document.payload.fixSource?.path.hasSuffix("/Palo-renamed") == true)
        // The rewritten bookmark resolves without being stale.
        var stale = true
        let again = try URL(resolvingBookmarkData: try #require(document.payload.fixSource?.bookmark),
                            options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        #expect(!stale && again.lastPathComponent == "Palo-renamed")
    }

    @Test func missingBookmarkFallsBackToSavedPath() {
        let resolution = SecurityScopedAccess.resolve(bookmark: nil, fallbackPath: "/tmp/project")
        #expect(resolution.url.path == "/tmp/project" && resolution.refreshedBookmark == nil)
        let garbage = SecurityScopedAccess.resolve(bookmark: Data([1, 2, 3]), fallbackPath: "/tmp/project")
        #expect(garbage.url.path == "/tmp/project")
    }
}
