import Foundation
import Testing
@testable import Web_Frames

@Suite("Evidence rotation") struct EvidenceStoreTests {
    @Test func keepsNewestRunsAndDropsOldOnes() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let now = Date()
        for i in 0..<25 {
            let run = dir.appendingPathComponent("run-\(i)", isDirectory: true)
            try fm.createDirectory(at: run, withIntermediateDirectories: true)
            // run-0 is the newest; run-3 is older than the age limit.
            let age: TimeInterval = i == 3 ? 40 * 86_400 : TimeInterval(i * 60)
            try fm.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: run.path)
        }
        EvidenceStore.prune(dir, keep: 20, maxAge: 30 * 86_400, now: now)
        let left = Set(try fm.contentsOfDirectory(atPath: dir.path))
        // 20 newest by date; run-3 is the oldest of all, so run-20 stays.
        #expect(left.count == 20)
        #expect(!left.contains("run-3") && left.contains("run-20") && !left.contains("run-21"))
        // Age alone removes a run even when under the count limit.
        EvidenceStore.prune(dir, keep: 100, maxAge: 10 * 60, now: now)
        #expect(Set(try fm.contentsOfDirectory(atPath: dir.path)) == Set((0...10).filter { $0 != 3 }.map { "run-\($0)" }))
    }

    @Test func runDirectoriesArePrivate() throws {
        let run = try EvidenceStore.newRunDirectory()
        defer { try? FileManager.default.removeItem(at: run) }
        let mode = try FileManager.default.attributesOfItem(atPath: run.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(!run.path.contains("/Library/Application Support/"))
    }
}
