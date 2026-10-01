//
//  WebFramesDocumentTests.swift
//  webframesTests
//
//  Covers the in-memory contract of `WebFramesDocument`:
//   • init assigns a sandboxed fileURL + fileType
//   • setName trims, falls back to "Untitled", and marks dirty only on
//     a real change
//   • data(ofType:) ↔ read(from:) round-trip preserves the full payload
//   • applyCanvasState merges bridge updates without losing the native-
//     owned `name` field, and de-duplicates identical messages so the
//     canvas can't mark a pristine doc dirty on reload
//
//  The class is @MainActor (app target has
//  SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor); tests are annotated to
//  match so we can poke instance state synchronously. We never write to
//  disk here — the doc's fileURL is assigned in init and we only exercise
//  data encoding/decoding via Data in memory.
//

import AppKit
import Foundation
import Testing
@testable import Web_Frames

// MARK: - Init / configuration

@MainActor
@Suite("WebFramesDocument · init")
struct WebFramesDocumentInitTests {

    @Test("init assigns a fileURL under the projects directory")
    func initAssignsFileURL() {
        let doc = WebFramesDocument()
        // NSDocument.fileURL is nominally `URL?`, but the compiler sees
        // that our init unconditionally assigns it and narrows the type
        // accordingly — so `#require` on it would be flagged redundant.
        let url = doc.fileURL
        #expect(url?.pathExtension == WebFramesDocument.fileExtension)
        let parent = url?.deletingLastPathComponent().standardizedFileURL
        #expect(parent == ProjectStorage.projectsDirectory.standardizedFileURL)
    }

    @Test("init assigns the .webframes UTI as fileType")
    func initAssignsFileType() {
        let doc = WebFramesDocument()
        #expect(doc.fileType == WebFramesDocument.fileTypeIdentifier)
    }

    @Test("payload starts equal to .empty")
    func initPayloadEmpty() {
        let doc = makeTestDocument()
        #expect(doc.payload == DocumentPayload.empty)
    }

    @Test("autosavesInPlace is true (auto-save is the save mechanism)")
    func autosavesInPlaceTrue() {
        #expect(WebFramesDocument.autosavesInPlace == true)
    }

    @Test("undo manager is enabled — Phase 6d owns undo via NSUndoManager")
    func undoManagerEnabled() {
        // Phase 6d moved undo ownership from the canvas JS `undoStack`
        // to `NSUndoManager` driven by `WorkspaceStoreDelegate`. The JS
        // Cmd+Z keydown is a no-op when `NativeAPI.available`; a native
        // `NSEvent` monitor on `DocumentWindowController` feeds
        // Cmd+Z / Shift+Cmd+Z into `undoManager.undo()` / `redo()`.
        let doc = makeTestDocument()
        #expect(doc.hasUndoManager == true)
        #expect(doc.undoManager != nil)
    }

    @Test("fresh doc is not marked edited")
    func initNotEdited() {
        let doc = makeTestDocument()
        #expect(doc.isDocumentEdited == false)
    }

    @Test("managed project is never an AppKit draft")
    func managedProjectIsNotDraft() throws {
        let doc = makeTestDocument()
        #expect(doc.isDraft == false)

        let data = try doc.data(ofType: WebFramesDocument.fileTypeIdentifier)
        try doc.read(from: data, ofType: WebFramesDocument.fileTypeIdentifier)
        #expect(doc.isDraft == false)
    }
}

@MainActor
@Suite("Application lifecycle")
struct ApplicationLifecycleTests {
    @Test("session reopen is rejected before a document is created")
    func sessionReopenIsRejected() {
        let controller = WebFramesDocumentController()
        var completionWasCalled = false
        controller.reopenDocument(
            for: nil,
            withContentsOf: URL(fileURLWithPath: "/tmp/previous-session.webframes"),
            display: true
        ) { document, wasAlreadyOpen, error in
            completionWasCalled = true
            #expect(document == nil)
            #expect(wasAlreadyOpen == false)
            #expect(error == nil)
        }
        #expect(completionWasCalled)
    }
}

// MARK: - setName / displayName

@MainActor
@Suite("WebFramesDocument · name")
struct WebFramesDocumentNameTests {

    @Test("setName trims whitespace")
    func trimsWhitespace() {
        let doc = makeTestDocument()
        doc.setName("  Design Explorations  ")
        #expect(doc.payload.name == "Design Explorations")
    }

    @Test("empty / whitespace-only name becomes 'Untitled'")
    func emptyBecomesUntitled() {
        let doc = makeTestDocument()
        doc.setName("   ")
        #expect(doc.payload.name == "Untitled")
    }

    @Test("changing the name marks the doc dirty")
    func setNameMarksDirty() {
        let doc = makeTestDocument()
        #expect(doc.isDocumentEdited == false)
        doc.setName("Project A")
        #expect(doc.isDocumentEdited == true)
    }

    @Test("setting the same name again is a no-op for change tracking")
    func sameNameNoop() {
        let doc = makeTestDocument()
        doc.setName("Same")
        doc.updateChangeCount(.changeCleared)
        #expect(doc.isDocumentEdited == false)

        doc.setName("Same")
        #expect(doc.isDocumentEdited == false,
                "Re-applying the current name must not bump changeCount")
    }

    @Test("displayName falls back to 'Untitled' when the payload name is empty")
    func displayNameFallback() {
        let doc = makeTestDocument()
        // Route through setName so we exercise the real code path rather
        // than poking the private(set) payload directly.
        doc.setName("")
        #expect(doc.displayName == "Untitled")
    }

    @Test("displayName reflects the current payload name")
    func displayNameLive() {
        let doc = makeTestDocument()
        doc.setName("Flow B")
        #expect(doc.displayName == "Flow B")
    }
}

// MARK: - Codable round-trip

@MainActor
@Suite("WebFramesDocument · data(ofType:) ↔ read(from:)")
struct WebFramesDocumentCodableTests {

    @Test("encode → decode preserves the full payload")
    func roundTripPreservesPayload() throws {
        let source = makeTestDocument()
        source.setName("Round-Trip")
        // Smuggle some bridge-shaped content through applyCanvasState so
        // we're not only testing the name field.
        source.applyCanvasState([
            "version": 1,
            "frames": [
                ["id": "f1", "url": "https://example.com", "x": 10.0, "y": 20.0],
            ],
            "annotations": [],
            "links": [],
            "canvas": ["scale": 1.25, "px": 50.0, "py": 75.0],
            "nextNum": 2,
            "annNext": 1,
        ])

        let data = try source.data(ofType: WebFramesDocument.fileTypeIdentifier)

        let sink = makeTestDocument()
        try sink.read(from: data, ofType: WebFramesDocument.fileTypeIdentifier)

        // Saving writes the current format version; everything else is kept.
        var expected = source.payload
        expected.version = DocumentPayload.currentVersion
        #expect(sink.payload == expected)
    }

