//
//  ProjectStorageTests.swift
//  webframesTests
//
//  Tests the app-owned library of `.webframes` files: URL generation,
//  listing semantics, the lightweight displayName peek, and delete.
//  Tests run against the real `ProjectStorage.projectsDirectory` (in
//  the test process's sandbox container), so we scope every fixture
//  under a unique UUID filename and always clean up afterwards.
//

import Foundation
import Testing
@testable import Web_Frames

@Suite("ProjectStorage")
struct ProjectStorageTests {

    // MARK: - newProjectURL

    @Test("newProjectURL has the .webframes extension")
    func newProjectURLExtension() {
        let url = ProjectStorage.newProjectURL()
        #expect(url.pathExtension == WebFramesDocument.fileExtension)
    }

    @Test("newProjectURL is under projectsDirectory")
    func newProjectURLIsScoped() {
        let url = ProjectStorage.newProjectURL()
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let expected = ProjectStorage.projectsDirectory.standardizedFileURL
        #expect(parent == expected)
    }

    @Test("newProjectURL returns unique URLs")
    func newProjectURLIsUnique() {
        // Two back-to-back calls must never collide (UUID based).
        // Cheap sanity check — not a real collision search.
        var seen = Set<String>()
        for _ in 0..<32 {
            seen.insert(ProjectStorage.newProjectURL().lastPathComponent)
        }
        #expect(seen.count == 32)
    }

    // MARK: - listProjects

    @Test("listProjects surfaces a freshly-written .webframes file")
    func listProjectsSurfacesFixture() throws {
        let fx = try Fixture.write(name: "Hello World")
        defer { fx.cleanup() }

        let entries = ProjectStorage.listProjects()
        let match = entries.first { $0.url == fx.url }
        try #require(match != nil)
        #expect(match?.displayName == "Hello World")
    }

    @Test("listProjects ignores non-.webframes files")
    func listProjectsSkipsNonMatching() throws {
        // A file with the wrong extension in the projects directory
        // must never appear in the list — regressions here show
        // random files in the Start window.
        let wrong = ProjectStorage.projectsDirectory
            .appendingPathComponent("test-\(UUID().uuidString).txt")
        try "junk".write(to: wrong, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: wrong) }

