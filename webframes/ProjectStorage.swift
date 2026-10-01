import AppKit
import Foundation
import os

/// App-managed library of projects. Replaces the user-chosen-file model
/// (NSSavePanel / NSOpenPanel) with a single directory the app owns:
///
///     ~/Library/Application Support/Web Frames/Projects/<uuid>.webframes
///
/// Each file is the same JSON blob a `.webframes` document used to be; we
/// just pick the URL for the user. The Start window reads this directory to
/// build its project list, and deletes do `FileManager.removeItem(at:)`.
enum ProjectStorage {

    /// Where projects live. Created lazily on first access.
    /// `WEBFRAMES_PROJECTS_DIR` overrides it (the comments MCP honours the
    /// same variable); unit tests get a throwaway folder so they never add
    /// projects to the user's library.
    static let projectsDirectory: URL = {
        let fm = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        if let custom = environment["WEBFRAMES_PROJECTS_DIR"], !custom.isEmpty {
            let dir = URL(fileURLWithPath: custom, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        if environment["XCTestConfigurationFilePath"] != nil {
            let dir = fm.temporaryDirectory.appendingPathComponent("WebFramesTests-Projects", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            // /var/folders is a symlink to /private/var/folders; directory
            // listings return the real path, so use it here too.
            return URL(fileURLWithPath: realPath(of: dir), isDirectory: true)
        }
        let base = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base
            .appendingPathComponent("Web Frames", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Log.doc.error("failed to create projects dir: \(error.localizedDescription, privacy: .private)")
        }
        return dir
    }()

    /// Generate a fresh URL for a new project. The file need not exist yet —
    /// the caller (NSDocument auto-save) will create it.
    static func newProjectURL() -> URL {
        projectsDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(WebFramesDocument.fileExtension)
    }

    /// One row on the Start window — enough to render the list without
    /// decoding the whole payload. `displayName` is read from the JSON
    /// `name` field when present, otherwise falls back to "Untitled".
    struct Entry {
        let url: URL
        let displayName: String
        let modifiedAt: Date
    }

    /// Snapshot of all projects on disk, newest-modified first.
    static func listProjects() -> [Entry] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let entries: [Entry] = urls.compactMap { url in
            guard url.pathExtension == WebFramesDocument.fileExtension else { return nil }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modified = values?.contentModificationDate ?? .distantPast
            return Entry(url: url, displayName: readDisplayName(at: url), modifiedAt: modified)
        }
        return entries.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Permanently remove a project file. Best-effort — any error is logged
    /// and surfaced to the caller so the Start window can show it.
    static func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Private

    /// Peek at the JSON on disk to read just the `name` field. We avoid
    /// decoding the whole `DocumentPayload` here — the Start window renders
    /// potentially many of these in a loop, and most fields are heavy
    /// (frames / annotations / canvas) and irrelevant to the list row.
    ///
    /// Projects embed base64 screenshots and reach tens of MB, and sorted keys
    /// put `name` after `frames`, so parsing every file froze the Start
    /// window. Documents are written pretty-printed, where the top-level name
    /// is the one line indented by exactly two spaces; find it in the mapped
    /// file and decode only that string. Anything else (compact JSON from
    /// another writer) falls back to a full parse.
    static func readDisplayName(at url: URL) -> String {
        // Packages keep a small document.json; version-1 projects are one file.
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let file = isDirectory.boolValue ? url.appendingPathComponent(DocumentPackage.documentName) : url
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return "Untitled" }
        if let name = topLevelName(inPrettyJSON: data) { return name.isEmpty ? "Untitled" : name }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = json["name"] as? String, !name.isEmpty else { return "Untitled" }
        return name
    }

    static func topLevelName(inPrettyJSON data: Data) -> String? {
        let marker = Array("\n  \"name\" : \"".utf8)
        return data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> String? in
            guard let base = buffer.baseAddress, buffer.count >= marker.count else { return nil }
            // Sorted keys put `name` after the large `frames` array, so search
            // backwards in windows; only the file's tail pages get read. Only
            // one line can match: nested keys are indented deeper.
            let window = 256 * 1024
            var hitOffset: Int?
            var end = buffer.count
            while end > 0, hitOffset == nil {
                let begin = max(0, end - window)
                let length = min(buffer.count, end + marker.count - 1) - begin
                if let hit = memmem(base + begin, length, marker, marker.count) {
                    hitOffset = UnsafeRawPointer(hit) - base
                }
                end = begin
            }
            guard let hitOffset else { return nil }
            let start = hitOffset + marker.count - 1   // keep the opening quote
            var index = start + 1
            var escaped = false
            while index < buffer.count, index - start < 4_096 {
                let byte = buffer[index]
                if escaped { escaped = false }
                else if byte == UInt8(ascii: "\\") { escaped = true }
                else if byte == UInt8(ascii: "\"") {
                    let literal = Data(buffer[start...index])
                    return try? JSONDecoder().decode(String.self, from: literal)
                }
                index += 1
            }
            return nil
        }
    }
}

/// The fully resolved path (`realpath(3)`). Unlike
/// `URL.resolvingSymlinksInPath()`, it keeps the `/private` prefix, which is
/// what FileManager listings and enumerators return.
nonisolated func realPath(of url: URL) -> String {
    url.withUnsafeFileSystemRepresentation { pointer -> String in
        guard let pointer, let resolved = realpath(pointer, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
