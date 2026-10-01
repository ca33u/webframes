import Foundation
import os

/// Local evidence of Compare / Fix runs (screenshots, DOM, source before and
/// after, comment text) and the disposable sample project. Everything lives
/// under ~/Library/Application Support/Web Frames with owner-only access and
/// is rotated, because it contains the user's source code.
enum EvidenceStore {
    static let keepRuns = 20
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    static var baseDirectory: URL {
        if let custom = ProcessInfo.processInfo.environment["WEBFRAMES_SUPPORT_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("WebFramesTests-Support", isDirectory: true)
        }
        return support.appendingPathComponent("Web Frames", isDirectory: true)
    }
    static var runsDirectory: URL { baseDirectory.appendingPathComponent("AstraRuns", isDirectory: true) }
    static var sampleDirectory: URL { baseDirectory.appendingPathComponent("AstraDemo", isDirectory: true) }
    static var connectorDirectory: URL { baseDirectory.appendingPathComponent("Connector", isDirectory: true) }

    /// Creates `url` (and parents) with 0700 permissions.
    @discardableResult
    static func privateDirectory(_ url: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    static func newRunDirectory() throws -> URL {
        try privateDirectory(runsDirectory)
        prune(runsDirectory, keep: keepRuns, maxAge: maxAge)
        return try privateDirectory(runsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    /// Keeps the `keep` newest entries and drops anything older than `maxAge`.
    static func prune(_ directory: URL, keep: Int, maxAge: TimeInterval, now: Date = Date()) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles]) else { return }
        let dated = entries.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (index, entry) in dated.enumerated() where index >= keep || now.timeIntervalSince(entry.1) > maxAge {
            try? fm.removeItem(at: entry.0)
        }
    }

    /// 1.0.x wrote runs and the sample to "WebFrames" (no space). Move runs
    /// into the one support folder, drop the disposable sample copies, and
    /// clean connector folders left by earlier sessions.
    static func migrateAndClean(excludingConnector current: URL? = nil) {
        // The test host is the app: never touch the user's real folders there.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = support.appendingPathComponent("WebFrames", isDirectory: true)
        if fm.fileExists(atPath: legacy.path) {
            let legacyRuns = legacy.appendingPathComponent("AstraRuns", isDirectory: true)
            if let runs = try? fm.contentsOfDirectory(at: legacyRuns, includingPropertiesForKeys: nil), !runs.isEmpty,
               (try? privateDirectory(runsDirectory)) != nil {
                for run in runs {
                    let target = runsDirectory.appendingPathComponent(run.lastPathComponent)
                    if (try? fm.moveItem(at: run, to: target)) == nil { try? fm.removeItem(at: run) }
                }
            }
            try? fm.removeItem(at: legacy)
            Log.doc.info("migrated legacy WebFrames support folder")
        }
        _ = try? privateDirectory(baseDirectory)
        for directory in [runsDirectory, sampleDirectory] where fm.fileExists(atPath: directory.path) {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        prune(runsDirectory, keep: keepRuns, maxAge: maxAge)
        if let connectors = try? fm.contentsOfDirectory(at: connectorDirectory, includingPropertiesForKeys: nil) {
            for folder in connectors where folder.standardizedFileURL != current?.standardizedFileURL {
                try? fm.removeItem(at: folder)
            }
        }
    }

    /// Bytes used by run evidence, the sample and old connector runs.
    static func diskUsage() -> Int64 {
        [runsDirectory, sampleDirectory, connectorDirectory].reduce(0) { $0 + size(of: $1) }
    }

    /// Removes all run evidence and the sample project. Undo of an applied fix
    /// keeps working: it reads the originals from memory, not from disk.
    static func clearAll(excludingConnector current: URL? = nil) {
        let fm = FileManager.default
        try? fm.removeItem(at: runsDirectory)
        try? fm.removeItem(at: sampleDirectory)
        if let connectors = try? fm.contentsOfDirectory(at: connectorDirectory, includingPropertiesForKeys: nil) {
            for folder in connectors where folder.standardizedFileURL != current?.standardizedFileURL {
                try? fm.removeItem(at: folder)
            }
        }
    }

    private static func size(of directory: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}
