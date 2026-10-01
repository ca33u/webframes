import AppKit
import os
import UniformTypeIdentifiers

/// `NSDocument` wrapper over a `.webframes` file — the working-file format
/// for a Web Frames project (name + frames + annotations + links + canvas
/// viewport).
///
/// Storage model
/// =============
/// The app owns the projects directory (`ProjectStorage.projectsDirectory`)
/// and assigns every new document a UUID-based `fileURL` at creation time.
/// `NSSavePanel` / `NSOpenPanel` are never shown to the user — listing,
/// opening, and deletion happen from the Start window. `autosavesInPlace`
/// is enabled, so AppKit writes changes to disk in the background whenever
/// `updateChangeCount(.changeDone)` is called from the canvas bridge.
///
/// Cmd+S
/// =====
/// Overridden to flush pending auto-save and surface a "no need to save —
/// auto-save is on" toast, rather than invoking the standard save pipeline
/// (which would otherwise be a no-op from the user's point of view).
@objc(WebFramesDocument)
final class WebFramesDocument: NSDocument {

    /// In-memory state. Mutations originate from the canvas JS (via
    /// `doc-state-changed`) and are applied via `applyCanvasState(_:)`.
    private(set) var payload: DocumentPayload = .empty

    /// Typed Swift mirror of `payload` (frames/links/annotations/viewport
    /// as structs rather than JSONValue). Kept in sync by
    /// `applyCanvasState(_:)`. Read-only until Phase 6d — native code that
    /// prefers typed access can read from here today; the canvas JS is
    /// still the source of truth for mutations.
    let workspace = WorkspaceStore()
    private lazy var commentsInbox = CommentsMCPInbox(document: self)

    /// Mirror of the last state the canvas told us about. Used to
    /// `updateChangeCount(.changeDone)` only when something actually changed
    /// — otherwise we'd mark pristine documents dirty on every re-load.
    private var lastObservedPayload: DocumentPayload = .empty

    /// UTI for `.webframes` files. Registered in Info.plist under
    /// `UTExportedTypeDeclarations` + `CFBundleDocumentTypes`.
    static let fileTypeIdentifier = "app.essazanov.webframes.document"

    /// Filename extension. Kept as a constant so file panel configuration and
    /// the UTI declaration can reference one source of truth.
    static let fileExtension = "webframes"

    private var needsInitialManagedSave = true
    private var initialManagedSaveInFlight = false

    override init() {
        super.init()
        // Phase 6d owns undo: every undoable mutation on `workspace`
        // registers an inverse closure with this document's
        // `NSUndoManager` (see `workspaceStore(_:didApplyMutation:)`
        // below). The JS `undoStack` in index.html is now dead code —
        // kept only until Phase 6e strips the canvas WKWebView.
        hasUndoManager = true
        // Every fresh document gets a managed URL immediately — no "untitled"
        // in-memory state, no save panel ever. The file itself is created by
        // the first auto-save.
        fileURL = ProjectStorage.newProjectURL()
        fileType = Self.fileTypeIdentifier
        // The managed URL is the final destination, not a placeholder that
        // requires Save As. Marking the document as a draft makes AppKit ask
        // for a save location during close. The old no-op save-panel override
        // then left the close activity waiting forever.
        isDraft = false
        // Phase 6d: the document is the workspace store's delegate — any
        // native mutation routed through the store gets persisted back
        // into `payload`, forwarded to the canvas JS so the WKWebView
        // mirrors the Swift-side state, and registered with the document's
        // undo manager. Call sites that still forward to JS (frame drag /
        // resize / rename / link create-delete, undo path through the
        // canvas Cmd+Z keydown) will migrate over subsequent passes; each
        // flip is independently verifiable under the debugger.
        workspace.delegate = self
    }

    override func close() {
        commentsInbox.stop()
        super.close()
    }

    // NSDocument declares this nonisolated; under SWIFT_DEFAULT_ACTOR_ISOLATION
    // = MainActor our override inherits MainActor and the compiler flags the
    // isolation mismatch. Explicit `nonisolated` restores the base's contract
    // (body is a trivial constant — no isolated state is touched).
    nonisolated override class var autosavesInPlace: Bool { true }