    @Test("read rejects corrupt JSON with NSFileReadCorruptFileError")
    func readRejectsCorruptData() {
        let doc = makeTestDocument()
        let garbage = Data("not { valid } json".utf8)

        // `#expect(throws:)` returns the thrown error, so we can both assert
        // that the call threw *and* inspect the error shape in one pass.
        // AppKit keys off this domain+code pair to surface a user-readable
        // "this file is corrupt" alert instead of a raw decoding stacktrace.
        let error = #expect(throws: NSError.self) {
            try doc.read(from: garbage, ofType: WebFramesDocument.fileTypeIdentifier)
        }
        #expect(error?.domain == NSCocoaErrorDomain)
        #expect(error?.code == NSFileReadCorruptFileError)
    }

    @Test("read replaces the in-memory payload")
    func readReplacesPayload() throws {
        let source = makeTestDocument()
        source.setName("From Disk")
        let data = try source.data(ofType: WebFramesDocument.fileTypeIdentifier)

        let sink = makeTestDocument()
        sink.setName("Old Name")
        try sink.read(from: data, ofType: WebFramesDocument.fileTypeIdentifier)

        #expect(sink.payload.name == "From Disk")
    }
}

// MARK: - applyCanvasState (JS bridge)

@MainActor
@Suite("WebFramesDocument · applyCanvasState")
struct WebFramesDocumentBridgeTests {

    @Test("applyCanvasState reflects incoming frames / counters")
    func appliesIncomingState() {
        let doc = makeTestDocument()
        doc.applyCanvasState([
            "frames": [["id": "a"]],
            "nextNum": 7,
            "annNext": 3,
        ])
        #expect(doc.payload.frames.count == 1)
        #expect(doc.payload.nextNum == 7)
        #expect(doc.payload.annNext == 3)
    }

    @Test("applyCanvasState preserves the native-owned name")
    func preservesNativeName() {
        let doc = makeTestDocument()
        doc.setName("Keep Me")
        doc.applyCanvasState([
            "frames": [["id": "a"]],
            "name": "Overwritten From Canvas",  // should be ignored
        ])
        #expect(doc.payload.name == "Keep Me",
                "Canvas must not be able to rename the project via state sync")
    }

    @Test("first applyCanvasState call marks the doc dirty")
    func firstApplyMarksDirty() {
        let doc = makeTestDocument()
        #expect(doc.isDocumentEdited == false)
        doc.applyCanvasState([
            "frames": [["id": "a"]],
        ])
        #expect(doc.isDocumentEdited == true)
    }

    @Test("identical state back-to-back is a no-op for change tracking")
    func identicalStateNoop() {
        let doc = makeTestDocument()
        let dict: [String: Any] = [
            "frames": [["id": "a"]],
            "nextNum": 2,
        ]
        doc.applyCanvasState(dict)

        // Simulate a save having happened.
        doc.updateChangeCount(.changeCleared)
        #expect(doc.isDocumentEdited == false)

        doc.applyCanvasState(dict)
        #expect(doc.isDocumentEdited == false,
                "Re-sending the same state must not dirty a clean doc — otherwise re-loading the canvas would spam auto-saves")
    }

    @Test("payloadAsDictionary exposes the shape the JS bridge consumes")
    func payloadAsDictionaryShape() {
        let doc = makeTestDocument()
        doc.setName("DictCheck")
        let dict = doc.payloadAsDictionary
        #expect(dict["name"] as? String == "DictCheck")
        #expect(dict["version"] as? Int == DocumentPayload.currentVersion)
        #expect((dict["frames"] as? [Any])?.isEmpty == true)
        #expect((dict["annotations"] as? [Any])?.isEmpty == true)
        #expect((dict["links"] as? [Any])?.isEmpty == true)
    }
}

// MARK: - NSUndoManager integration (Phase 6d)
//
// Phase 6d moved undo ownership from the JS `undoStack` in index.html to
// `NSUndoManager` driven by `WorkspaceStoreDelegate.workspaceStore(_:
// didApplyMutation:)`. Every undoable mutation on the store registers an
// inverse closure with the document's undo manager; non-undoable mutations
// (frame move/resize/rename, viewport pan-zoom) deliberately skip the
// registration so the undo stack only contains the operations the user
// would recognise — matching the JS `undoStack` policy this replaces.
//
// These tests exercise the full round-trip synchronously on the main actor:
//   forward mutation → undo() → inverse applied → redo() → forward re-applied
// relying on NSUndoManager's auto-promotion of nested registerUndo calls
// during undo() into redo operations.
//
// Fixture helpers populate the workspace directly (bypassing JS) and then
// clear the undo manager so the mutation under test starts from a pristine
// stack.

@MainActor
@Suite("WebFramesDocument · NSUndoManager")
struct WebFramesDocumentUndoTests {

    /// Builds a frame via the workspace (so the delegate fires and the
    /// serialized payload updates) and then clears the undo ops that the
    /// creation triggered — callers want the frame present but the undo
    /// stack empty when the scenario begins.
    private func makeFrame(_ doc: WebFramesDocument,
                           id: String = "f1",
                           num: Int = 1) -> FrameModel {
        let frame = FrameModel(
            id: id, url: "https://example.com", label: "Test",
            x: 0, y: 0, w: 300, h: 200, num: num,
            isImage: false, filePath: nil
        )
        doc.workspace.createFrame(frame)
        doc.undoManager?.removeAllActions()
        return frame
    }

    /// Adds an annotation to the workspace. Mirrors the fields the JS side
    /// populates for a pin dropped in annotation mode.
    @discardableResult
    private func makeAnnotation(_ doc: WebFramesDocument,
                                id: String = "a1",
                                frameId: String = "f1",
                                comment: String = "",
                                color: String = "blue",
                                resolved: Bool = false,
                                edits: [String: String] = [:]) -> AnnotationModel {
        let ann = AnnotationModel(
            id: id, num: 1, frameId: frameId,
            xPct: 0.5, yPct: 0.5,
            color: color, comment: comment, resolved: resolved,
            edits: edits, frameUrl: nil, frameLabel: nil
        )
        doc.workspace.createAnnotation(ann)
        return ann
    }

    @Test("undo of annotation delete restores it")
    func undoDeleteAnnotationRestoresIt() throws {
        let doc = makeTestDocument()
        _ = makeFrame(doc)
        let ann = makeAnnotation(doc)
        doc.undoManager?.removeAllActions()

        doc.workspace.deleteAnnotation(id: ann.id)
        #expect(doc.workspace.annotations.isEmpty)
        #expect(doc.undoManager?.canUndo == true)

        doc.undoManager?.undo()
        #expect(doc.workspace.annotations.contains(ann))
        // Nested registerUndo inside the inverse closure is auto-promoted
        // to a redo op by NSUndoManager — without this invariant the redo
        // arrow in the Edit menu would stay disabled after every undo.
        #expect(doc.undoManager?.canRedo == true)
    }

    @Test("redo after undo of annotation delete removes it again")
    func redoAfterUndoDeletesAnnotation() throws {
        let doc = makeTestDocument()
        _ = makeFrame(doc)
        let ann = makeAnnotation(doc)
        doc.undoManager?.removeAllActions()

        doc.workspace.deleteAnnotation(id: ann.id)
        doc.undoManager?.undo()
        doc.undoManager?.redo()
        #expect(doc.workspace.annotations.isEmpty)
    }

    @Test("toggle resolved is self-inverse under undo/redo")
    func undoToggleResolvedFlipsBack() throws {
        let doc = makeTestDocument()
        _ = makeFrame(doc)
        let ann = makeAnnotation(doc, resolved: false)
        doc.undoManager?.removeAllActions()

        doc.workspace.toggleAnnotationResolved(id: ann.id)
        #expect(doc.workspace.annotations.first?.resolved == true)

        doc.undoManager?.undo()
        #expect(doc.workspace.annotations.first?.resolved == false)

        doc.undoManager?.redo()
        #expect(doc.workspace.annotations.first?.resolved == true)
    }

