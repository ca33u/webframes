import AppKit
import CryptoKit
import ImageIO
import os

/// Local requests are applied by the open document, never by a second file writer.
/// The opt-in covers local MCP clients running as this macOS user, not remote agents.
@MainActor final class CommentsMCPInbox {
    static let permissionKey = "webframes.allowMCPResolveComments"
    static var isAllowed: Bool { UserDefaults.standard.bool(forKey: permissionKey) }
    static let frameImagesPermissionKey = "webframes.allowMCPUpdateFrameImages"
    static var areFrameImagesAllowed: Bool { UserDefaults.standard.bool(forKey: frameImagesPermissionKey) }
    static let simulatorPermissionKey = "webframes.allowMCPSimulatorCapture"
    static var isSimulatorCaptureAllowed: Bool { UserDefaults.standard.bool(forKey: simulatorPermissionKey) }
    /// Why the request folder could not be prepared, shown in Settings.
    private(set) static var unavailableReason: String?
    private weak var document: WebFramesDocument?
    private let permission: () -> Bool
    private let frameImagesPermission: () -> Bool
    private let simulatorPermission: () -> Bool
    private let captureService: SimulatorCapture
    private var captureTask: Task<Void, Never>?
    private var busy = false
    private var started = false
    private var directory: URL?
    private var watcher: DispatchSourceFileSystemObject?
    private var defaultsObserver: NSObjectProtocol?

    struct ExpectedComment: Codable { let id: String; let comment: String; let resolved: Bool }
    struct FrameImageUpdate: Codable {
        let frameID: String
        let beforeHash: String
        let dataURL: String
    }
    struct Request: Codable {
        let id: String
        let deadline: Double
        let resolved: Bool
        let comments: [ExpectedComment]
        var frameImage: FrameImageUpdate? = nil
        var simulatorCapture: SimulatorRequest? = nil
        var simulatorCaptures: [SimulatorRequest]? = nil
    }
    struct SimulatorRequest: Codable {
        let frameID: String
        let beforeHash: String
        let recipe: SimulatorCaptureRecipe
    }
    init(document: WebFramesDocument, permission: (() -> Bool)? = nil, frameImagesPermission: (() -> Bool)? = nil,
         simulatorPermission: (() -> Bool)? = nil, captureService: SimulatorCapture? = nil) {
        self.document = document
        self.permission = permission ?? { CommentsMCPInbox.isAllowed }
        self.frameImagesPermission = frameImagesPermission ?? { CommentsMCPInbox.areFrameImagesAllowed }
        self.simulatorPermission = simulatorPermission ?? { CommentsMCPInbox.isSimulatorCaptureAllowed }
        self.captureService = captureService ?? .shared
    }
    static func directory(for project: URL) -> URL {
        let canonical = project.resolvingSymlinksInPath().standardizedFileURL.path
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Web Frames/MCP Requests")
            .appendingPathComponent(hash)
    }

