import Foundation
import CoreGraphics

/// Shadow copy of the workspace state (frames / links / annotations /
/// viewport), kept in sync with the authoritative JS state via
/// `DocumentPayload`.
///
/// Role (today, Phase 6d-prep)
/// ===========================
/// `WorkspaceStore` is a **read-only mirror**. It's rebuilt from the
/// `DocumentPayload` every time the canvas fires `doc-state-changed`,
/// and exposes typed arrays (`frames: [FrameModel]`, `links: [LinkModel]`,
/// etc.) to any native code that prefers working with structs instead of
/// the loose `JSONValue` payload. It does NOT yet drive the UI — the
/// canvas WKWebView is still the source of truth.
///
/// Role (Phase 6d / 6e)
/// ====================
/// When the source-of-truth flip happens, this store becomes authoritative.
/// The planned evolution:
///
///   1. Add mutation API (`createFrame`, `moveFrame`, `deleteFrame`,
///      `createLink`, …). Each mutation updates the arrays, emits a
///      `WorkspaceMutation` to the delegate (so `WebFramesDocument` can
///      write the updated `DocumentPayload` back into its `payload` and
///      `updateChangeCount(.changeDone)`), and notifies observers.
///   2. Wire native UI components (FrameManager, LinkLayerView, PinOverlay,
///      AnnotationPanel, Dock) to subscribe via `observe` instead of the
///      current JS-driven pushes.
///   3. Port the JS mutation logic (dockAddFrame, addLink, drag/resize,
///      pin-editor save/delete/toggle, undo/redo) into Swift methods on
///      this store.
///   4. Strip the canvas WKWebView (Phase 6e).
///
/// Undo lives in the document's NSUndoManager, fed by the `WorkspaceMutation`
/// each method emits (see `WebFramesDocument.registerUndo(for:)`).
///
/// Threading
/// =========
/// Accessed from the main actor only — all workspace mutations originate
/// from UI events or bridge messages which are already main-actor-bound.
/// The `@MainActor` annotation makes that invariant explicit.
@MainActor
final class WorkspaceStore {

    // MARK: - State (typed mirror)

    private(set) var frames:      [FrameModel]      = []
    private(set) var links:       [LinkModel]       = []
    private(set) var annotations: [AnnotationModel] = []
    private(set) var viewport:    ViewportModel     = .identity

    /// Project display name. Carried through `apply(_:)` from
    /// `DocumentPayload.name`. Not mutated by any of the mutation methods
    /// below — the titlebar text field drives name edits directly on
    /// `WebFramesDocument`.
    private(set) var name: String = "Untitled"
    private(set) var projectMap: ProjectMapSnapshot?

