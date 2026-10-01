import AppKit
import CryptoKit

enum AstraError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct AstraEdit: Codable, Equatable { let oldText: String; let newText: String }
struct AstraFinding: Codable {
    let id: String
    let selector: String
    let mismatch: String
    let expected: String
}
struct AstraProposal: Codable {
    let summary: String
    let findings: [AstraFinding]
    let path: String
    let beforeHash: String
    let edits: [AstraEdit]
}
struct AstraCheck: Codable {
    let id: String
    let status: String
    let evidence: String
}
struct AstraVerification: Codable {
    let summary: String
    let checks: [AstraCheck]
}

@MainActor
final class AstraWorkspace {
    let root: URL
    private let selectedURL: URL
    private let scoped: Bool
    private let readable: Set<String> = ["html", "css", "js", "jsx", "ts", "tsx", "json"]
    private let excluded: Set<String> = ["node_modules", "dist", "build", "out", "vendor", "coverage"]
    init(root: URL) throws {
        selectedURL = root
        scoped = root.startAccessingSecurityScopedResource()
        // realpath keeps /private, like FileManager enumerators do, so
        // listed paths and the root share one prefix.
        self.root = URL(fileURLWithPath: realPath(of: root), isDirectory: true)
        guard (try? self.root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            if scoped { root.stopAccessingSecurityScopedResource() }
            throw AstraError.message("Choose a source folder.")
        }
    }
    deinit { if scoped { selectedURL.stopAccessingSecurityScopedResource() } }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func resolve(_ path: String, writing: Bool = false) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.contains("\\"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && !excluded.contains(String($0)) }),
              readable.contains((path as NSString).pathExtension.lowercased()) else {
            throw AstraError.message("Path is outside the allowed source scope.")
        }
        guard !SourcePolicy.isLikelySecret(path) else {
            throw AstraError.message("Credential files are never read or sent to \(AgentProvider.current.name).")
        }
        let lexical = root.appendingPathComponent(path).standardized
        let canonical = URL(fileURLWithPath: realPath(of: lexical))
        guard canonical.path.hasPrefix(root.path + "/"), canonical.path == lexical.path else {
            throw AstraError.message("Symlinks and paths outside the source folder are not allowed.")
        }
        if writing && canonical.pathExtension.lowercased() != "css" {
            throw AstraError.message("This preview only applies changes to one CSS file.")
        }
        let values = try canonical.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 131_072 else {
            throw AstraError.message("Source must be a regular text file smaller than 128 KB.")
        }
        return canonical
    }

    func read(_ path: String) throws -> (text: String, hash: String) {
        let data = try Data(contentsOf: resolve(path))
        guard data.count <= 131_072, let text = String(data: data, encoding: .utf8) else {
            throw AstraError.message("Cannot read this source as UTF-8 text.")
        }
        return (text, Self.hash(data))
    }

    func files() -> [String] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [String] = []
        var visited = 0
        for case let url as URL in e {
            visited += 1
            if visited > 2000 || result.count >= 200 { break }
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true || excluded.contains(url.lastPathComponent) { e.skipDescendants(); continue }
            if v?.isDirectory == true { continue }
            let path = String(url.path.dropFirst(root.path.count + 1))
            if (try? resolve(path)) != nil { result.append(path) }
        }
        return result.sorted()
    }

    func search(_ query: String) throws -> [[String: Any]] {
        guard !query.isEmpty, query.count <= 120 else { throw AstraError.message("Use a search query of 1–120 characters.") }
        var matches: [[String: Any]] = []
        for path in files() {
            guard let source = try? read(path) else { continue }
            for (i, line) in source.text.components(separatedBy: "\n").enumerated() where line.localizedCaseInsensitiveContains(query) {
                matches.append(["path": path, "line": i + 1, "text": String(line.prefix(350))])
                if matches.count == 20 { return matches }
            }
        }
        return matches
    }
}

struct AstraPatch {
    let id: UUID
    let path: String
    let before: Data
    let after: Data
    let beforeHash: String
    let afterHash: String
    let reviewText: String
}

