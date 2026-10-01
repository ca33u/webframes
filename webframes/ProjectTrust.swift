import AppKit
import os

/// One explicit, per-machine consent for everything Web Frames may do with a
/// project folder beyond reading it: running its dev script, running its
/// build tooling for Library previews, and sending its sources to Codex.
///
/// The decision is keyed by the folder's canonical path and stored in
/// `UserDefaults`, never in the `.webframes` document — a document received
/// from someone else must not be able to carry its own approval. A folder
/// the user picks in an open panel for a purpose that already implies the
/// action (Fix with Codex source folder) is trusted at that moment.
@MainActor
enum ProjectTrust {
    static let defaultsKey = "webframes.trustedProjectRoots"

    enum Purpose {
        case devServer(command: String, notice: String?)
        case library
        case codex

        var title: String {
            switch self {
            case .devServer: return "Run This Project’s Dev Server?"
            case .library:   return "Render This Project’s Components?"
            case .codex:     return "Share This Project’s Sources with \(AgentProvider.current.name)?"
            }
        }
        var confirmTitle: String {
            switch self {
            case .devServer: return "Run Server"
            case .library:   return "Render"
            case .codex:     return "Continue"
            }
        }
        func message(root: URL) -> String {
            let footer = "Approving lets Web Frames run this project’s scripts and build tooling and send its "
                + "sources to \(AgentProvider.current.name) from now on. Project scripts can execute code on your Mac."
            switch self {
            case .devServer(let command, let notice):
                let extra = notice.map { "\n\n\($0)" } ?? ""
                return "Web Frames will run:\n\n\(command)\n\nin \(root.path).\(extra)\n\n\(footer)"
            case .library:
                return "Library builds previews with the project’s own configuration "
                    + "(PostCSS plugins, TypeScript, imports) in \(root.path).\n\n\(footer)"
            case .codex:
                return "Fix with \(AgentProvider.current.name) uploads a snapshot of the source files in \(root.path) "
                    + "to \(AgentProvider.current.name) and, after your review, writes approved changes back there.\n\n\(footer)"
            }
        }
    }

    static func canonicalPath(_ root: URL) -> String {
        root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func isTrusted(_ root: URL) -> Bool {
        trustedPaths().contains(canonicalPath(root))
    }

    static func trust(_ root: URL) {
        var paths = trustedPaths()
        paths.insert(canonicalPath(root))
        UserDefaults.standard.set(Array(paths).sorted(), forKey: defaultsKey)
        Log.doc.info("project trusted path=\(canonicalPath(root), privacy: .private)")
    }

    static func revoke(_ root: URL) {
        var paths = trustedPaths()
        paths.remove(canonicalPath(root))
        UserDefaults.standard.set(Array(paths).sorted(), forKey: defaultsKey)
    }

    /// Approved folders, for the Settings list.
    static var trustedFolders: [String] { trustedPaths().sorted() }

    static func revokeAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Returns immediately when the folder is already trusted; otherwise asks
    /// once (as a sheet when a window is available) and records approval.
    static func confirm(_ root: URL, purpose: Purpose, in window: NSWindow?) async -> Bool {
        if isTrusted(root) { return true }
        let alert = NSAlert()
        alert.messageText = purpose.title
        alert.informativeText = purpose.message(root: root)
        alert.addButton(withTitle: purpose.confirmTitle)
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let window, window.isVisible, window.attachedSheet == nil {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        guard response == .alertFirstButtonReturn else { return false }
        trust(root)
        return true
    }

    /// Completion-handler flavour for call sites that are not `async`.
    static func confirm(_ root: URL, purpose: Purpose, in window: NSWindow?,
                        completion: @escaping @MainActor (Bool) -> Void) {
        if isTrusted(root) { completion(true); return }
        Task { @MainActor in completion(await confirm(root, purpose: purpose, in: window)) }
    }

    private static func trustedPaths() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }
}