    func setProjectMap(_ map: ProjectMapSnapshot) {
        guard projectMap != map else { return }; projectMap = map; finish(.projectMapChanged)
    }
    func reorderFrames(_ ids: [String]) {
        let previous = frames.map(\.id)
        guard ids != previous, ids.count == previous.count, Set(ids) == Set(previous) else { return }
        let byID = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, $0) })
        frames = ids.compactMap { byID[$0] }
        finish(.framesReordered(previousIDs: previous))
    }
    func setFrameSource(id: String, url: String) {
        guard let i = frames.firstIndex(where: { $0.id == id }), frames[i].url != url else { return }
        frames[i].url = url; finish(.projectMapChanged)
    }
    func setFrameWebSource(id: String, sourceID: String?) {
        guard let i = frames.firstIndex(where: { $0.id == id }) else { return }
        let previous = frames[i].extras["webSourceID"]
        if let sourceID { frames[i].extras["webSourceID"] = .string(sourceID) }
        else { frames[i].extras.removeValue(forKey: "webSourceID") }
        guard frames[i].extras["webSourceID"] != previous else { return }
        finish(.projectMapChanged)
    }

    /// Freeze a live web frame into a persisted bitmap while preserving
    /// the frame identity, geometry, links, annotations, and source URL.
    func convertFrameToSnapshot(id: String, dataURL: String,
                                sourceURL: String, pixelSize: CGSize) {
        guard let i = frames.firstIndex(where: { $0.id == id }),
              !frames[i].isImage, !dataURL.isEmpty else { return }
        frames[i].extras["snapshotSourceURL"] = .string(sourceURL)
        frames[i].extras["snapshotCapturedAt"] = .string(
            ISO8601DateFormatter().string(from: Date())
        )
        frames[i].extras["imgUrl"] = .string(dataURL)
        frames[i].extras["natW"] = .number(Double(max(1, pixelSize.width)))
        frames[i].extras["natH"] = .number(Double(max(1, pixelSize.height)))
        frames[i].url = "image://snapshot-\(frames[i].id)"
        frames[i].isImage = true
        frames[i].filePath = nil
        finish(.projectMapChanged)
    }

    /// Restore a frozen web snapshot to its retained live URL in place.
    func restoreLiveFrame(id: String) {
        guard let i = frames.firstIndex(where: { $0.id == id }),
              frames[i].isImage,
              case .string(let sourceURL) = frames[i].extras["snapshotSourceURL"] ?? .null,
              !sourceURL.isEmpty else { return }
        frames[i].url = sourceURL
        frames[i].isImage = false
        frames[i].extras.removeValue(forKey: "snapshotSourceURL")
        frames[i].extras.removeValue(forKey: "snapshotCapturedAt")
        frames[i].extras.removeValue(forKey: "imgUrl")
        frames[i].extras.removeValue(forKey: "natW")
        frames[i].extras.removeValue(forKey: "natH")
        finish(.projectMapChanged)
    }

    /// On-disk schema version tag. Mirrors `DocumentPayload.version`.
    /// Carried through so `serialize()` produces an identical envelope
    /// shape to whatever the JS side wrote, preventing spurious schema
    /// downgrades on flip day.
    private(set) var schemaVersion: Int = 1

    /// Running counters — carried from the payload so numbering is stable
    /// across reload. Mutations that allocate a new frame/annotation bump
    /// these.
    private(set) var nextFrameNum: Int = 1
    private(set) var nextAnnNum:   Int = 1

    /// Serial that increments on every `apply(_:)` or mutation call.
    /// Observers compare it to detect staleness without deep-diffing
    /// the arrays.
    private(set) var version: Int = 0

    // MARK: - Delegate (Phase 6d mutation sink)

    /// The owner (`WebFramesDocument` in production) listens for mutations
    /// to persist them back into `DocumentPayload` and mark the document
    /// dirty. Weak reference because the document owns the store.
    weak var delegate: WorkspaceStoreDelegate?

    // MARK: - Observers

    /// Opaque handle returned by `observe(_:)`. Owning it keeps the
    /// registration alive; releasing it unregisters automatically. Mirrors
    /// the NotificationCenter / Combine cancellation pattern but stays
    /// lightweight (no Combine dependency).
    final class Subscription {
        fileprivate let id: Int
        fileprivate weak var store: WorkspaceStore?
        fileprivate init(id: Int, store: WorkspaceStore) {
            self.id = id
            self.store = store
        }
        deinit {
            // Retain cycle is impossible because the callback map holds by
            // id, not by `Subscription`. The deinit is our cancellation.
            //
            // Copy the captures into locals before spawning the Task —
            // Swift 6 rejects implicit `self` capture across a closure
            // that outlives `deinit`, so the Task must reference only
            // local bindings, not `self.id` / `self.store`.
            let capturedId = id
            guard let capturedStore = store else { return }
            Task { @MainActor in capturedStore.remove(id: capturedId) }
        }
    }

    private var nextSubscriptionId = 1
    private var callbacks: [Int: () -> Void] = [:]

    /// Register a callback fired after every `apply(_:)` or mutation.
    /// Fires once synchronously on registration so late subscribers see
    /// the current state immediately.
    func observe(_ block: @escaping () -> Void) -> Subscription {
        let id = nextSubscriptionId
        nextSubscriptionId += 1
        callbacks[id] = block
        block()
        return Subscription(id: id, store: self)
    }

    fileprivate func remove(id: Int) { callbacks.removeValue(forKey: id) }

    // MARK: - Apply (rebuild from payload)

    /// Rebuilds the typed mirror from the serialized `DocumentPayload`.
    /// Called by `WebFramesDocument.applyCanvasState(_:)` — which is the
    /// single funnel for canvas-originated state changes — right after it
    /// updates `payload`. Invalid / malformed entries are skipped rather
    /// than fatal; the JS side is still authoritative and Swift is just
    /// mirroring, so one bad annotation shouldn't break the whole store.
    ///
    /// `apply(_:)` does NOT fire the delegate — a round-trip from the
    /// payload back into the payload would just re-mark the document
    /// dirty on every reload. Observers still fire because UI may need
    /// to redraw (e.g. after open-document).

    func apply(_ payload: DocumentPayload) {
        projectMap    = payload.projectMap
        name          = payload.name
        schemaVersion = payload.version
        frames        = payload.frames.compactMap(FrameModel.init(jsonValue:))
        links         = payload.links.compactMap(LinkModel.init(jsonValue:))
        annotations   = payload.annotations.compactMap(AnnotationModel.init(jsonValue:))
        viewport      = ViewportModel(jsonValue: payload.canvas)
        nextFrameNum  = payload.nextNum
        nextAnnNum    = payload.annNext
        version &+= 1
        for cb in callbacks.values { cb() }
    }

    /// Inverse of `apply(_:)`. Produces the `DocumentPayload` that would
    /// round-trip to the current typed state. Used by the delegate to
    /// persist mutations back into `WebFramesDocument.payload`.
    ///
    /// Field ordering matches `DocumentPayload`'s declaration so the
    /// `sortedKeys`-encoded JSON has a stable, diffable shape on disk.
    func serialize() -> DocumentPayload {
        var p = DocumentPayload()
        p.projectMap  = projectMap
        p.version     = schemaVersion
        p.name        = name
        p.frames      = frames.map(\.jsonValue)
        p.annotations = annotations.map(\.jsonValue)
        p.links       = links.map(\.jsonValue)
        p.canvas      = viewport.jsonValue
        p.nextNum     = nextFrameNum
        p.annNext     = nextAnnNum
        return p
    }

    // MARK: - Read-only queries

    /// Returns the frame with the given id, or nil if missing.
    func frame(id: String) -> FrameModel? {
        // Linear scan — `frames` typically has single-digit counts, so a
        // dictionary cache would be pure overhead. Revisit only if a
        // realistic project grows past ~200 frames.
        frames.first { $0.id == id }
    }

    /// All annotations belonging to the given frame, in the order JS stored
    /// them. Callers that need a specific visual order should sort.
    func annotations(for frameId: String) -> [AnnotationModel] {
        annotations.filter { $0.frameId == frameId }
    }

    /// True if any link references the frame on either end. Used by
    /// `deleteFrame` to decide whether to also prune dangling links.
    func hasLinksReferencing(frameId: String) -> Bool {
        links.contains { $0.fromId == frameId || $0.toId == frameId }
    }

    // MARK: - Mutation API
    //
    // Every mutation below:
    //   1. No-ops silently on missing IDs (matches the JS `find` + early
    //      return pattern — mutations are idempotent in that deleting a
    //      frame twice is not a crash).
    //   2. Updates the typed arrays in place.
    //   3. Emits a `WorkspaceMutation` to the delegate so the document
    //      can persist. The mutation value carries enough context that
    //      the delegate doesn't have to diff the whole state.
    //   5. Fires observers.
    //
    // The methods do NOT allocate IDs. Callers (UI code, tests) pass
    // explicit IDs — matches the JS `"f" + Date.now() + Math.random()`
    // pattern where the caller owns ID generation. `WorkspaceIDGenerator`
    // below offers a default generator but mutations accept any string.

    /// Appends a frame. The caller is responsible for generating a unique
    /// id and allocating `num` (usually via `allocateFrameNum()`).
    ///
    /// Duplicate ids are rejected (no-op) — matches JS behavior where
    /// frame creation funnels through `dockAddFrame` → `spawnFrame` which
    /// always generates a fresh id via timestamped random.
    ///
    /// Advances `nextFrameNum` past the incoming frame's `num` so the
    /// round-trip back into JS's `nextNum` doesn't regress to an already-
    /// used value. Without this, JS would pre-increment its local
    /// `nextNum`, send the frame with `num=N`, then `applyDocState` would
    /// reset `nextNum` to `N` from `payload.nextNum` — the next spawn
    /// would collide on num. Same rationale for `createAnnotation`.
    @discardableResult
    func createFrame(_ frame: FrameModel) -> FrameModel? {
        guard !frames.contains(where: { $0.id == frame.id }) else { return nil }
        frames.append(frame)
        nextFrameNum = max(nextFrameNum, frame.num + 1)
        finish(.frameCreated(frame))
        return frame
    }

    /// Moves a frame to a new world-space position. No-op if the id is
    /// unknown.
    func moveFrame(id: String, to origin: CGPoint) {
        guard let idx = frames.firstIndex(where: { $0.id == id }) else { return }
        let old = CGPoint(x: frames[idx].x, y: frames[idx].y)
        // Skip the mutation if the position is unchanged — avoids
        // re-dirtying the document on a click-without-drag.
        if old.x == origin.x, old.y == origin.y { return }
        frames[idx].x = origin.x
        frames[idx].y = origin.y
        finish(.frameMoved(id: id, oldOrigin: old))
    }

    /// Resizes a frame. Width/height clamped to ≥ 1 to match the JS
    /// resize handler (which min-clamps at the CSS minimum of the card
    /// chrome). No-op if the id is unknown or the size is unchanged.
    func resizeFrame(id: String, size: CGSize) {
        guard let idx = frames.firstIndex(where: { $0.id == id }) else { return }
        let w = max(1, size.width)
        let h = max(1, size.height)
        let old = CGSize(width: frames[idx].w, height: frames[idx].h)
        if old.width == w, old.height == h { return }
        frames[idx].w = w
        frames[idx].h = h
        finish(.frameResized(id: id, oldSize: old))
    }

    /// Updates a frame's label (the titlebar text). Matches the JS
    /// `frame.label = …` path from the header `<input>` commit.
    func renameFrame(id: String, label: String) {
        guard let idx = frames.firstIndex(where: { $0.id == id }) else { return }
        guard frames[idx].label != label else { return }
        frames[idx].label = label
        finish(.frameRenamed(id: id))
    }

    /// Deletes a frame *and* cascades: removes annotations belonging to
    /// the frame and any links that reference it on either end. Matches
    /// JS `deleteFrame` at index.html ~line 1946.
    ///
    /// The `.frameDeleted` mutation carries the removed annotations and links
    /// so the document's undo can restore them together.
    func deleteFrame(id: String) {
        guard let frame = frames.first(where: { $0.id == id }) else { return }
        let removedAnnotations = annotations.filter { $0.frameId == id }
        let removedLinks       = links.filter { $0.fromId == id || $0.toId == id }
        frames      = frames.filter { $0.id != id }
        annotations = annotations.filter { $0.frameId != id }
        links       = links.filter { $0.fromId != id && $0.toId != id }
        finish(.frameDeleted(frame,
                             annotations: removedAnnotations,
                             links: removedLinks))
    }

    /// Adds a link. Rejects duplicates (same from/to/sides) to match JS
    /// `addLink` which guards against double-drop. Also rejects self-links
    /// (fromId == toId) and links whose endpoints don't exist — both are
    /// user errors the JS layer already prevents.
    @discardableResult
    func createLink(_ link: LinkModel) -> LinkModel? {
        guard link.fromId != link.toId,
              frames.contains(where: { $0.id == link.fromId }),
              frames.contains(where: { $0.id == link.toId }) else { return nil }
        guard !links.contains(where: {
            $0.fromId == link.fromId && $0.toId == link.toId &&
            $0.fromSide == link.fromSide && $0.toSide == link.toSide
        }) else { return nil }
        guard !links.contains(where: { $0.id == link.id }) else { return nil }
        links.append(link)
        finish(.linkCreated(link))
        return link
    }

    /// Sets (or with nil clears) the user-placed bends of a link: the
    /// coordinates of its interior segments, see `LinkOrthogonalMath.manualRoute`.
    func setLinkBends(id: String, bends: [CGFloat]?) {
        guard let index = links.firstIndex(where: { $0.id == id }) else { return }
        let previous = links[index]
        var updated = previous
        if let bends, !bends.isEmpty {
            updated.extras["bends"] = .array(bends.map { .number(Double($0)) })
        } else {
            updated.extras.removeValue(forKey: "bends")
        }
        guard updated != previous else { return }
        links[index] = updated
        finish(.linkBendsChanged(previous: previous))
    }

    /// Frame pictures and comment screenshots, separately: comment
    /// screenshots go to agents as-is and must stay PNG.
    var imageDataURLsByUse: (frames: [String], comments: [String]) {
        var frameURLs: [String] = [], commentURLs: [String] = []
        for frame in frames { if case .string(let s)? = frame.extras["imgUrl"], s.hasPrefix("data:image/") { frameURLs.append(s) } }
        for ann in annotations {
            if case .object(let element)? = ann.extras["element"], case .string(let s)? = element["screenshot"], s.hasPrefix("data:image/") { commentURLs.append(s) }
        }
        return (frameURLs, commentURLs)
    }

    /// Every stored image data URL: frame pictures and comment screenshots.
    var imageDataURLs: [String] {
        var urls: [String] = []
        for frame in frames { if case .string(let s)? = frame.extras["imgUrl"], s.hasPrefix("data:image/") { urls.append(s) } }
        for ann in annotations {
            if case .object(let element)? = ann.extras["element"], case .string(let s)? = element["screenshot"], s.hasPrefix("data:image/") { urls.append(s) }
        }
        return urls
    }

    /// Swaps image data URLs (old → new) in frames and comment screenshots
    /// as one undoable change.
    func replaceImages(_ replacements: [String: String]) {
        guard !replacements.isEmpty else { return }
        let previousFrames = frames, previousAnnotations = annotations
        var changed = false
        for i in frames.indices {
            if case .string(let s)? = frames[i].extras["imgUrl"], let new = replacements[s], new != s {
                frames[i].extras["imgUrl"] = .string(new); changed = true
            }
        }
        for i in annotations.indices {
            if case .object(var element)? = annotations[i].extras["element"],
               case .string(let s)? = element["screenshot"], let new = replacements[s], new != s {
                element["screenshot"] = .string(new)
                annotations[i].extras["element"] = .object(element); changed = true
            }
        }
        guard changed else { return }
        finish(.imagesReplaced(previousFrames: previousFrames, previousAnnotations: previousAnnotations))
    }

    /// Restores frames and comments captured by `.imagesReplaced`.
    func restoreImages(frames oldFrames: [FrameModel], annotations oldAnnotations: [AnnotationModel]) {
        let previousFrames = frames, previousAnnotations = annotations
        frames = oldFrames; annotations = oldAnnotations
        finish(.imagesReplaced(previousFrames: previousFrames, previousAnnotations: previousAnnotations))
    }

    /// Deletes a link. Undo is registered by the document's NSUndoManager.
    func deleteLink(id: String) {
        guard let link = links.first(where: { $0.id == id }) else { return }
        links = links.filter { $0.id != id }
        finish(.linkDeleted(link))
    }

    /// Adds an annotation. Caller supplies the full model; typical
    /// production usage allocates `num` via `allocateAnnotationNum()` and
    /// generates the id once.
    ///
    /// Advances `nextAnnNum` past the incoming annotation's `num` for the
    /// same round-trip reason explained on `createFrame(_:)` — without it
    /// `applyDocState` would reset JS's `annNext` to a value the next pin
    /// drop would collide on.
    @discardableResult
    func createAnnotation(_ annotation: AnnotationModel) -> AnnotationModel? {
        guard !annotations.contains(where: { $0.id == annotation.id }) else { return nil }
        // The frame must exist — an annotation pinned to a vanished frame
        // would immediately fall through `annotations(for:)` queries.
        guard frames.contains(where: { $0.id == annotation.frameId }) else { return nil }
        annotations.append(annotation)
        nextAnnNum = max(nextAnnNum, annotation.num + 1)
        finish(.annotationCreated(annotation))
        return annotation
    }

    /// Updates one or more editable fields on an annotation. Any argument
    /// left nil leaves the corresponding field unchanged. Mirrors the
    /// pin-editor save envelope, which can carry a partial update
    /// (comment-only, color-only, etc.).
    func updateAnnotation(
        id: String,
        comment: String? = nil,
        color: String? = nil,
        edits: [String: String]? = nil
    ) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        let old = annotations[idx]
        if let comment { annotations[idx].comment = comment }
        if let color   { annotations[idx].color   = color   }
        if let edits   { annotations[idx].edits   = edits   }
        guard annotations[idx] != old else { return }
        finish(.annotationUpdated(id: id, previous: old))
    }

    /// Toggles the resolved flag. Mirrors the chip click handler.
    func toggleAnnotationResolved(id: String) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        let was = annotations[idx].resolved
        if annotations[idx].extras["resolvedBy"] != nil {
            var item = annotations[idx]
            item.resolved.toggle()
            item.extras["resolvedBy"] = .string("You")
            item.extras["resolvedAt"] = .string(ISO8601DateFormatter().string(from: Date()))
            restoreCommentStatuses([item]); return
        }
        annotations[idx].resolved.toggle()
        finish(.annotationResolvedToggled(id: id, wasResolved: was))
    }

    /// Explicit status selection is idempotent; repeated menu events cannot flip it back.
    func setAnnotationResolved(id:String,resolved:Bool) {
        guard let current = annotations.first(where:{$0.id == id}), current.resolved != resolved else {return}
        toggleAnnotationResolved(id:id)
    }

    func setAgentCommentStatuses(ids: [String], resolved: Bool, date: Date) {
        let changed = annotations.filter { ids.contains($0.id) && $0.resolved != resolved }
        guard !changed.isEmpty else { return }
        let timestamp = ISO8601DateFormatter().string(from: date)
        let replacements = changed.map { original -> AnnotationModel in
            var item = original
            item.resolved = resolved
            item.extras["resolvedBy"] = .string("MCP agent")
            item.extras["resolvedAt"] = .string(timestamp)
            var history: [JSONValue] = []
            if case .array(let entries) = item.extras["resolutionHistory"] { history = entries }
            history.append(.object(["actor": .string("MCP agent"), "at": .string(timestamp), "resolved": .bool(resolved)]))
            item.extras["resolutionHistory"] = .array(Array(history.suffix(50)))
            return item
        }
        restoreCommentStatuses(replacements)
    }
    func restoreCommentStatuses(_ replacements: [AnnotationModel]) {
        var previous: [AnnotationModel] = []
        for item in replacements {
            guard let index = annotations.firstIndex(where: { $0.id == item.id }), annotations[index] != item else { continue }
            previous.append(annotations[index]); annotations[index] = item
        }
        if !previous.isEmpty { finish(.commentStatusesChanged(previous: previous)) }
    }

    /// Deletes an annotation. Matches JS `deleteAnnotation`.
    func deleteAnnotation(id: String) {
        guard let annotation = annotations.first(where: { $0.id == id }) else { return }
        annotations = annotations.filter { $0.id != id }
        finish(.annotationDeleted(annotation))
    }

    /// Replaces the viewport (pan/zoom). Fires observers every time
    /// because link bezier paths and the dot-grid phase both depend on
    /// the transform; one skipped frame during a pan is visible as a
    /// lagged arrow.
    func setViewport(_ viewport: ViewportModel) {
        guard self.viewport != viewport else { return }
        self.viewport = viewport
        finish(.viewportChanged(viewport))
    }

    // MARK: - ID / number allocation helpers
    //
    // These match the JS shapes so a flipped-authority document round-
    // trips byte-for-byte through a reload. Not thread-safe (main actor
    // only) and intentionally simple — Phase 6d's UI caller just needs a
    // consistent allocator, not a UUID.

    /// Returns the next frame number and bumps the counter. Matches JS
    /// `f.num = nextNum++;`.
    func allocateFrameNum() -> Int {
        let n = nextFrameNum
        nextFrameNum += 1
        return n
    }

    /// Returns the next annotation number and bumps the counter. Matches
    /// JS `a.num = annNext++;`.
    func allocateAnnotationNum() -> Int {
        let n = nextAnnNum
        nextAnnNum += 1
        return n
    }

    /// Renumbers frames and annotations to `1..n` based on current array
    /// order, and resets the counters accordingly. Mirrors JS
    /// `annResetCounters` (index.html ~line 2055). Not undoable — matches
    /// JS behavior. Silent if nothing changes (i.e. already sequential).
    func resetCounters() {
        let targetFrameNum = frames.count + 1
        let targetAnnNum   = annotations.count + 1
        var dirty = nextFrameNum != targetFrameNum || nextAnnNum != targetAnnNum
        for (i, frame) in frames.enumerated() where frame.num != i + 1 {
            frames[i].num = i + 1
            dirty = true
        }
        for (i, ann) in annotations.enumerated() where ann.num != i + 1 {
            annotations[i].num = i + 1
            dirty = true
        }
        nextFrameNum = targetFrameNum
        nextAnnNum   = targetAnnNum
        guard dirty else { return }
        finish(.countersReset)
    }

    // MARK: - Internal

    /// Fires delegate + observers + bumps the version counter. Called at
    /// the tail of every mutation method — centralized so a future
    /// change (e.g. coalescing mutations within a run-loop turn) has one
    /// place to edit.
    /// The mutation being broadcast, readable by observers for the
    /// duration of their callback (nil outside `finish`, including the
    /// synchronous first call from `observe(_:)`). Lets a heavy observer
    /// take a cheap path for `.viewportChanged`, which fires on every
    /// scroll-wheel tick, without changing the `observe` signature.
    private(set) var mutationInFlight: WorkspaceMutation?

    private func finish(_ mutation: WorkspaceMutation) {
        version &+= 1
        mutationInFlight = mutation
        defer { mutationInFlight = nil }
        delegate?.workspaceStore(self, didApplyMutation: mutation)
        for cb in callbacks.values { cb() }
    }
}

