import Foundation
import Testing
@testable import Web_Frames

@Suite("Child process watchdog") struct ChildProcessWatchdogTests {
    private func pids(matching marker: String) throws -> [Int32] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", marker]
        let out = Pipe(); pgrep.standardOutput = out; pgrep.standardError = FileHandle.nullDevice
        try pgrep.run(); pgrep.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    private func waitUntil(_ condition: () throws -> Bool, timeout: Duration = .seconds(6)) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try condition()
    }

    @Test func terminatingTheSupervisorStopsTheWholeTree() async throws {
        // A shell that spawns a grandchild — the shape of `npm run dev` → `next dev`.
        let marker = "wf-watchdog-\(UUID().uuidString)"
        let wrapped = ChildProcessWatchdog.wrap(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sh -c 'sleep 300 # \(marker)' & wait"])
        let process = Process()
        process.executableURL = wrapped.executable
        process.arguments = wrapped.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let started = try await waitUntil { try !pids(matching: marker).isEmpty }
        #expect(started)

        process.terminate()
        let supervisorExited = try await waitUntil { !process.isRunning }
        #expect(supervisorExited)
        let treeGone = try await waitUntil { try pids(matching: marker).isEmpty }
        #expect(treeGone)
    }

    @Test func wrapKeepsTheOriginalCommandLine() {
        let wrapped = ChildProcessWatchdog.wrap(executable: URL(fileURLWithPath: "/usr/local/bin/npm"),
                                                arguments: ["run", "dev", "--", "--port", "3000"])
        #expect(wrapped.executable.path == "/bin/sh")
        #expect(Array(wrapped.arguments.suffix(6)) == ["/usr/local/bin/npm", "run", "dev", "--", "--port", "3000"])
        #expect(wrapped.arguments.first == "-c")
    }
}
