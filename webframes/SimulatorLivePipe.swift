import Foundation

/// A length-prefixed PNG pipe retains only the newest complete frame, never a video recording.
nonisolated final class SimulatorLiveFrameBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var latest: Data?
    private var length: Int?
    private var ended = false
    private var invalid = false
    func feed(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !invalid, !ended else { return }
        pending.append(bytes)
        while true {
            if length == nil {
                guard pending.count >= 4 else { return }
                let value = pending.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                pending.removeFirst(4)
                guard value > 0, value <= 8 * 1024 * 1024 else {
                    invalid = true
                    pending.removeAll()
                    return
                }
                length = value
            }
            guard let size = length, pending.count >= size else { return }
            latest = Data(pending.prefix(size))
            pending.removeFirst(size)
            length = nil
        }
    }
    func finish() {
        lock.lock()
        ended = true
        lock.unlock()
    }
    func take() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if invalid { throw SimulatorCapture.failure("Invalid live frame header.") }
        if let latest {
            self.latest = nil
            return latest
        }
        if ended { throw SimulatorCapture.failure("Live preview disconnected.") }
        return nil
    }
}

extension SimulatorCapture {
    /// Streaming stdout is consumed directly; it is never redirected to an accumulating file.
    func runLivePipe(executable: URL, arguments: [String], frames: SimulatorLiveFrameBuffer) async throws {
        let pipe = Pipe()
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("WF-Live-" + UUID().uuidString)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            try? errors.close()
            try? FileManager.default.removeItem(at: errorURL)
            frames.finish()
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let bytes = (try? handle.read(upToCount: 65_536)) ?? Data()
            if bytes.isEmpty {
                handle.readabilityHandler = nil
                frames.finish()
            } else {
                frames.feed(bytes)
            }
        }
        let process = Process()
        let command = ChildProcessWatchdog.wrap(executable: executable, arguments: arguments)
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.standardOutput = pipe
        process.standardError = errors
        try Task.checkCancellation()
        try process.run()
        let end = Date().addingTimeInterval(1_020)
        while process.isRunning {
            if Task.isCancelled || Date() > end {
                process.terminate()
                await Task.detached { try? await Task.sleep(for: .seconds(3)) }.value
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                if Task.isCancelled { throw CancellationError() }
                throw Self.failure("Live preview ended after 15 minutes.")
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw Self.failure("The live device connection ended.") }
    }
}