    @Test("undo of annotation update restores previous comment/color/edits")
    func undoUpdateAnnotationRestoresPrevious() throws {
        let doc = makeTestDocument()
        _ = makeFrame(doc)
        let original = makeAnnotation(doc, comment: "initial", color: "blue")
        doc.undoManager?.removeAllActions()

        doc.workspace.updateAnnotation(
            id: original.id,
            comment: "edited",
            color: "red",
            edits: ["k": "v"]
        )
        #expect(doc.workspace.annotations.first?.comment == "edited")
        #expect(doc.workspace.annotations.first?.color == "red")

        doc.undoManager?.undo()
        let restored = try #require(doc.workspace.annotations.first)
        #expect(restored.comment == "initial")
        #expect(restored.color == "blue")
        #expect(restored.edits.isEmpty)
    }

    @Test("undo of frame delete restores frame, annotations, and links")
    func undoDeleteFrameCascadeRestoresDependents() throws {
        let doc = makeTestDocument()
        let f1 = makeFrame(doc, id: "f1", num: 1)
        // Second frame added via the store directly; we don't care about
        // the extra undo op since we clear the stack below.
        let f2 = FrameModel(
            id: "f2", url: "https://example.com", label: "Second",
            x: 400, y: 0, w: 300, h: 200, num: 2,
            isImage: false, filePath: nil
        )
        doc.workspace.createFrame(f2)
        let ann = makeAnnotation(doc, id: "a1", frameId: f1.id)
        let link = LinkModel(
            id: "l1",
            fromId: f1.id, fromSide: .right,
            toId: f2.id, toSide: .left
        )
        doc.workspace.createLink(link)
        doc.undoManager?.removeAllActions()

        doc.workspace.deleteFrame(id: f1.id)
        #expect(doc.workspace.frames.count == 1)
        #expect(doc.workspace.annotations.isEmpty)
        #expect(doc.workspace.links.isEmpty)

        doc.undoManager?.undo()
        #expect(doc.workspace.frames.count == 2)
        #expect(doc.workspace.annotations.contains(ann))
        #expect(doc.workspace.links.contains(link))
    }

    @Test("undo of link delete restores the link")
    func undoDeleteLinkRestoresIt() throws {
        let doc = makeTestDocument()
        let f1 = makeFrame(doc, id: "f1", num: 1)
        let f2 = FrameModel(
            id: "f2", url: "https://example.com", label: "Second",
            x: 400, y: 0, w: 300, h: 200, num: 2,
            isImage: false, filePath: nil
        )
        doc.workspace.createFrame(f2)
        let link = LinkModel(
            id: "l1",
            fromId: f1.id, fromSide: .right,
            toId: f2.id, toSide: .left
        )
        doc.workspace.createLink(link)
        doc.undoManager?.removeAllActions()

        doc.workspace.deleteLink(id: link.id)
        #expect(doc.workspace.links.isEmpty)

        doc.undoManager?.undo()
        #expect(doc.workspace.links.contains(link))
    }

    @Test("applyCanvasState does NOT pollute the undo manager")
    func applyDoesNotRegisterUndo() throws {
        // Critical invariant: round-trips from the JS canvas land via
        // `applyCanvasState` → `WorkspaceStore.apply(_:)`, which
        // deliberately skips the delegate. Were it to fire, every
        // `doc-state-changed` would flood the undo stack with ops the user
        // never performed directly.
        let doc = makeTestDocument()
        doc.undoManager?.removeAllActions()
        doc.applyCanvasState([
            "version": 1,
            "frames": [
                ["id": "f1", "url": "https://e.com",
                 "x": 0.0, "y": 0.0, "w": 300.0, "h": 200.0, "num": 1],
            ],
            "annotations": [],
            "links": [],
            "canvas": ["scale": 1.0, "px": 0.0, "py": 0.0],
            "nextNum": 2,
            "annNext": 1,
        ])
        #expect(doc.workspace.frames.count == 1,
                "sanity: apply populated the typed mirror")
        #expect(doc.undoManager?.canUndo == false,
                "apply(_:) must not feed the undo manager — otherwise canvas reloads would overwrite user-facing undo history")
    }

    @Test("delete annotation sets undoActionName to 'Delete Comment'")
    func deletePinSetsActionName() throws {
        let doc = makeTestDocument()
        _ = makeFrame(doc)
        let ann = makeAnnotation(doc)
        doc.undoManager?.removeAllActions()

        doc.workspace.deleteAnnotation(id: ann.id)
        // The action name is what the Edit menu shows as "Undo Delete Comment".
        // It's set in `registerUndo(for:undoManager:)` alongside the
        // inverse closure; without it the menu item would read just "Undo".
        #expect(doc.undoManager?.undoActionName == "Delete Comment")
    }

    @Test("frame delete sets undoActionName to 'Delete Frame'")
    func deleteFrameSetsActionName() throws {
        let doc = makeTestDocument()
        let f = makeFrame(doc)
        doc.workspace.deleteFrame(id: f.id)
        #expect(doc.undoManager?.undoActionName == "Delete Frame")
    }

    /// Regression test for the data-loss bug that would land if
    /// `AnnotationModel` didn't preserve unknown JS-owned fields.
    ///
    /// Every Swift-side mutation re-serializes the whole annotations
    /// array via `store.serialize()` → `DocumentPayload.annotations`.
    /// If the typed mirror dropped fields it didn't enumerate (e.g. the
    /// `element` DOM snapshot, `initialScrollX/Y`), then deleting ONE
    /// annotation would strip those fields from every OTHER annotation
    /// in the same payload — breaking pin-editor label / screenshot /
    /// scroll-follow on reopen. The `extras` catchall on
    /// `AnnotationModel` exists specifically to prevent that.
    @Test("sibling annotation's JS-only fields survive Swift-side delete")
    func siblingExtrasSurviveDelete() throws {
        let doc = makeTestDocument()
        _ = makeFrame(doc)

        // Pre-load the document with two annotations, one of which
        // carries JS-only `element` + scroll fields. Use applyCanvasState
        // to match the real loading path (`read(from:)` → `apply`).
        let preload: [String: Any] = [
            "version": 1,
            "name": "T",
            "frames": [[
                "id": "f1", "url": "https://example.com", "label": "F",
                "x": 0, "y": 0, "w": 300, "h": 200, "num": 1,
            ]],
            "annotations": [
                [
                    "id": "a1", "frameId": "f1", "num": 1,
                    "xPct": 0.1, "yPct": 0.1,
                    "color": "blue", "comment": "first",
                    "resolved": false,
                    // JS-only fields:
                    "element": [
                        "tagName": "div",
                        "componentName": "Header",
                        "screenshot": "data:image/png;base64,abc",
                    ],
                    "initialScrollX": 0, "initialScrollY": 0,
                ],
                [
                    "id": "a2", "frameId": "f1", "num": 2,
                    "xPct": 0.5, "yPct": 0.5,
                    "color": "amber", "comment": "second",
                    "resolved": false,
                    "element": [
                        "tagName": "button",
                        "componentName": "SubmitBtn",
                        "screenshot": "data:image/png;base64,xyz",
                        "computedStyles": ["color": "rgb(0,0,0)"],
                    ],
                    "initialScrollX": 120, "initialScrollY": 40,
                ],
            ],
            "links": [] as [Any],
            "canvas": ["scale": 1, "px": 0, "py": 0],
            "nextNum": 2, "annNext": 3,
        ]
        doc.applyCanvasState(preload)
        doc.undoManager?.removeAllActions()

        // Mutate — delete one annotation through the Swift workspace.
        // This re-serializes the typed mirror back into payload.
        doc.workspace.deleteAnnotation(id: "a1")

        // The surviving annotation's JS-only fields MUST be intact in
        // the resulting payload. Reach into the serialized payload (not
        // the typed mirror, which is where `extras` lives) so we verify
        // the contract the canvas JS sees on its next `doc-load-state`.
        let survivor = try #require(
            doc.workspace.annotations.first(where: { $0.id == "a2" })
        )
        #expect(survivor.extras["element"] != nil,
                "element snapshot must survive sibling delete")
        if case .object(let el)? = survivor.extras["element"] {
            #expect(el["componentName"] == .string("SubmitBtn"))
            #expect(el["screenshot"] == .string("data:image/png;base64,xyz"))
        } else {
            Issue.record("element was not preserved as an object")
        }
        #expect(survivor.extras["initialScrollX"] == .number(120))
        #expect(survivor.extras["initialScrollY"] == .number(40))
    }

    @Test("non-undoable mutations do not register undo")
    func nonUndoableMutations() throws {
        // Resize, rename and viewport remain direct edits. Frame moves now
        // participate in undo, including a single group-drag transaction.
        let doc = makeTestDocument()
        let f = makeFrame(doc)
        doc.undoManager?.removeAllActions()

        doc.workspace.resizeFrame(id: f.id, size: CGSize(width: 500, height: 400))
        doc.workspace.renameFrame(id: f.id, label: "Renamed")
        doc.workspace.setViewport(
            ViewportModel(scale: 2.0, panX: 10, panY: 20)
        )

        #expect(doc.undoManager?.canUndo == false,
                "Resize/rename/viewport must not fill the undo stack")
    }
}