        let entries = ProjectStorage.listProjects()
        #expect(!entries.contains(where: { $0.url == wrong }))
    }

    @Test("listProjects sorts newest-modified first")
    func listProjectsSortedByModified() throws {
        let older = try Fixture.write(name: "Older")
        defer { older.cleanup() }
        // Bump the modification date on `older` into the past so we
        // don't rely on filesystem timestamp resolution being fine-
        // grained enough to distinguish two writes in the same tick.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3600)],
            ofItemAtPath: older.url.path
        )

        let newer = try Fixture.write(name: "Newer")
        defer { newer.cleanup() }

        let entries = ProjectStorage.listProjects()
        let indexNewer = entries.firstIndex(where: { $0.url == newer.url })
        let indexOlder = entries.firstIndex(where: { $0.url == older.url })

        try #require(indexNewer != nil)
        try #require(indexOlder != nil)
        #expect(indexNewer! < indexOlder!)
    }

    // MARK: - displayName fallback

    @Test("displayName falls back to Untitled when name is missing")
    func displayNameFallback() throws {
        // Write a valid JSON file without a `name` field.
        let url = ProjectStorage.projectsDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(WebFramesDocument.fileExtension)
        try Data("{}".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let entry = ProjectStorage.listProjects().first { $0.url == url }
        try #require(entry != nil)
        #expect(entry?.displayName == "Untitled")
    }

    @Test("displayName falls back to Untitled when name is empty")
    func displayNameFallbackOnEmpty() throws {
        let url = ProjectStorage.projectsDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(WebFramesDocument.fileExtension)
        try Data(#"{"name":""}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let entry = ProjectStorage.listProjects().first { $0.url == url }
        try #require(entry != nil)
        #expect(entry?.displayName == "Untitled")
    }

    @Test("displayName falls back to Untitled when JSON is malformed")
    func displayNameFallbackOnGarbage() throws {
        // A file with the right extension but garbage contents should
        // still appear in the list (so the user can delete it), just
        // with the fallback name.
        let url = ProjectStorage.projectsDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(WebFramesDocument.fileExtension)
        try Data("this is not JSON".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let entry = ProjectStorage.listProjects().first { $0.url == url }
        try #require(entry != nil)
        #expect(entry?.displayName == "Untitled")
    }

    // MARK: - delete

    @Test("delete removes the file from disk and from listProjects")
    func deleteRoundTrip() throws {
        let fx = try Fixture.write(name: "Doomed")
        // Don't use fixture.cleanup — delete is what we're testing.

        #expect(FileManager.default.fileExists(atPath: fx.url.path))
        try ProjectStorage.delete(fx.url)

        #expect(!FileManager.default.fileExists(atPath: fx.url.path))
        let entries = ProjectStorage.listProjects()
        #expect(!entries.contains(where: { $0.url == fx.url }))
    }

    @Test("delete of a missing file throws")
    func deleteMissingThrows() {
        let ghost = ProjectStorage.projectsDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
            .appendingPathExtension(WebFramesDocument.fileExtension)
        #expect(throws: (any Error).self) {
            try ProjectStorage.delete(ghost)
        }
    }

    // MARK: - Fixture

    /// RAII-ish helper: writes a minimal valid `.webframes` JSON with
    /// the given name, hands back the URL, and knows how to remove
    /// itself. Test code pairs it with `defer { fx.cleanup() }` so a
    /// failure mid-test never leaves turds in the projects directory.
    private struct Fixture {
        let url: URL

        static func write(name: String) throws -> Fixture {
            let url = ProjectStorage.projectsDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(WebFramesDocument.fileExtension)
            // Minimal payload the DocumentPayload decoder will accept.
            let json = """
            {
              "version": 1,
              "name": \(encoded(name)),
              "frames": [],
              "annotations": [],
              "links": [],
              "canvas": null,
              "nextNum": 1,
              "annNext": 1
            }
            """
            try Data(json.utf8).write(to: url)
            return Fixture(url: url)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: url)
        }

        private static func encoded(_ s: String) -> String {
            // JSONEncoder for a single String gives us proper escaping
            // (quotes, backslashes, unicode) — avoids hand-rolling it.
            let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
            return String(data: data, encoding: .utf8) ?? "\"\""
        }
    }
}

@Suite("Start window speed") struct ProjectStorageSpeedTests {
    @Test func namesComeFromThePrettyPrintedHeaderLine() throws {
        var payload = DocumentPayload.empty
        payload.name = "Café \"Quoted\" \\ Board"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        #expect(ProjectStorage.topLevelName(inPrettyJSON: data) == payload.name)
        #expect(ProjectStorage.topLevelName(inPrettyJSON: Data(#"{"name":"compact"}"#.utf8)) == nil)
    }

    @Test func listingTwentyLargeProjectsIsFast() throws {
        let fm = FileManager.default
        var written: [URL] = []
        defer { written.forEach { try? fm.removeItem(at: $0) } }
        let blob = String(repeating: "A", count: 5_000_000)
        for index in 0..<20 {
            let url = ProjectStorage.projectsDirectory.appendingPathComponent("speed-\(UUID().uuidString).webframes")
            let text = "{\n  \"annotations\" : [\n\n  ],\n  \"frames\" : [\n    {\n      \"imgUrl\" : \"data:image\\/png;base64,\(blob)\"\n    }\n  ],\n  \"name\" : \"Big \(index)\"\n}"
            try Data(text.utf8).write(to: url)
            written.append(url)
        }
        _ = ProjectStorage.listProjects()   // warm the file cache
        let start = Date()
        let entries = ProjectStorage.listProjects()
        let elapsed = Date().timeIntervalSince(start)
        #expect(Set(written.map(\.lastPathComponent)).isSubset(of: Set(entries.map(\.url.lastPathComponent))))
        #expect(entries.contains { $0.displayName == "Big 7" })
        // Reading the header line takes ~0.05 s here; parsing the 100 MB of
        // JSON took seconds. 0.25 s keeps that margin without failing on a
        // busy machine or CI runner.
        #expect(elapsed < 0.25, "listProjects took \(elapsed)s")
    }
}