    // NSDocument declares makeWindowControllers nonisolated; match it so the
    // override is dispatched on the same actor as the base — otherwise the
    // controller we add here gets dropped before showWindows can run it, and
    // doc.windowControllers stays empty. AppKit drives this on the main
    // thread, so `MainActor.assumeIsolated` is safe; if that invariant ever
    // changes it will trap loudly rather than silently lose the window.
    nonisolated override func makeWindowControllers() {
        MainActor.assumeIsolated {
            let wc = DocumentWindowController(document: self)
            addWindowController(wc)
            commentsInbox.start()
            // We used to pre-materialize an empty `.webframes` file here so
            // fresh projects appeared in the Start list even if the user
            // closed without touching the canvas. That fought
            // `autosavesInPlace`'s draft semantics — AppKit discarded the
            // file on close as a never-explicitly-saved draft — and left
            // empty "Untitled" placeholders cluttering Recent anyway. Now:
            // the project materialises on the first meaningful change
            // (rename / add frame / move canvas) via the existing
            // `updateChangeCount(.changeDone)` → autosave pipeline.
        }
    }

    // MARK: - Read / Write

    // NSDocument declares read(from:ofType:) nonisolated. Our override must
    // match — but the body mutates `payload` / `lastObservedPayload`, which
    // are MainActor-isolated on this class. NSDocument drives file reads on
    // the main thread in practice (via NSDocumentController's open pipeline),
    // so `MainActor.assumeIsolated` is safe here; if that invariant ever
    // changes, it will trap loudly rather than silently corrupt state.
    nonisolated override func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        try MainActor.assumeIsolated {
            do {
                let (decoded, package) = try DocumentPackage.read(fileWrapper)
                try load(decoded)
                packageWrapper = package
            } catch let error as DocumentVersionError {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
                    NSLocalizedDescriptionKey: "This project was saved by a newer version of Web Frames.",
                    NSLocalizedRecoverySuggestionErrorKey: "Update Web Frames (Web Frames › Check for Updates…) to open it. Format version \(error.found); this build reads up to \(DocumentPayload.currentVersion).",
                ])
            } catch {
                Log.doc.error("failed to decode .webframes: \(error.localizedDescription, privacy: .private)")
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadCorruptFileError,
                    userInfo: [NSLocalizedDescriptionKey: "This file is not a valid .webframes document."]
                )
            }
        }
    }

    /// Version-1 JSON (tests and callers holding raw bytes).
    nonisolated override func read(from data: Data, ofType typeName: String) throws {
        try read(from: FileWrapper(regularFileWithContents: data), ofType: typeName)
    }

    private func load(_ decoded: DocumentPayload) throws {
        guard decoded.version <= DocumentPayload.currentVersion else {
            throw DocumentVersionError(found: decoded.version)
        }
        needsInitialManagedSave = false
        isDraft = false
        payload = decoded
        lastObservedPayload = decoded
        // Keep the typed store in sync on every disk load so native code
        // that reads it right after open sees the document's content.
        workspace.apply(decoded)
    }

    /// The package from the last read or save, updated in place on the next
    /// save so unchanged image files are carried over, not rewritten.
    private var packageWrapper: FileWrapper?

    /// Saves as a package (format version 2); see `DocumentPackage`.
    override func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let package = try DocumentPackage.wrapper(for: payload, updating: packageWrapper)
        packageWrapper = package
        return package
    }

    /// A single self-contained JSON with inline images (format version 2
    /// without external references), for export and tests.
    override func data(ofType typeName: String) throws -> Data {
        var inline = payload
        inline.version = DocumentPayload.currentVersion
        return try DocumentPackage.encode(inline)
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        // `read(from:)` → `workspace.apply(_:)` already fired every
        // observer, so the native views on each `CanvasHost` have
        // already repainted with the reverted state. Just refresh the
        // window title. Phase 6e Step 70e: no more
        // `pushDocumentStateToCanvas` here — the JS canvas is gone, the
        // workspace observer is the only sink.
        for case let wc as DocumentWindowController in windowControllers {
            wc.refreshTitle()
        }
    }

    // MARK: - Save overrides
    //
    // The user never picks a save location: every document has a managed
    // `fileURL` from `init()`, and `autosavesInPlace` takes care of writing
    // changes to disk in the background. What's left is translating Cmd+S
    // into a visible "you don't need to save" signal.

    /// The first write must be an explicit save: autosaving to a URL whose
    /// file does not exist triggers NSDocument's ownership/safety alert.
    /// Delay it until the first edit so untouched windows create no files.
    private func markWorkspaceChanged() {
        updateChangeCount(.changeDone)
        guard needsInitialManagedSave, !initialManagedSaveInFlight,
              !windowControllers.isEmpty, let url = fileURL else { return }
        initialManagedSaveInFlight = true
        save(to: url, ofType: Self.fileTypeIdentifier, for: .saveOperation) { [weak self] error in
            guard let self else { return }
            self.initialManagedSaveInFlight = false
            if let error {
                Log.doc.error("Initial project save failed: \(error.localizedDescription, privacy: .private)")
                self.presentError(error)
            } else {
                self.needsInitialManagedSave = false
            }
        }
    }

    /// The first write is the explicit save in `markWorkspaceChanged`, which
    /// runs once the project has a window. A window-less document that was
    /// never saved has nothing to autosave yet.
    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool,
                           completionHandler: @escaping (Error?) -> Void) {
        if needsInitialManagedSave && windowControllers.isEmpty {
            completionHandler(nil)
            return
        }
        super.autosave(withImplicitCancellability: autosavingIsImplicitlyCancellable,
                       completionHandler: completionHandler)
    }

    override func save(_ sender: Any?) {
        Log.doc.info("Cmd+S — flushing autosave and showing toast")
        autosave(withImplicitCancellability: false) { [weak self] error in
            guard let self else { return }
            if let error {
                // "Auto-save is on" would be false reassurance here.
                Log.doc.error("autosave failed: \(error.localizedDescription, privacy: .private)")
                self.presentError(error)
                return
            }
            self.showAutoSaveToastInAllWindows()
        }
    }

    override func saveAs(_ sender: Any?) { save(sender) }
    override func saveTo(_ sender: Any?) { save(sender) }

    private func showAutoSaveToastInAllWindows() {
        for case let wc as DocumentWindowController in windowControllers {
            wc.showAutoSaveToast()
        }
    }

    // MARK: - Bridge integration

    /// Called by the canvas host when a `doc-state-changed` message arrives.
    /// Updates `payload` and marks the document dirty if the new state
    /// differs from what we last observed.
    func applyCanvasState(_ dict: [String: Any]) {
        // The canvas doesn't own the project name — keep whatever the native
        // titlebar has set, even if the incoming dict lacks the field.
        var incoming = DocumentPayload(fromDictionary: dict)
        incoming.name = payload.name
        incoming.projectMap = payload.projectMap
        incoming.fixSource = payload.fixSource
        guard incoming != lastObservedPayload else { return }
        payload = incoming
        lastObservedPayload = incoming
        // Refresh the typed shadow. `WorkspaceStore.apply` is idempotent
        // and cheap — linear over the arrays, no allocation beyond the
        // typed structs themselves. Fires any observers registered via
        // `workspace.observe(_:)`, which is how Phase 6d UI subscribers
        // will eventually re-render.
        workspace.apply(incoming)
        markWorkspaceChanged()
    }

    /// Convenience for the canvas host: the payload as a JS-ready dict.
    var payloadAsDictionary: [String: Any] { payload.asDictionary }

    /// Records the Fix with Codex source folder. Returns false (and keeps the
    /// path only) when macOS refuses a bookmark, so callers can tell the user
    /// the folder must be chosen again after relaunch.
    @discardableResult
    func setFixSource(_ url: URL) -> Bool {
        let bookmark = try? SecurityScopedAccess.makeBookmark(for: url)
        storeFixSource(path: url.path, bookmark: bookmark)
        return bookmark != nil
    }

    /// The saved fix source, re-resolved; a stale bookmark (folder moved or
    /// renamed) is rewritten together with the new path.
    func resolvedFixSource() -> URL? {
        guard let saved = payload.fixSource else { return nil }
        let resolution = SecurityScopedAccess.resolve(bookmark: saved.bookmark, fallbackPath: saved.path)
        if let refreshed = resolution.refreshedBookmark {
            storeFixSource(path: resolution.url.path, bookmark: refreshed)
        }
        return resolution.url
    }

    /// The imported project folder, re-resolved; refreshes a stale bookmark
    /// and the saved root path in the project map.
    func resolvedProjectRoot() -> URL? {
        guard var map = workspace.projectMap, !map.rootPath.isEmpty else { return nil }
        let resolution = SecurityScopedAccess.resolve(bookmark: map.bookmark, fallbackPath: map.rootPath)
        if let refreshed = resolution.refreshedBookmark {
            map.bookmark = refreshed
            map.rootPath = resolution.url.path
            workspace.setProjectMap(map)
        }
        return resolution.url
    }

    private func storeFixSource(path: String, bookmark: Data?) {
        let reference = FixSourceReference(path: path, bookmark: bookmark)
        payload.fixSource = reference
        lastObservedPayload.fixSource = reference
        markWorkspaceChanged()
    }

    // MARK: - Name

    /// Updates the project's display name, marks the document dirty, and
    /// syncs window titles. Called by the native titlebar text field when
    /// the user commits an edit.
    func setName(_ newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "Untitled" : trimmed
        guard resolved != payload.name else { return }
        payload.name = resolved
        lastObservedPayload.name = resolved
        markWorkspaceChanged()
        for case let wc as DocumentWindowController in windowControllers {
            wc.refreshTitle()
        }
    }

    override var displayName: String! {
        get { payload.name.isEmpty ? "Untitled" : payload.name }
        set { /* ignored — the name is driven by payload.name via setName(_:) */ }
    }
}

