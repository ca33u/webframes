import Foundation

struct CodexFixFileProposal: Codable, Equatable {
    let path: String
    let beforeHash: String
    let edits: [AstraEdit]
}

struct CodexCommentFixProposal: Codable, Equatable {
    let summary: String
    let addressedCommentIDs: [String]
    let files: [CodexFixFileProposal]
}

struct CodexCommentContext: Codable, Equatable {
    let id: String
    let comment: String
    let frameLabel: String
    let url: String
    let viewport: String
    let selector: String
    let component: String
    let requestedStyleEdits: [String: String]
    let screenshotIndex: Int?
    let projectName: String
    let xPct: Double
    let yPct: Double
    /// Area comments: the selected region and the elements inside it. The
    /// comment applies to the whole region; nil for a point comment.
    var area: String? = nil
}

struct CodexCommentFixPatchEntry {
    let path: String
    let before: Data
    let after: Data
    let beforeHash: String
    let afterHash: String
    let reviewText: String
    /// Build or dependency configuration; applying needs a second confirmation.
    var isBuildOrConfig: Bool { SourcePolicy.isBuildOrConfigFile(path) }
}

struct CodexCommentFixPatch {
    let id: UUID
    let summary: String
    let addressedCommentIDs: [String]
    let entries: [CodexCommentFixPatchEntry]

    var configEntries: [CodexCommentFixPatchEntry] { entries.filter(\.isBuildOrConfig) }

    var reviewText: String {
        var header = [summary, "Comments: " + addressedCommentIDs.joined(separator: ", ")]
        if !configEntries.isEmpty {
            header.append("⚠︎ Build or dependency configuration: " + configEntries.map(\.path).joined(separator: ", ")
                + "\nThese files can run code when the project installs or builds. Apply asks again before writing them.")
        }
        return (header + entries.map { ($0.isBuildOrConfig ? "⚠︎ " : "") + $0.reviewText }).joined(separator: "\n\n")
    }
}

struct CodexCommentFixEvidenceTarget: Equatable {
    let frameID: String
    let label: String
}

/// Chooses the live frames that can provide before/after evidence for a
/// reviewed comment fix. The order follows the canvas, duplicate comments on
/// one frame collapse to one capture, and static references are deliberately
/// excluded because applying source code cannot refresh their pixels.
enum CodexCommentFixEvidencePlanner {
    static func targets(for patch: CodexCommentFixPatch,
                        annotations: [AnnotationModel],
                        frames: [FrameModel]) -> [CodexCommentFixEvidenceTarget] {
        let addressed = Set(patch.addressedCommentIDs)
        let frameIDs = Set(annotations.lazy
            .filter { addressed.contains($0.id) }
            .map(\.frameId))
        return frames.compactMap { frame in
            guard frameIDs.contains(frame.id), !frame.isImage else { return nil }
            return CodexCommentFixEvidenceTarget(frameID: frame.id, label: frame.label)
        }
    }
}

@MainActor
final class CodexCommentFixService {
    private(set) var applied: CodexCommentFixPatch?
    private var used = Set<UUID>()

    func prepare(_ proposal: CodexCommentFixProposal,
                 allowedCommentIDs: Set<String>,
                 workspace: AstraWorkspace) throws -> CodexCommentFixPatch {
        guard !proposal.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !proposal.addressedCommentIDs.isEmpty,
              Set(proposal.addressedCommentIDs).count == proposal.addressedCommentIDs.count,
              Set(proposal.addressedCommentIDs).isSubset(of: allowedCommentIDs),
              !proposal.files.isEmpty, proposal.files.count <= 8,
              Set(proposal.files.map(\.path)).count == proposal.files.count else {
            throw AstraError.message("\(AgentProvider.current.name) returned an incomplete or oversized comment fix.")
        }

        var entries: [CodexCommentFixPatchEntry] = []
        var totalEdits = 0
        for file in proposal.files {
            let target = try workspace.resolve(file.path)
            let source = try workspace.read(file.path)
            guard source.hash == file.beforeHash,
                  !file.edits.isEmpty, file.edits.count <= 8 else {
                throw AstraError.message("Source changed or a proposed file is incomplete. Run Fix with \(AgentProvider.current.name) again.")
            }
            totalEdits += file.edits.count
            guard totalEdits <= 32 else {
                throw AstraError.message("\(AgentProvider.current.name) proposed too many changes for one reviewed operation.")
            }

            var updated = source.text
            var review = "File: \(file.path)"
            for edit in file.edits {
                guard !edit.oldText.isEmpty, edit.oldText != edit.newText,
                      updated.components(separatedBy: edit.oldText).count == 2 else {
                    throw AstraError.message("Every proposed edit must match one exact source fragment.")
                }
                updated = updated.replacingOccurrences(of: edit.oldText, with: edit.newText)
                review += "\n\n--- Before\n\(edit.oldText)\n+++ After\n\(edit.newText)"
            }
            let after = Data(updated.utf8)
            guard after.count <= 131_072, target.isFileURL else {
                throw AstraError.message("A proposed file exceeds the review limit.")
            }
            entries.append(CodexCommentFixPatchEntry(
                path: file.path,
                before: Data(source.text.utf8),
                after: after,
                beforeHash: source.hash,
                afterHash: AstraWorkspace.hash(after),
                reviewText: review
            ))
        }

        return CodexCommentFixPatch(
            id: UUID(), summary: proposal.summary,
            addressedCommentIDs: proposal.addressedCommentIDs,
            entries: entries
        )
    }

