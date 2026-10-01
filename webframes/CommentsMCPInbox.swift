import AppKit
import CryptoKit
import os

/// Local requests are applied by the open document, never by a second file writer.
/// The opt-in covers local MCP clients running as this macOS user, not remote agents.
@MainActor final class CommentsMCPInbox {
    static let permissionKey = "webframes.allowMCPResolveComments"
    static var isAllowed: Bool { UserDefaults.standard.bool(forKey: permissionKey) }
    /// Why the request folder could not be prepared, shown in Settings.
    private(set) static var unavailableReason: String?
    private weak var document: WebFramesDocument?
    private let permission: () -> Bool
    private var busy = false
    private var started = false
    private var directory: URL?
    private var watcher: DispatchSourceFileSystemObject?
    private var defaultsObserver: NSObjectProtocol?

    struct ExpectedComment: Codable { let id: String; let comment: String; let resolved: Bool }
    struct Request: Codable {
        let id: String
        let deadline: Double
        let resolved: Bool
        let comments: [ExpectedComment]
    }
    init(document: WebFramesDocument, permission: (() -> Bool)? = nil) {
        self.document = document
        self.permission = permission ?? { CommentsMCPInbox.isAllowed }
    }
    static func directory(for project: URL) -> URL {
        let canonical = project.resolvingSymlinksInPath().standardizedFileURL.path
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Web Frames/MCP Requests")
            .appendingPathComponent(hash)
    }

    /// Follows the Settings opt-in: the request folder exists, and is watched,
    /// only while agents may resolve comments. Without the folder the MCP
    /// server answers immediately that the setting is off.
    func start() {
        guard !started, let url = document?.fileURL else { return }
        started = true
        directory = Self.directory(for: url)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateActivation() }
        }
        updateActivation()
    }
    func stop() {
        started = false
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        watcher?.cancel(); watcher = nil
    }

    /// Starts or stops watching to match the current permission.
    func updateActivation() {
        guard started, let directory else { return }
        if permission() {
            guard watcher == nil else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            } catch {
                Log.doc.error("MCP inbox unavailable: \(error.localizedDescription, privacy: .private)")
                Self.unavailableReason = error.localizedDescription
                return
            }
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else {
                Self.unavailableReason = "The request folder could not be watched."
                return
            }
            Self.unavailableReason = nil
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.drain() } }
            source.setCancelHandler { close(descriptor) }
            watcher = source
            source.resume()
            drain()
        } else {
            watcher?.cancel(); watcher = nil
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Validate the entire batch against current memory before changing any item.
    static func apply(_ request: Request, to document: WebFramesDocument, allowed: Bool, now: Date = Date()) throws {
        guard allowed else { throw ConnectionSettingsError.message("Comment changes are disabled. Enable Allow agents to resolve comments in Web Frames Settings.") }
        guard request.deadline > now.timeIntervalSince1970, request.deadline <= now.timeIntervalSince1970 + 30 else {
            throw ConnectionSettingsError.message("Request expired. Read the comments again and retry.")
        }
        let ids = request.comments.map(\.id)
        guard !ids.isEmpty, ids.count <= 100, Set(ids).count == ids.count else {
            throw ConnectionSettingsError.message("Provide 1–100 unique comment ids.")
        }
        for expected in request.comments {
            guard let current = document.workspace.annotations.first(where: { $0.id == expected.id }),
                  current.comment == expected.comment,
                  current.resolved == expected.resolved || current.resolved == request.resolved else {
                throw ConnectionSettingsError.message("A comment changed or was deleted. Read the latest saved comments and retry.")
            }
        }
        document.workspace.setAgentCommentStatuses(ids: ids, resolved: request.resolved, date: now)
    }
    private func drain() {
        guard !busy, let document, let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]) else { return }
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(200) {
            guard url.lastPathComponent.hasSuffix(".request.json") else { continue }
            let id = String(url.lastPathComponent.dropLast(".request.json".count))
            guard UUID(uuidString: id) != nil else { continue }
            let reply = directory.appendingPathComponent(id + ".response.json")
            do {
                let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                guard info.isSymbolicLink != true, (info.fileSize ?? 0) <= 128_000 else {
                    throw ConnectionSettingsError.message("Invalid comment request.")
                }
                let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: url))
                try FileManager.default.removeItem(at: url)
                guard request.id == id else { throw ConnectionSettingsError.message("Invalid request id.") }
                // Only the in-app preference grants permission. CLI arguments cannot bypass it.
                try Self.apply(request, to: document, allowed: permission())
                guard let projectURL = document.fileURL else { throw ConnectionSettingsError.message("Save this project first.") }
                busy = true
                document.save(to: projectURL, ofType: WebFramesDocument.fileTypeIdentifier, for: .saveOperation) { [weak self] error in
                    MainActor.assumeIsolated {
                        self?.busy = false
                        defer { self?.drain() }
                        Self.reply(error.map { ["error": "Status changed in the app but could not be saved: " + $0.localizedDescription] }
                            ?? ["ok": true, "ids": request.comments.map(\.id), "resolved": request.resolved], to: reply)
                    }
                }
                return
            } catch {
                try? FileManager.default.removeItem(at: url)
                Self.reply(["error": error.localizedDescription], to: reply)
            }
        }
    }
    /// The status change is already saved when this runs; a lost reply would
    /// make the agent time out and retry blind, so retry the write and log.
    private static func reply(_ result: [String: Any], to url: URL, attempt: Int = 0) {
        guard let data = try? JSONSerialization.data(withJSONObject: result) else { return }
        do { try data.write(to: url, options: .atomic) }
        catch {
            Log.doc.error("MCP reply write failed (attempt \(attempt + 1)): \(error.localizedDescription, privacy: .private)")
            guard attempt < 3 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                MainActor.assumeIsolated { reply(result, to: url, attempt: attempt + 1) }
            }
        }
    }
}