// MARK: - WorkspaceStoreDelegate

/// Persist-and-undo hook. When native UI routes a mutation through
/// `WorkspaceStore`, the store calls this delegate once the typed model
/// is updated. Two things happen here:
///
///   1. **Persist.** Serialize the store into `payload` and mark the
///      document dirty so `autosavesInPlace` writes the change.
///   2. **Register undo.** For every undoable mutation we register an
///      inverse closure with the document's `NSUndoManager`. The closure
///      calls back into another workspace mutation method which re-enters
///      this delegate — `NSUndoManager` sees that the nested registration
///      happened inside an undo and promotes it to redo, giving symmetric
///      undo/redo for free. Non-undoable mutations (frame resize / rename,
///      viewport pan-zoom) deliberately skip the `registerUndo`
///      call, matching the JS `undoStack` policy this replaces.
///
/// Phase 6d used to do a third thing — push the serialized payload at
/// the canvas WKWebView so JS's `frames` / `annotations` / `links`
/// arrays could catch up. Step 70e retired the canvas WKWebView, so
/// the native UI subscribes to `WorkspaceStore.observe` directly and
/// the mirror step is gone. The companion `apply(_:)` path on the
/// store still skips this delegate on purpose — it's used by
/// `revert(toContentsOf:)` / `undo(_:)` where the native observer
/// alone is enough and an extra undo registration would double-count.
extension WebFramesDocument: WorkspaceStoreDelegate {
    func workspaceStore(_ store: WorkspaceStore,
                        didApplyMutation mutation: WorkspaceMutation) {
        // 1. Persist.
        if case .viewportChanged(let viewport) = mutation {
            // Every scroll-wheel tick lands here. Frames, annotations and
            // links are untouched, so refresh only the `canvas` slot
            // instead of re-serializing the whole document (with its
            // base64 images) at pointer rate.
            payload.canvas = viewport.jsonValue
            lastObservedPayload = payload
        } else {
            var serialized = store.serialize()
            serialized.name = payload.name
            serialized.fixSource = payload.fixSource
            payload = serialized
            lastObservedPayload = serialized
        }
        markWorkspaceChanged()

        // 2. Paint.
        //
        // Phase 6e Step 70e: Swift is authoritative for every mutation,
        // and the canvas WKWebView is gone. The native UI subscribes to
        // `workspace.observe` directly (see `CanvasHost.installWorkspaceObserver`)
        // so the observer callback already fired inside `finish(_:)` on
        // the store — there's no longer a JS mirror to push to. What
        // remains here is (1) persist (above) and (3) register undo
        // (below); the bridge's `pushDocumentStateToCanvas` /
        // `pushViewportToCanvas` are dead along with the canvas channel.

        // 3. Register undo (skipped when there's no undoManager — e.g.
        // while the document is being torn down).
        guard let undoManager else { return }
        registerUndo(for: mutation, undoManager: undoManager)
    }

