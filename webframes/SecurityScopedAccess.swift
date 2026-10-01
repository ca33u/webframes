import Foundation
import os

/// Resolves saved folder bookmarks and keeps them fresh. A moved or renamed
/// project folder resolves through its bookmark but reports it as stale; the
/// bookmark and saved path must then be rewritten or the next launch loses
/// the folder.
enum SecurityScopedAccess {
    struct Resolution {
        let url: URL
        /// A new bookmark to persist when the saved one was stale.
        let refreshedBookmark: Data?
    }

    static func resolve(bookmark: Data?, fallbackPath: String) -> Resolution {
        let fallback = URL(fileURLWithPath: fallbackPath, isDirectory: true)
        guard let bookmark else { return Resolution(url: fallback, refreshedBookmark: nil) }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            Log.doc.error("folder bookmark could not be resolved; using saved path")
            return Resolution(url: fallback, refreshedBookmark: nil)
        }
        guard stale else { return Resolution(url: url, refreshedBookmark: nil) }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let refreshed = try? makeBookmark(for: url)
        if refreshed == nil { Log.doc.error("stale folder bookmark could not be refreshed") }
        return Resolution(url: url, refreshedBookmark: refreshed)
    }

    static func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            Log.doc.error("folder bookmark creation failed: \(error.localizedDescription, privacy: .private)")
            throw error
        }
    }
}