// MARK: - NativeBridge envelope dispatch
//
// Phase 6d flip: pin-editor save / cancel of new pins / color swatch all
// route through a new `NativeAPI` JS surface that posts one of:
//
//   { type:'ann-create', ann }            → workspace.createAnnotation
//   { type:'ann-update', id, ...partial } → workspace.updateAnnotation
//   { type:'ann-delete', id }             → workspace.deleteAnnotation
//
// The bridge's `handleCanvasMessage` dispatches on `type`. These tests
// drive that dispatch directly (no WKWebView) and assert that the bound
// document's typed `WorkspaceStore` reflects the mutation — catching
// regressions in the envelope parser (missing id, malformed `ann`,
// `edits` coercion from NSNumber values, etc.).
@MainActor
@Suite("NativeBridge · annotation envelopes")
struct BridgeAnnotationEnvelopeTests {

    /// Build a bridge bound to a fresh document that already has one
    /// frame (`f1`). Annotation envelopes require a matching frame to
    /// land in the store — otherwise `createAnnotation` silently drops
    /// per `WorkspaceStore` policy.
    private func makeBridge() -> (NativeBridge, WebFramesDocument) {
        let doc = makeTestDocument()
        let frame = FrameModel(
            id: "f1", url: "https://example.com", label: "F",
            x: 0, y: 0, w: 300, h: 200, num: 1,
            isImage: false, filePath: nil
        )
        doc.workspace.createFrame(frame)
        let bridge = NativeBridge()
        bridge.document = doc
        return (bridge, doc)
    }

    @Test("ann-create lands the full annotation in the workspace")
    func annCreateCreatesAnnotation() throws {
        let (bridge, doc) = makeBridge()

        bridge.handleCanvasMessage([
            "type": "ann-create",
            "ann": [
                "id": "a1", "frameId": "f1", "num": 1,
                "xPct": 0.25, "yPct": 0.75,
                "color": "blue", "comment": "hello",
                "resolved": false,
                // JS-only preservation check — these must flow through
                // into `AnnotationModel.extras` via the JSONValue parser.
                "element": [
                    "tagName": "button",
                    "componentName": "SubmitBtn",
                ],
                "initialScrollX": 0, "initialScrollY": 40,
            ] as [String: Any],
        ] as [String: Any])

        let ann = try #require(doc.workspace.annotations.first)
        #expect(ann.id == "a1")
        #expect(ann.frameId == "f1")
        #expect(ann.color == "blue")
        #expect(ann.comment == "hello")
        // Catchall preservation — regression test companion to
        // `siblingExtrasSurviveDelete`. A save of a brand-new pin in
        // annotation mode is the exact path that carries element / scroll
        // fields into Swift for the first time; if extras weren't plumbed
        // through the bridge, reopening the editor would show no screenshot.
        #expect(ann.extras["element"] != nil)
        #expect(ann.extras["initialScrollY"] == .number(40))
    }

    @Test("ann-create with malformed payload does not mutate workspace")
    func annCreateRejectsMalformedPayload() {
        let (bridge, doc) = makeBridge()

        // Missing `ann` — dispatcher logs and returns.
        bridge.handleCanvasMessage([
            "type": "ann-create",
        ] as [String: Any])

        #expect(doc.workspace.annotations.isEmpty,
                "malformed ann-create must not leak a zombie annotation")
    }

    @Test("ann-update applies partial fields; omitted fields stay unchanged")
    func annUpdateAppliesPartial() throws {
        let (bridge, doc) = makeBridge()
        // Seed an annotation so the update has something to mutate.
        doc.workspace.createAnnotation(AnnotationModel(
            id: "a1", num: 1, frameId: "f1",
            xPct: 0.5, yPct: 0.5,
            color: "blue", comment: "initial", resolved: false,
            edits: [:], frameUrl: nil, frameLabel: nil
        ))

        // Color-only swatch click — typical live-update envelope.
        bridge.handleCanvasMessage([
            "type": "ann-update",
            "id": "a1",
            "color": "red",
        ] as [String: Any])

        let afterColor = try #require(doc.workspace.annotations.first)
        #expect(afterColor.color == "red",
                "color must update from the partial envelope")
        #expect(afterColor.comment == "initial",
                "omitted fields must survive the partial update")

        // Save envelope — comment + color + edits together.
        bridge.handleCanvasMessage([
            "type": "ann-update",
            "id": "a1",
            "comment": "edited",
            "color": "amber",
            "edits": ["href": "https://new.example"] as [String: Any],
        ] as [String: Any])

        let afterSave = try #require(doc.workspace.annotations.first)
        #expect(afterSave.comment == "edited")
        #expect(afterSave.color == "amber")
        #expect(afterSave.edits["href"] == "https://new.example")
    }

    @Test("ann-update coerces numeric edits values to strings")
    func annUpdateCoercesNumericEdits() throws {
        // `edits` on the JS side is `{ [key]: string }` by convention, but
        // WKWebView coerces whole-number values arriving as NSNumbers when
        // the JS source accidentally uses non-string values. The dispatcher
        // stringifies NSNumber entries instead of dropping them so the save
        // keeps what the user typed. Guard against regressions to silent
        // drop-on-type-mismatch.
        let (bridge, doc) = makeBridge()
        doc.workspace.createAnnotation(AnnotationModel(
            id: "a1", num: 1, frameId: "f1",
            xPct: 0.5, yPct: 0.5,
            color: "blue", comment: "", resolved: false,
            edits: [:], frameUrl: nil, frameLabel: nil
        ))

        bridge.handleCanvasMessage([
            "type": "ann-update",
            "id": "a1",
            "edits": ["count": NSNumber(value: 42)] as [String: Any],
        ] as [String: Any])

        let ann = try #require(doc.workspace.annotations.first)
        #expect(ann.edits["count"] == "42")
    }

    @Test("ann-update without id is ignored")
    func annUpdateWithoutIdIsIgnored() throws {
        let (bridge, doc) = makeBridge()
        doc.workspace.createAnnotation(AnnotationModel(
            id: "a1", num: 1, frameId: "f1",
            xPct: 0.5, yPct: 0.5,
            color: "blue", comment: "initial", resolved: false,
            edits: [:], frameUrl: nil, frameLabel: nil
        ))

        bridge.handleCanvasMessage([
            "type": "ann-update",
            "comment": "noop",
        ] as [String: Any])

        let ann = try #require(doc.workspace.annotations.first)
        #expect(ann.comment == "initial", "missing-id update must be a no-op")
    }

    @Test("ann-delete removes the annotation and registers undo")
    func annDeleteRemovesAndRegistersUndo() throws {
        let (bridge, doc) = makeBridge()
        doc.workspace.createAnnotation(AnnotationModel(
            id: "a1", num: 1, frameId: "f1",
            xPct: 0.5, yPct: 0.5,
            color: "blue", comment: "", resolved: false,
            edits: [:], frameUrl: nil, frameLabel: nil
        ))
        doc.undoManager?.removeAllActions()

        bridge.handleCanvasMessage([
            "type": "ann-delete",
            "id": "a1",
        ] as [String: Any])

        #expect(doc.workspace.annotations.isEmpty)
        // Bridge-driven deletes must follow the same undo contract as
        // panel/pin-editor deletes — the store registers it in
        // `deleteAnnotation(id:)` regardless of caller.
        #expect(doc.undoManager?.canUndo == true)
        #expect(doc.undoManager?.undoActionName == "Delete Comment")
    }

    @Test("ann-delete without id is ignored")
    func annDeleteWithoutIdIsIgnored() {
        let (bridge, doc) = makeBridge()
        doc.workspace.createAnnotation(AnnotationModel(
            id: "a1", num: 1, frameId: "f1",
            xPct: 0.5, yPct: 0.5,
            color: "blue", comment: "", resolved: false,
            edits: [:], frameUrl: nil, frameLabel: nil
        ))

        bridge.handleCanvasMessage([
            "type": "ann-delete",
        ] as [String: Any])

        #expect(doc.workspace.annotations.count == 1,
                "missing-id delete must not drop the annotation")
    }
}

