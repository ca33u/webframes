import Foundation
import Testing
@testable import Web_Frames

@Suite("Bundled agent discovery") struct BundledToolsTests {
    @Test(arguments: ["Contents/Resources/codex",
                      "Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"])
    func discoversCodexInDesktopAppLayouts(_ relativePath: String) throws {
        let fm = FileManager.default
        let app = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        defer { try? fm.removeItem(at: app) }
        let binary = app.appendingPathComponent(relativePath)
        try fm.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binary.path)
        #expect(BundledTools.codexAppExecutable(in: app) == nil)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        #expect(BundledTools.codexAppExecutable(in: app) == binary.path)
    }
}