    /// Follows the Settings opt-in: the request folder exists, and is watched,
    /// only while either kind of agent mutation is allowed. Without the folder the MCP
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
        captureTask?.cancel(); captureTask = nil
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        watcher?.cancel(); watcher = nil
    }

    /// Starts or stops watching to match the current permission.
    func updateActivation() {
        guard started, let directory else { return }
        if !simulatorPermission() { captureTask?.cancel() }
        if permission() || frameImagesPermission() || simulatorPermission() {
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
    static func apply(_ request: Request, to document: WebFramesDocument, allowed: Bool, imagesAllowed: Bool = false, now: Date = Date()) throws {
        guard request.simulatorCapture == nil, request.simulatorCaptures == nil else { throw SimulatorCapture.failure("Use the native capture request handler.") }
        guard request.deadline > now.timeIntervalSince1970, request.deadline <= now.timeIntervalSince1970 + 30 else {
            throw ConnectionSettingsError.message("Request expired. Read the comments again and retry.")
        }
        if let update = request.frameImage {
            guard imagesAllowed else { throw ConnectionSettingsError.message("Frame image changes are disabled. Enable Allow agents to update frame images in Web Frames Settings.") }
            guard request.comments.isEmpty, !request.resolved,
                  !update.frameID.isEmpty, update.frameID.count <= 200,
                  update.beforeHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  let frame = document.workspace.frames.first(where: { $0.id == update.frameID }), frame.isImage,
                  case .string(let previousURL)? = frame.extras["imgUrl"],
                  let previous = imageBytes(previousURL) else {
                throw ConnectionSettingsError.message("The image frame changed or was deleted. Read the latest frames and retry.")
            }
            guard update.dataURL.utf8.count <= 12_000_000,
                  update.dataURL.hasPrefix("data:image/png;base64,") || update.dataURL.hasPrefix("data:image/jpeg;base64,"),
                  let data = imageBytes(update.dataURL), !data.isEmpty, data.count <= 8 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
                  let imageType = CGImageSourceGetType(source) as String?,
                  imageType == (update.dataURL.hasPrefix("data:image/png;") ? "public.png" : "public.jpeg"),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16_384, height <= 16_384,
                  width * height <= 32_000_000,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
                throw ConnectionSettingsError.message("Provide a valid PNG or JPEG screenshot up to 8 MiB and 32 million pixels.")
            }
            let newHash = imageHash(data)
            let currentHash = imageHash(previous)
            guard currentHash == update.beforeHash || currentHash == newHash else {
                throw ConnectionSettingsError.message("The frame image changed since it was read. Read the latest frames and retry.")
            }
            // A timed-out request may already have been saved. Retrying the same bytes is a no-op.
            guard currentHash != newHash else { return }
            document.workspace.updateAgentFrameImage(id: frame.id, dataURL: update.dataURL,
                                                      pixelSize: CGSize(width: width, height: height), date: now)
            return
        }
        guard allowed else { throw ConnectionSettingsError.message("Comment changes are disabled. Enable Allow agents to resolve comments in Web Frames Settings.") }
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
    static func imageBytes(_ value: String) -> Data? {
        guard value.hasPrefix("data:image/"), let comma = value.firstIndex(of: ","),
              value[..<comma].hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(value[value.index(after: comma)...]))
    }
    static func imageHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func drain() {
        guard started, !busy, let document, let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]) else { return }
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(200) {
            guard url.lastPathComponent.hasSuffix(".request.json") else { continue }
            let id = String(url.lastPathComponent.dropLast(".request.json".count))
            guard UUID(uuidString: id) != nil else { continue }
            let reply = directory.appendingPathComponent(id + ".response.json")
            do {
                let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
                guard info.isSymbolicLink != true, (info.fileSize ?? 0) <= 12_000_000 else {
                    throw ConnectionSettingsError.message("Invalid comment request.")
                }
                let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: url))
                guard request.frameImage != nil || (info.fileSize ?? 0) <= 128_000 else {
                    throw ConnectionSettingsError.message("Invalid comment request.")
                }
                try FileManager.default.removeItem(at: url)
                guard request.id == id else { throw ConnectionSettingsError.message("Invalid request id.") }
                if request.simulatorCaptures != nil {
                    let frames = try Self.validateSimulatorBatchRequest(request, document: document, allowed: simulatorPermission())
                    busy = true
                    captureTask = Task { [weak self, weak document] in
                        guard let self, let document else { return }
                        let timeout = Task { [weak self] in
                            do {
                                try await Task.sleep(for: .seconds(max(0, request.deadline - Date().timeIntervalSince1970)))
                                self?.captureTask?.cancel()
                            } catch { }
                        }
                        defer { timeout.cancel(); self.busy = false; self.captureTask = nil; self.drain() }
                        do {
                            guard let projectURL = document.fileURL else { throw SimulatorCapture.failure("Save this project first.") }
                            let results = try await SimulatorCaptureBatch.run(document: document, frames: frames, service: self.captureService, validateCommit: {
                                guard self.started, self.simulatorPermission(), request.deadline > Date().timeIntervalSince1970 else {
                                    throw SimulatorCapture.failure("Capture cancelled, permission revoked or request expired. No screenshots were applied.")
                                }
                            })
                            if results.contains(where: \.updated) {
                                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                    document.save(to: projectURL, ofType: WebFramesDocument.fileTypeIdentifier, for: .saveOperation) {
                                        if let error = $0 { continuation.resume(throwing: error) } else { continuation.resume() }
                                    }
                                }
                            }
                            let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(results))
                            Self.reply(["ok": true, "updated": results.filter(\.updated).count, "results": values], to: reply)
                        } catch { Self.reply(["error": error.localizedDescription], to: reply) }
                    }
                    return
                }
                if request.simulatorCapture != nil {
                    let frame = try Self.validateSimulatorRequest(request, document: document, allowed: simulatorPermission())
                    busy = true
                    captureTask = Task { [weak self, weak document] in
                        guard let self, let document, let capture = request.simulatorCapture else { return }
                        defer { self.busy = false; self.captureTask = nil; self.drain() }
                        do {
                            let image = try await self.captureService.capture(capture.recipe)
                            try Task.checkCancellation()
                            _ = try Self.validateSimulatorRequest(request, document: document, allowed: self.simulatorPermission())
                            guard let projectURL = document.fileURL else { throw SimulatorCapture.failure("Save this project first.") }
                            // Put the complete image replacement into one explicit undo group: this task resumes outside a UI event.
                            document.undoManager?.beginUndoGrouping()
                            do { try document.applySimulatorCapture(image, frameID: frame.id, expected: frame) }
                            catch { document.undoManager?.endUndoGrouping(); throw error }
                            document.undoManager?.endUndoGrouping()
                            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                                document.save(to: projectURL, ofType: WebFramesDocument.fileTypeIdentifier, for: .saveOperation) {
                                    if let error = $0 { continuation.resume(throwing: error) } else { continuation.resume() }
                                }
                            }
                            Self.reply(["ok": true, "frame_id": frame.id, "imageHash": Self.imageHash(image.data)], to: reply)
                        } catch { Self.reply(["error": error.localizedDescription], to: reply) }
                    }
                    return
                }
                // Only the in-app preference grants permission. CLI arguments cannot bypass it.
                try Self.apply(request, to: document, allowed: permission(), imagesAllowed: frameImagesPermission())
                guard let projectURL = document.fileURL else { throw ConnectionSettingsError.message("Save this project first.") }
                busy = true
                document.save(to: projectURL, ofType: WebFramesDocument.fileTypeIdentifier, for: .saveOperation) { [weak self] error in
                    MainActor.assumeIsolated {
                        self?.busy = false
                        defer { self?.drain() }
                        let success: [String: Any]
                        if let update = request.frameImage, let bytes = Self.imageBytes(update.dataURL) {
                            success = ["ok": true, "frame_id": update.frameID, "imageHash": Self.imageHash(bytes)]
                        } else {
                            success = ["ok": true, "ids": request.comments.map(\.id), "resolved": request.resolved]
                        }
                        Self.reply(error.map { ["error": "Change applied in the app but could not be saved: " + $0.localizedDescription] }
                            ?? success, to: reply)
                    }
                }
                return
            } catch {
                try? FileManager.default.removeItem(at: url)
                Self.reply(["error": error.localizedDescription], to: reply)
            }
        }
    }
    static func validateSimulatorRequest(_ request: Request, document: WebFramesDocument, allowed: Bool, now: Date = Date()) throws -> FrameModel {
        guard allowed else { throw ConnectionSettingsError.message("Simulator capture is disabled. Enable Allow agents to capture simulator screens in Settings.") }
        guard request.deadline > now.timeIntervalSince1970, request.deadline <= now.timeIntervalSince1970 + 901,
              request.frameImage == nil, request.simulatorCaptures == nil, request.comments.isEmpty, !request.resolved,
              let capture = request.simulatorCapture, !capture.frameID.isEmpty, capture.frameID.count <= 200,
              let frame = document.workspace.frames.first(where: { $0.id == capture.frameID }), frame.isImage,
              frame.simulatorCapture == capture.recipe,
              case .string(let url)? = frame.extras["imgUrl"], let data = imageBytes(url), imageHash(data) == capture.beforeHash else {
            throw ConnectionSettingsError.message("The saved frame or simulator recipe changed, or the request expired. Read the frame and retry.")
        }
        try capture.recipe.validate()
        return frame
    }

    static func validateSimulatorBatchRequest(_ request: Request, document: WebFramesDocument, allowed: Bool, now: Date = Date()) throws -> [FrameModel] {
        guard request.simulatorCapture == nil, let captures = request.simulatorCaptures,
              !captures.isEmpty, captures.count <= SimulatorCaptureBatch.limit,
              Set(captures.map(\.frameID)).count == captures.count else {
            throw SimulatorCapture.failure("Provide 1–\(SimulatorCaptureBatch.limit) unique saved capture frames.")
        }
        return try captures.map { capture in
            var single = request
            single.simulatorCaptures = nil; single.simulatorCapture = capture
            return try validateSimulatorRequest(single, document: document, allowed: allowed, now: now)
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