// MARK: - NativeBridge link envelope dispatch
//
// Companion to `BridgeAnnotationEnvelopeTests`. Phase 6d flip #2: the JS
// `addLink` / `deleteLink` paths route through `NativeAPI.createLink` /
// `deleteLink`, which arrive here as `link-create` / `link-delete`
// envelopes and hit `WorkspaceStore.createLink` / `deleteLink`. Validation
// (self-link, duplicate endpoints, missing frame) lives in the store —
// these tests make sure each rejection branch is preserved by the
// envelope parser and that the JS-side caller can trust the store to
// enforce it.
@MainActor
@Suite("NativeBridge · link envelopes")
struct BridgeLinkEnvelopeTests {

    /// Build a bridge bound to a doc with two frames (`f1`, `f2`) so
    /// valid link endpoints exist. `createFrame` undo entries are cleared
    /// so tests that assert `undoActionName == "Delete Link"` aren't
    /// confused by a stale "Add Frame" label sitting at the top.
    private func makeBridge() -> (NativeBridge, WebFramesDocument) {
        let doc = makeTestDocument()
        doc.workspace.createFrame(FrameModel(
            id: "f1", url: "https://example.com", label: "F1",
            x: 0, y: 0, w: 300, h: 200, num: 1,
            isImage: false, filePath: nil
        ))
        doc.workspace.createFrame(FrameModel(
            id: "f2", url: "https://example.com", label: "F2",
            x: 400, y: 0, w: 300, h: 200, num: 2,
            isImage: false, filePath: nil
        ))
        doc.undoManager?.removeAllActions()
        let bridge = NativeBridge()
        bridge.document = doc
        return (bridge, doc)
    }

    @Test("link-create lands a valid link in the workspace")
    func linkCreateAddsLink() throws {
        let (bridge, doc) = makeBridge()

        bridge.handleCanvasMessage([
            "type": "link-create",
            "link": [
                "id": "l1",
                "fromId": "f1", "fromSide": "right",
                "toId": "f2",   "toSide":   "left",
            ] as [String: Any],
        ] as [String: Any])

        let link = try #require(doc.workspace.links.first)
        #expect(link.id == "l1")
        #expect(link.fromId == "f1")
        #expect(link.toId == "f2")
        #expect(link.fromSide == .right)
        #expect(link.toSide == .left)
    }

    @Test("link-create with malformed payload is ignored")
    func linkCreateRejectsMalformed() {
        let (bridge, doc) = makeBridge()

        // Missing `link` dict.
        bridge.handleCanvasMessage([
            "type": "link-create",
        ] as [String: Any])
        #expect(doc.workspace.links.isEmpty)

        // `link` present but missing required fields (no fromId/toId).
        bridge.handleCanvasMessage([
            "type": "link-create",
            "link": ["id": "l1"] as [String: Any],
        ] as [String: Any])
        #expect(doc.workspace.links.isEmpty)
    }