    func apply(_ patch: CodexCommentFixPatch,
               approvedID: UUID,
               configFilesConfirmed: Bool = false,
               workspace: AstraWorkspace,
               artifacts: URL) throws {
        guard patch.id == approvedID, !used.contains(patch.id), applied == nil else {
            throw AstraError.message("This comment fix was already applied or was not the reviewed proposal.")
        }
        guard patch.configEntries.isEmpty || configFilesConfirmed else {
            throw AstraError.message("This fix changes build or dependency configuration and needs a separate confirmation. No files were written.")
        }

        let targets = try patch.entries.map { entry -> URL in
            let target = try workspace.resolve(entry.path)
            guard try workspace.read(entry.path).hash == entry.beforeHash else {
                throw AstraError.message("Source changed since review. No files were written.")
            }
            return target
        }

        let receipt: [String: Any] = [
            "patchID": patch.id.uuidString,
            "commentIDs": patch.addressedCommentIDs,
            "configFilesConfirmed": configFilesConfirmed,
            "files": patch.entries.map { ["path": $0.path, "beforeHash": $0.beforeHash, "afterHash": $0.afterHash] },
            "approvedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
            .write(to: artifacts.appendingPathComponent("comment-fix-approval.json"), options: .atomic)

        var written: [Int] = []
        do {
            for index in patch.entries.indices {
                try patch.entries[index].before.write(
                    to: artifacts.appendingPathComponent("comment-fix-\(index)-before.txt"), options: .atomic
                )
                try patch.entries[index].after.write(
                    to: artifacts.appendingPathComponent("comment-fix-\(index)-after.txt"), options: .atomic
                )
                try patch.entries[index].after.write(to: targets[index], options: .atomic)
                written.append(index)
            }
        } catch {
            for index in written.reversed() {
                try? patch.entries[index].before.write(to: targets[index], options: .atomic)
            }
            throw AstraError.message("A file could not be written. Already-written files were restored.")
        }
        applied = patch
        used.insert(patch.id)
    }

    func undo(workspace: AstraWorkspace) throws {
        guard let patch = applied else { throw AstraError.message("No applied \(AgentProvider.current.name) fix to undo.") }
        let targets = try patch.entries.map { entry -> URL in
            let target = try workspace.resolve(entry.path)
            guard try workspace.read(entry.path).hash == entry.afterHash else {
                throw AstraError.message("A file changed after Apply. Undo will not overwrite your edits.")
            }
            return target
        }
        for index in patch.entries.indices {
            try patch.entries[index].before.write(to: targets[index], options: .atomic)
        }
        applied = nil
    }
}

enum CodexCommentContextBuilder {
    static func make(annotations: [AnnotationModel],
                     frames: [FrameModel], projectName: String = "",
                     frameScreenshots: [String: String] = [:]) -> (comments: [CodexCommentContext], images: [String]) {
        var images: [String] = []
        var imageIndices: [String: Int] = [:]
        let openFrameIDs = Set(annotations.filter { !$0.resolved }.map(\.frameId))
        for frame in frames where openFrameIDs.contains(frame.id) {
            if images.count < 5, let png = frameScreenshots[frame.id] {
                imageIndices[frame.id] = images.count
                images.append(png)
            }
        }
        let comments = annotations.filter { !$0.resolved }.map { annotation in
            let frame = frames.first(where: { $0.id == annotation.frameId })
            let element = object(annotation.extras["element"])
            let screenshot = string(element?["screenshot"])
            let screenshotIndex: Int?
            if let index = imageIndices[annotation.frameId] {
                screenshotIndex = index
            } else if images.count < 5, let screenshot, screenshot.hasPrefix("data:image/png;base64,") {
                screenshotIndex = images.count
                images.append(screenshot)
            } else {
                screenshotIndex = nil
            }
            return CodexCommentContext(
                id: annotation.id,
                comment: String(annotation.comment.prefix(8_000)),
                frameLabel: frame?.label ?? annotation.frameLabel ?? "Frame",
                url: URLRedaction.redact(frame?.url ?? annotation.frameUrl ?? ""),
                viewport: frame.map { "\(Int($0.w))×\(Int($0.h))" } ?? "",
                selector: string(element?["path"])
                    ?? string(element?["selector"])
                    ?? string(element?["tagName"]) ?? "—",
                component: string(element?["componentName"])
                    ?? string(element?["component"]) ?? "",
                requestedStyleEdits: annotation.edits,
                screenshotIndex: screenshotIndex,
                projectName: projectName,
                xPct: Double(annotation.xPct), yPct: Double(annotation.yPct),
                area: annotation.areaSummary
            )
        }
        return (comments, images)
    }

    private static func object(_ value: JSONValue?) -> [String: JSONValue]? {
        if case .object(let object) = value { return object }
        return nil
    }

    private static func string(_ value: JSONValue?) -> String? {
        if case .string(let string) = value { return string }
        return nil
    }
}