    /// Extracts the undo registration into its own function so the
    /// delegate method stays readable. Each case maps a forward mutation
    /// to its semantic inverse; the `registerUndo` closure runs on the
    /// main actor (NSUndoManager dispatches on the thread that registered
    /// it) and captures only value-type payloads, so there's no retain
    /// cycle concern. The action name drives the menu-bar "Undo <name>"
    /// / "Redo <name>" labels.
    private func registerUndo(for mutation: WorkspaceMutation,
                              undoManager: UndoManager) {
        switch mutation {
        case .commentStatusesChanged(let previous):
            undoManager.registerUndo(withTarget: self) { $0.workspace.restoreCommentStatuses(previous) }
            undoManager.setActionName("Change Agent Comment Status")
        case .framesReordered(let ids):
            undoManager.registerUndo(withTarget: self) { $0.workspace.reorderFrames(ids) }
            undoManager.setActionName("Reorder Frames")
        case .annotationDeleted(let ann):
            undoManager.registerUndo(withTarget: self) { doc in
                doc.workspace.createAnnotation(ann)
            }
            undoManager.setActionName("Delete Comment")

        case .annotationCreated(let ann):
            undoManager.registerUndo(withTarget: self) { doc in
                doc.workspace.deleteAnnotation(id: ann.id)
            }
            undoManager.setActionName("Add Comment")

        case .annotationUpdated(let id, let previous):
            undoManager.registerUndo(withTarget: self) { doc in
                doc.workspace.updateAnnotation(
                    id: id,
                    comment: previous.comment,
                    color: previous.color,
                    edits: previous.edits
                )
            }
            undoManager.setActionName("Edit Comment")

        case .annotationResolvedToggled(let id, _):
            // Toggle is self-inverse — a second toggle undoes the first.
            undoManager.registerUndo(withTarget: self) { doc in
                doc.workspace.toggleAnnotationResolved(id: id)
            }
            undoManager.setActionName("Change Comment Status")

        case .linkCreated(let link):
            undoManager.registerUndo(withTarget: self) { doc in
                doc.workspace.deleteLink(id: link.id)
            }
            undoManager.setActionName("Add Link")

        case .linkDeleted(let link):
            undoManager.registerUndo(withTarget: self) { doc in
                doc.workspace.createLink(link)
            }
            undoManager.setActionName("Delete Link")

        case .imagesReplaced(let frames, let annotations):
            undoManager.registerUndo(withTarget: self) { doc in
                doc.workspace.restoreImages(frames: frames, annotations: annotations)
            }
            undoManager.setActionName("Reduce Image Sizes")

        case .linkBendsChanged(let previous):
            undoManager.registerUndo(withTarget: self) { doc in
                doc.workspace.setLinkBends(id: previous.id, bends: previous.bends)
            }
            undoManager.setActionName("Move Link Bend")

        case .frameCreated(let frame):
            undoManager.registerUndo(withTarget: self) { doc in
                doc.workspace.deleteFrame(id: frame.id)
            }
            undoManager.setActionName("Add Frame")

        case .frameDeleted(let frame, let anns, let links):
            // Restore order matches `WorkspaceStore.undo` for the
            // equivalent op: frame first, then dependents. Creation
            // helpers are idempotent (id-guarded) so the order is robust
            // against duplicate restore attempts.
            undoManager.registerUndo(withTarget: self) { doc in
                doc.workspace.createFrame(frame)
                for link in links { doc.workspace.createLink(link) }
                for ann  in anns  { doc.workspace.createAnnotation(ann) }
            }
            undoManager.setActionName("Delete Frame")

        case .frameMoved(let id, let origin):
            undoManager.registerUndo(withTarget: self) { $0.workspace.moveFrame(id: id, to: origin) }
            undoManager.setActionName("Move Frames")

        case .frameResized, .frameRenamed,
             .viewportChanged, .countersReset, .projectMapChanged:
            // Non-undoable by design. Matches JS `undoStack` which only
            // stores deletions. Viewport changes are continuous-gesture
            // noise; resizes/renames are treated as direct edits.
            // `.countersReset` matches JS `annResetCounters`, which also
            // had no undo hook.
            break
        }
    }
}

struct DocumentVersionError: Error { let found: Int }