    @Test("link-create self-link is rejected by the store")
    func linkCreateSelfLinkRejected() {
        // JS `addLink` guards against this client-side, but the envelope
        // parser can't assume the JS guard held — an older renderer or
        // a misbehaving caller might send one. The store is the backstop.
        let (bridge, doc) = makeBridge()

        bridge.handleCanvasMessage([
            "type": "link-create",
            "link": [
                "id": "l1",
                "fromId": "f1", "fromSide": "right",
                "toId": "f1",   "toSide":   "left",
            ] as [String: Any],
        ] as [String: Any])

        #expect(doc.workspace.links.isEmpty,
                "store must reject self-links regardless of envelope shape")
    }

    @Test("link-create with missing endpoint frame is rejected")
    func linkCreateMissingFrameRejected() {
        let (bridge, doc) = makeBridge()

        bridge.handleCanvasMessage([
            "type": "link-create",
            "link": [
                "id": "l1",
                "fromId": "f1",       "fromSide": "right",
                "toId": "ghostFrame", "toSide":   "left",
            ] as [String: Any],
        ] as [String: Any])

        #expect(doc.workspace.links.isEmpty,
                "dangling-endpoint link must not land in the store")
    }

    @Test("link-create rejects duplicate endpoint pair")
    func linkCreateDuplicateEndpointsRejected() throws {
        let (bridge, doc) = makeBridge()

        let linkDict: [String: Any] = [
            "id": "l1",
            "fromId": "f1", "fromSide": "right",
            "toId": "f2",   "toSide":   "left",
        ]
        bridge.handleCanvasMessage([
            "type": "link-create",
            "link": linkDict,
        ] as [String: Any])

        // Second envelope with the same endpoints but a fresh id (matches
        // the JS-side `addLink` drop-again behavior — timestamped random
        // id, same (from,to,side,side) tuple).
        var dup = linkDict
        dup["id"] = "l2"
        bridge.handleCanvasMessage([
            "type": "link-create",
            "link": dup,
        ] as [String: Any])

        #expect(doc.workspace.links.count == 1,
                "duplicate-endpoint link must not double-add")
        #expect(doc.workspace.links.first?.id == "l1")
    }

    @Test("link-create missing side fields defaults to right/left")
    func linkCreateDefaultsSides() throws {
        // The JS `addLink` path supplies both sides explicitly, but the
        // on-disk schema allows them to be absent (pre-Phase-6b docs).
        // `LinkModel(jsonValue:)` falls back to right/left, matching the
        // JS defaults — preserve that via the bridge too.
        let (bridge, doc) = makeBridge()

        bridge.handleCanvasMessage([
            "type": "link-create",
            "link": [
                "id": "l1",
                "fromId": "f1",
                "toId": "f2",
            ] as [String: Any],
        ] as [String: Any])

        let link = try #require(doc.workspace.links.first)
        #expect(link.fromSide == .right)
        #expect(link.toSide == .left)
    }

    @Test("link-delete removes the link and registers undo")
    func linkDeleteRemovesAndRegistersUndo() throws {
        let (bridge, doc) = makeBridge()
        doc.workspace.createLink(LinkModel(
            id: "l1",
            fromId: "f1", fromSide: .right,
            toId: "f2",   toSide:   .left
        ))
        doc.undoManager?.removeAllActions()

        bridge.handleCanvasMessage([
            "type": "link-delete",
            "id": "l1",
        ] as [String: Any])

        #expect(doc.workspace.links.isEmpty)
        #expect(doc.undoManager?.canUndo == true)
        #expect(doc.undoManager?.undoActionName == "Delete Link")
    }

    @Test("link-delete without id is ignored")
    func linkDeleteWithoutIdIsIgnored() {
        let (bridge, doc) = makeBridge()
        doc.workspace.createLink(LinkModel(
            id: "l1",
            fromId: "f1", fromSide: .right,
            toId: "f2",   toSide:   .left
        ))

        bridge.handleCanvasMessage([
            "type": "link-delete",
        ] as [String: Any])

        #expect(doc.workspace.links.count == 1,
                "missing-id delete must not drop the link")
    }

    @Test("link-delete for unknown id is a no-op (no undo entry)")
    func linkDeleteUnknownIdIsNoop() {
        let (bridge, doc) = makeBridge()
        doc.workspace.createLink(LinkModel(
            id: "l1",
            fromId: "f1", fromSide: .right,
            toId: "f2",   toSide:   .left
        ))
        doc.undoManager?.removeAllActions()

        bridge.handleCanvasMessage([
            "type": "link-delete",
            "id": "ghostLink",
        ] as [String: Any])

        #expect(doc.workspace.links.count == 1)
        #expect(doc.undoManager?.canUndo == false,
                "unknown-id delete must not push a phantom undo entry")
    }
}

// MARK: - NativeBridge frame envelope dispatch
//
// Companion to the annotation + link envelope suites. Phase 6d flip #3:
// the JS `spawnFrame` path routes through `NativeAPI.workspaceCreateFrame`,
// which arrives here as `frame-model-create` and hits
// `WorkspaceStore.createFrame`. Tests drive the bridge dispatcher directly
// (no WKWebView) to catch regressions in the envelope parser and the
// counter-bump contract that keeps JS's `nextNum` in sync after the
// round-trip.
@MainActor
@Suite("NativeBridge · frame envelopes")
struct BridgeFrameEnvelopeTests {

    /// Fresh doc with no frames — most frame-envelope tests want a clean
    /// starting counter, and `createFrame` doesn't require a pre-existing
    /// frame to land (unlike annotations / links, which need endpoints).
    private func makeBridge() -> (NativeBridge, WebFramesDocument) {
        let doc = makeTestDocument()
        doc.undoManager?.removeAllActions()
        let bridge = NativeBridge()
        bridge.document = doc
        return (bridge, doc)
    }

    @Test("frame-model-create lands a fully-populated frame in the workspace")
    func frameCreateLandsFrame() throws {
        let (bridge, doc) = makeBridge()

        bridge.handleCanvasMessage([
            "type": "frame-model-create",
            "frame": [
                "id": "f1",
                "url": "https://example.com",
                "label": "Example",
                "x": 100, "y": 200,
                "w": 1280, "h": 800,
                "num": 1,
            ] as [String: Any],
        ] as [String: Any])

        let frame = try #require(doc.workspace.frames.first)
        #expect(frame.id == "f1")
        #expect(frame.url == "https://example.com")
        #expect(frame.label == "Example")
        #expect(frame.x == 100)
        #expect(frame.y == 200)
        #expect(frame.w == 1280)
        #expect(frame.h == 800)
        #expect(frame.num == 1)
        #expect(frame.isImage == false)
    }

    @Test("frame-model-create with malformed payload does not mutate workspace")
    func frameCreateRejectsMalformed() {
        let (bridge, doc) = makeBridge()

        // Missing `frame` — dispatcher logs and returns.
        bridge.handleCanvasMessage([
            "type": "frame-model-create",
        ] as [String: Any])

        #expect(doc.workspace.frames.isEmpty,
                "malformed frame-model-create must not leak a zombie frame")

        // Missing required fields — `FrameModel(jsonValue:)` returns nil.
        bridge.handleCanvasMessage([
            "type": "frame-model-create",
            "frame": [
                "id": "f1",
                // url is required
                "label": "no url",
            ] as [String: Any],
        ] as [String: Any])