@MainActor
final class AstraPatchService {
    private(set) var applied: AstraPatch?
    private var used = Set<UUID>()

    func prepare(_ proposal: AstraProposal, workspace: AstraWorkspace) throws -> AstraPatch {
        _ = try workspace.resolve(proposal.path, writing: true)
        let source = try workspace.read(proposal.path)
        guard source.hash == proposal.beforeHash else { throw AstraError.message("Source changed. Analyze again before applying.") }
        guard !proposal.edits.isEmpty, proposal.edits.count <= 8, !proposal.findings.isEmpty,
              proposal.findings.count <= 5, Set(proposal.findings.map(\.id)).count == proposal.findings.count else {
            throw AstraError.message("\(AgentProvider.current.name) returned an incomplete or oversized proposal.")
        }
        var updated = source.text
        var diff = "File: \(proposal.path)\n\n"
        for edit in proposal.edits {
            guard !edit.oldText.isEmpty, edit.oldText != edit.newText,
                  updated.components(separatedBy: edit.oldText).count == 2 else {
                throw AstraError.message("An edit must match exactly one existing source fragment.")
            }
            updated = updated.replacingOccurrences(of: edit.oldText, with: edit.newText)
            diff += "--- Before\n\(edit.oldText)\n+++ After\n\(edit.newText)\n\n"
        }
        let after = Data(updated.utf8)
        guard after.count <= 131_072 else { throw AstraError.message("Patch exceeds the file size limit.") }
        return AstraPatch(id: UUID(), path: proposal.path, before: Data(source.text.utf8), after: after,
                          beforeHash: source.hash, afterHash: AstraWorkspace.hash(after), reviewText: diff)
    }

    // Only the review UI calls this method; there is no model-callable write tool.
    func apply(_ patch: AstraPatch, approvedID: UUID, workspace: AstraWorkspace, artifacts: URL) throws {
        guard patch.id == approvedID, !used.contains(patch.id), applied == nil else {
            throw AstraError.message("This patch has already been applied or is not the reviewed patch.")
        }
        let url = try workspace.resolve(patch.path, writing: true)
        guard try workspace.read(patch.path).hash == patch.beforeHash else {
            throw AstraError.message("Source changed since review. No files were written.")
        }
        try patch.before.write(to: artifacts.appendingPathComponent("before.css"), options: .atomic)
        try patch.after.write(to: artifacts.appendingPathComponent("after.css"), options: .atomic)
        let receipt: [String: Any] = ["patchID": patch.id.uuidString, "path": patch.path,
            "beforeHash": patch.beforeHash, "afterHash": patch.afterHash, "approvedAt": ISO8601DateFormatter().string(from: Date())]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifacts.appendingPathComponent("approval.json"), options: .atomic)
        // Revalidate immediately before a single atomic replacement, without an await.
        _ = try workspace.resolve(patch.path, writing: true)
        guard try workspace.read(patch.path).hash == patch.beforeHash else { throw AstraError.message("Source changed. Apply cancelled.") }
        try patch.after.write(to: url, options: .atomic)
        applied = patch
        used.insert(patch.id)
    }

    func undo(workspace: AstraWorkspace) throws {
        guard let patch = applied else { throw AstraError.message("No applied fix to undo.") }
        let url = try workspace.resolve(patch.path, writing: true)
        guard try workspace.read(patch.path).hash == patch.afterHash else {
            throw AstraError.message("The file changed after Apply. Undo will not overwrite your edits.")
        }
        try patch.before.write(to: url, options: .atomic)
        applied = nil
    }
}

@MainActor
final class AstraRunArtifacts {
    let url: URL
    init() throws {
        url = try EvidenceStore.newRunDirectory()
    }
    func save<T: Encodable>(_ value: T, name: String) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(value).write(to: url.appendingPathComponent(name), options: .atomic)
    }
    func event(_ name: String, detail: String = "") {
        let line: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "event": name, "detail": detail]
        guard var data = try? JSONSerialization.data(withJSONObject: line, options: .sortedKeys) else { return }
        data.append(0x0a)
        let file = url.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
        }
    }
}