// MARK: - Delegate protocol

/// Conformed to by the workspace owner (`WebFramesDocument`) so mutations
/// on the store can be persisted back into the document payload and the
/// document marked dirty. The delegate callback is always called on the
/// main actor.
@MainActor
protocol WorkspaceStoreDelegate: AnyObject {
    func workspaceStore(_ store: WorkspaceStore,
                        didApplyMutation mutation: WorkspaceMutation)
}

// MARK: - WorkspaceMutation

/// Discriminated union describing a single store mutation. Delegate
/// implementations may switch on it to apply targeted updates (e.g. push
/// just the changed link to `LinkLayerView`) rather than serializing the
/// whole payload — though serializing is always a valid fallback.
enum WorkspaceMutation {
    case projectMapChanged
    case commentStatusesChanged(previous: [AnnotationModel])
    case framesReordered(previousIDs: [String])
    case frameCreated(FrameModel)
    case frameMoved(id: String, oldOrigin: CGPoint)
    case frameResized(id: String, oldSize: CGSize)
    case frameRenamed(id: String)
    case frameDeleted(FrameModel, annotations: [AnnotationModel], links: [LinkModel])
    case linkCreated(LinkModel)
    case linkDeleted(LinkModel)
    case linkBendsChanged(previous: LinkModel)
    case imagesReplaced(previousFrames: [FrameModel], previousAnnotations: [AnnotationModel])
    case annotationCreated(AnnotationModel)
    case annotationUpdated(id: String, previous: AnnotationModel)
    case annotationResolvedToggled(id: String, wasResolved: Bool)
    case annotationDeleted(AnnotationModel)
    case viewportChanged(ViewportModel)
    /// Batch renumbering — frames and annotations are reassigned `num`
    /// based on array position, and the counters reset to `count + 1`.
    /// Not undoable (matches JS `annResetCounters`, which had no undo hook).
    case countersReset
}