        #expect(doc.workspace.frames.isEmpty,
                "missing-url frame payload must be rejected by FrameModel parser")
    }

    @Test("frame-model-create bumps nextFrameNum so the JS round-trip stays in sync")
    func frameCreateAdvancesCounter() throws {
        let (bridge, doc) = makeBridge()
        // Starting counter is 1 on a fresh doc.
        #expect(doc.workspace.serialize().nextNum == 1)

        bridge.handleCanvasMessage([
            "type": "frame-model-create",
            "frame": [
                "id": "f1", "url": "https://example.com", "label": "",
                "x": 0, "y": 0, "w": 1, "h": 1, "num": 1,
            ] as [String: Any],
        ] as [String: Any])

        // Serialized payload must carry `nextNum = 2` so JS's
        // `applyDocState` → `nextNum = payload.nextNum` doesn't regress
        // to 1 and collide on the next spawn.
        #expect(doc.workspace.serialize().nextNum == 2,
                "createFrame must advance nextFrameNum past the new frame's num")
    }

    @Test("frame-model-create registers undo with 'Add Frame' action name")
    func frameCreateRegistersUndo() throws {
        let (bridge, doc) = makeBridge()

        bridge.handleCanvasMessage([
            "type": "frame-model-create",
            "frame": [
                "id": "f1", "url": "https://example.com", "label": "",
                "x": 0, "y": 0, "w": 1, "h": 1, "num": 1,
            ] as [String: Any],
        ] as [String: Any])

        #expect(doc.undoManager?.canUndo == true)
        #expect(doc.undoManager?.undoActionName == "Add Frame")
    }

    @Test("frame-model-create rejects a duplicate id (no-op, no undo)")
    func frameCreateRejectsDuplicateId() throws {
        let (bridge, doc) = makeBridge()
        doc.workspace.createFrame(FrameModel(
            id: "f1", url: "https://example.com", label: "first",
            x: 0, y: 0, w: 1, h: 1, num: 1,
            isImage: false, filePath: nil
        ))
        doc.undoManager?.removeAllActions()

        bridge.handleCanvasMessage([
            "type": "frame-model-create",
            "frame": [
                "id": "f1", "url": "https://other.example", "label": "dup",
                "x": 10, "y": 10, "w": 2, "h": 2, "num": 2,
            ] as [String: Any],
        ] as [String: Any])

        // `createFrame` silently no-ops on dup — the first frame wins.
        #expect(doc.workspace.frames.count == 1)
        #expect(doc.workspace.frames.first?.label == "first",
                "duplicate-id create must not overwrite the existing frame")
        #expect(doc.undoManager?.canUndo == false,
                "rejected create must not push a phantom undo entry")
    }

    @Test("frame-model-create preserves image-frame fields through the typed model")
    func frameCreateImageFrame() throws {
        // Guard against a future change to `FrameModel(jsonValue:)` that
        // accidentally drops the isImage flag, which would visually silent-
        // fail as "web frame loading image URL".
        let (bridge, doc) = makeBridge()

        bridge.handleCanvasMessage([
            "type": "frame-model-create",
            "frame": [
                "id": "fi", "url": "image://screenshot.png", "label": "screenshot",
                "x": 0, "y": 0, "w": 800, "h": 600, "num": 1,
                "isImage": true,
                "filePath": "/Users/me/Desktop/screenshot.png",
            ] as [String: Any],
        ] as [String: Any])

        let frame = try #require(doc.workspace.frames.first)
        #expect(frame.isImage == true)
        #expect(frame.filePath == "/Users/me/Desktop/screenshot.png")
    }

    @Test("frame-model-create preserves JS-only image fields via extras round-trip")
    func frameCreateImageExtrasRoundTrip() throws {
        // Phase 6d item #5 end-to-end: `spawnImageFrame` in index.html now
        // routes through `NativeAPI.workspaceCreateFrame`. The image-specific
        // fields `imgUrl`, `natW`, `natH` are not typed on `FrameModel`, so
        // they must survive via the `extras` catchall for the round-trip
        // through `doc-load-state` → `applyDocState` → `renderImageFrame`
        // to rebuild a working <img src=…> with a valid aspect anchor.
        //
        // This test asserts the catchall path by dispatching the envelope
        // the way the JS bridge would, then re-serializing the stored frame
        // to confirm the fields re-emerge in the JSON payload JS will see.
        let (bridge, doc) = makeBridge()

        bridge.handleCanvasMessage([
            "type": "frame-model-create",
            "frame": [
                "id": "img1", "url": "image://shot", "label": "shot",
                "x": 0, "y": 0, "w": 800, "h": 600, "num": 1,
                "isImage": true,
                "imgUrl": "blob:wf-local//abc-123",
                "natW": 1920,
                "natH": 1440,
            ] as [String: Any],
        ] as [String: Any])

        let frame = try #require(doc.workspace.frames.first)
        #expect(frame.extras["imgUrl"] == .string("blob:wf-local//abc-123"))
        #expect(frame.extras["natW"]   == .number(1920))
        #expect(frame.extras["natH"]   == .number(1440))

        // Re-serialize and confirm the extras survive the trip back out.
        // This is what `pushDocumentStateToCanvas` will hand to JS.
        guard case .object(let out) = frame.jsonValue else {
            Issue.record("frame.jsonValue did not produce object"); return
        }
        #expect(out["imgUrl"] == .string("blob:wf-local//abc-123"))
        #expect(out["natW"]   == .number(1920))
        #expect(out["natH"]   == .number(1440))
    }

    // MARK: frame-move
    //
    // Phase 6d item #5: drag-end from the native chrome (and any future
    // move path) routes through `NativeAPI.workspaceMoveFrame`, which
    // arrives here as `frame-move` and lands in `WorkspaceStore.moveFrame`.
    // Intermediate drag-move ticks stay JS-local so these tests only need
    // to cover the commit boundary, not mousemove rate.

    /// Seeds a single frame for the move/resize/rename/delete tests.
    private func makeBridgeWithFrame(
        id: String = "f1",
        x: CGFloat = 0, y: CGFloat = 0,
        w: CGFloat = 1280, h: CGFloat = 800,
        label: String = "Example"
    ) -> (NativeBridge, WebFramesDocument) {
        let (bridge, doc) = makeBridge()
        doc.workspace.createFrame(FrameModel(
            id: id, url: "https://example.com", label: label,
            x: x, y: y, w: w, h: h, num: 1,
            isImage: false, filePath: nil
        ))
        doc.undoManager?.removeAllActions()
        return (bridge, doc)
    }

    @Test("frame-move commits the new origin to the workspace")
    func frameMoveLandsNewOrigin() throws {
        let (bridge, doc) = makeBridgeWithFrame(x: 10, y: 20)

        bridge.handleCanvasMessage([
            "type": "frame-move",
            "id": "f1",
            "x": 150,
            "y": 275,
        ] as [String: Any])

        let frame = try #require(doc.workspace.frames.first)
        #expect(frame.x == 150)
        #expect(frame.y == 275)
    }

    @Test("frame-move with unchanged coords is a no-op")
    func frameMoveUnchangedIsNoop() throws {
        let (bridge, doc) = makeBridgeWithFrame(x: 42, y: 42)

        bridge.handleCanvasMessage([
            "type": "frame-move",
            "id": "f1",
            "x": 42, "y": 42,
        ] as [String: Any])

        // A zero-delta move must not re-dirty the doc or push an undo op
        // — `WorkspaceStore.moveFrame` short-circuits. Matches the
        // click-without-drag case on the canvas.
        #expect(doc.undoManager?.canUndo == false,
                "unchanged-coord move must not register work")
    }

    @Test("frame-move with unknown id does not touch any frame")
    func frameMoveUnknownIdIsNoop() throws {
        let (bridge, doc) = makeBridgeWithFrame(x: 5, y: 5)

        bridge.handleCanvasMessage([
            "type": "frame-move",
            "id": "does-not-exist",
            "x": 999, "y": 999,
        ] as [String: Any])

        let frame = try #require(doc.workspace.frames.first)
        #expect(frame.x == 5, "unrelated frame must stay put")
        #expect(frame.y == 5)
    }

    @Test("frame-move missing id is rejected by the dispatcher")
    func frameMoveMissingIdRejected() throws {
        let (bridge, doc) = makeBridgeWithFrame(x: 0, y: 0)

        // No `id` key — bridge logs and returns before touching the store.
        bridge.handleCanvasMessage([
            "type": "frame-move",
            "x": 1, "y": 1,
        ] as [String: Any])

        let frame = try #require(doc.workspace.frames.first)
        #expect(frame.x == 0)
        #expect(frame.y == 0)
    }

    @Test("frame-move is undoable and restores the previous origin")
    func frameMoveIsUndoable() throws {
        let (bridge, doc) = makeBridgeWithFrame(x: 0, y: 0)

        bridge.handleCanvasMessage([
            "type": "frame-move",
            "id": "f1",
            "x": 100, "y": 200,
        ] as [String: Any])

        // `registerUndo(for:)` records `.frameMoved` as "Move Frames" so an
        // accidental drag or Align & Distribute can be reverted.
        #expect(doc.undoManager?.canUndo == true)
        doc.undoManager?.undo()
        let frame = try #require(doc.workspace.frame(id: "f1"))
        #expect(frame.x == 0 && frame.y == 0)
    }

    // MARK: frame-resize

    @Test("frame-resize commits the new size to the workspace")
    func frameResizeLandsNewSize() throws {
        let (bridge, doc) = makeBridgeWithFrame(w: 800, h: 600)

        bridge.handleCanvasMessage([
            "type": "frame-resize",
            "id": "f1",
            "w": 1024, "h": 768,
        ] as [String: Any])

        let frame = try #require(doc.workspace.frames.first)
        #expect(frame.w == 1024)
        #expect(frame.h == 768)
    }

    @Test("frame-resize clamps width and height to ≥ 1")
    func frameResizeClampsToOne() throws {
        let (bridge, doc) = makeBridgeWithFrame(w: 800, h: 600)

        bridge.handleCanvasMessage([
            "type": "frame-resize",
            "id": "f1",
            "w": 0, "h": -5,
        ] as [String: Any])

        // `WorkspaceStore.resizeFrame` clamps w/h to ≥ 1 — mirrors the
        // CSS minimum on the JS side. A zero- or negative-dimension
        // resize must land as 1×1, not pass through and break hit tests.
        let frame = try #require(doc.workspace.frames.first)
        #expect(frame.w == 1)
        #expect(frame.h == 1)
    }

    @Test("frame-resize with unchanged size is a no-op")
    func frameResizeUnchangedIsNoop() throws {
        let (bridge, doc) = makeBridgeWithFrame(w: 400, h: 300)

        bridge.handleCanvasMessage([
            "type": "frame-resize",
            "id": "f1",
            "w": 400, "h": 300,
        ] as [String: Any])

        // Size-preset tap on the currently-selected preset should not
        // register work — matches `moveFrame`'s no-delta guard.
        #expect(doc.undoManager?.canUndo == false)
    }

    @Test("frame-resize missing id is rejected by the dispatcher")
    func frameResizeMissingIdRejected() throws {
        let (bridge, doc) = makeBridgeWithFrame(w: 100, h: 100)

        bridge.handleCanvasMessage([
            "type": "frame-resize",
            "w": 999, "h": 999,
        ] as [String: Any])

        let frame = try #require(doc.workspace.frames.first)
        #expect(frame.w == 100)
        #expect(frame.h == 100)
    }

    @Test("frame-resize is non-undoable — matches JS undoStack policy")
    func frameResizeIsNotUndoable() throws {
        let (bridge, doc) = makeBridgeWithFrame(w: 100, h: 100)

        bridge.handleCanvasMessage([
            "type": "frame-resize",
            "id": "f1",
            "w": 200, "h": 150,
        ] as [String: Any])

        #expect(doc.undoManager?.canUndo == false)
    }

    // MARK: frame-rename

    @Test("frame-rename commits the new label to the workspace")
    func frameRenameLandsNewLabel() throws {
        let (bridge, doc) = makeBridgeWithFrame(label: "Old")

        bridge.handleCanvasMessage([
            "type": "frame-rename",
            "id": "f1",
            "label": "New Title",
        ] as [String: Any])

        let frame = try #require(doc.workspace.frames.first)
        #expect(frame.label == "New Title")
    }

    @Test("frame-rename with unchanged label is a no-op")
    func frameRenameUnchangedIsNoop() throws {
        let (bridge, doc) = makeBridgeWithFrame(label: "Same")

        bridge.handleCanvasMessage([
            "type": "frame-rename",
            "id": "f1",
            "label": "Same",
        ] as [String: Any])

        // Blur-without-edit must not register work — the title input
        // commits on every blur, so this path fires often.
        #expect(doc.undoManager?.canUndo == false)
    }

    @Test("frame-rename missing id is rejected by the dispatcher")
    func frameRenameMissingIdRejected() throws {
        let (bridge, doc) = makeBridgeWithFrame(label: "Untouched")

        bridge.handleCanvasMessage([
            "type": "frame-rename",
            "label": "Injected",
        ] as [String: Any])

        let frame = try #require(doc.workspace.frames.first)
        #expect(frame.label == "Untouched")
    }

    @Test("frame-rename is non-undoable — matches JS undoStack policy")
    func frameRenameIsNotUndoable() throws {
        let (bridge, doc) = makeBridgeWithFrame(label: "Old")

        bridge.handleCanvasMessage([
            "type": "frame-rename",
            "id": "f1",
            "label": "New",
        ] as [String: Any])

        #expect(doc.undoManager?.canUndo == false)
    }

    // MARK: frame-delete

    @Test("frame-delete removes the frame from the workspace")
    func frameDeleteRemovesFrame() throws {
        let (bridge, doc) = makeBridgeWithFrame()

        bridge.handleCanvasMessage([
            "type": "frame-delete",
            "id": "f1",
        ] as [String: Any])

        #expect(doc.workspace.frames.isEmpty)
    }

    @Test("frame-delete cascades to annotations and links on both endpoints")
    func frameDeleteCascadesDependents() throws {
        let (bridge, doc) = makeBridgeWithFrame()
        // Add a second frame + a link that crosses them + an ann on f1.
        doc.workspace.createFrame(FrameModel(
            id: "f2", url: "https://other.example", label: "other",
            x: 500, y: 0, w: 400, h: 300, num: 2,
            isImage: false, filePath: nil
        ))
        doc.workspace.createAnnotation(AnnotationModel(
            id: "a1", num: 1, frameId: "f1",
            xPct: 0.5, yPct: 0.5,
            color: "red", comment: "pin on f1", resolved: false,
            edits: [:],
            frameUrl: "https://example.com", frameLabel: "Example"
        ))
        doc.workspace.createLink(LinkModel(
            id: "l1",
            fromId: "f1", fromSide: .right,
            toId: "f2", toSide: .left
        ))
        doc.undoManager?.removeAllActions()

        bridge.handleCanvasMessage([
            "type": "frame-delete",
            "id": "f1",
        ] as [String: Any])

        // Frame gone, dependents pruned, other frame untouched.
        #expect(doc.workspace.frames.map(\.id) == ["f2"])
        #expect(doc.workspace.annotations.isEmpty,
                "annotation on deleted frame must cascade")
        #expect(doc.workspace.links.isEmpty,
                "link with endpoint on deleted frame must cascade")
    }

    @Test("frame-delete registers undo with 'Delete Frame' action name")
    func frameDeleteRegistersUndo() throws {
        let (bridge, doc) = makeBridgeWithFrame()

        bridge.handleCanvasMessage([
            "type": "frame-delete",
            "id": "f1",
        ] as [String: Any])

        // The delete path is the only frame-intent envelope that registers
        // undo — parity with JS `undoStack` which only stores deletions.
        // Menu bar "Undo Delete Frame" depends on this action name.
        #expect(doc.undoManager?.canUndo == true)
        #expect(doc.undoManager?.undoActionName == "Delete Frame")
    }

    @Test("frame-delete with unknown id is a silent no-op")
    func frameDeleteUnknownIdIsNoop() throws {
        let (bridge, doc) = makeBridgeWithFrame()

        bridge.handleCanvasMessage([
            "type": "frame-delete",
            "id": "not-a-real-id",
        ] as [String: Any])

        #expect(doc.workspace.frames.count == 1)
        #expect(doc.undoManager?.canUndo == false,
                "unknown-id delete must not push a phantom undo entry")
    }

    @Test("frame-delete missing id is rejected by the dispatcher")
    func frameDeleteMissingIdRejected() throws {
        let (bridge, doc) = makeBridgeWithFrame()

        bridge.handleCanvasMessage([
            "type": "frame-delete",
        ] as [String: Any])

        #expect(doc.workspace.frames.count == 1)
        #expect(doc.undoManager?.canUndo == false)
    }
}
