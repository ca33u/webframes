//
//  WorkspaceModelsTests.swift
//  webframesTests
//
//  Unit tests for the typed workspace model types (FrameModel, LinkModel,
//  AnnotationModel, ViewportModel), WorkspaceStore's read path (apply +
//  observers), the Phase 6d mutation API (create / move / resize / rename /
//  delete across frames / links / annotations), and the bounded undo stack.
//
//  Tests are @MainActor because WorkspaceStore is MainActor-isolated.
//
//  Scope for Phase 6d: the store is still additive — no UI path mutates
//  through it yet. These tests lock down the contract so wiring the store
//  up to WebFramesDocument and the native views later is a one-line move.
//

import Foundation
import CoreGraphics
import Testing
@testable import Web_Frames

// MARK: - FrameModel

@Suite("FrameModel · JSONValue round-trip")
struct FrameModelRoundTripTests {

    @Test("fully-populated frame round-trips")
    func fullFrame() {
        let f = FrameModel(
            id: "f1", url: "https://example.com", label: "Hello",
            x: 10, y: 20, w: 300, h: 400, num: 3,
            isImage: false, filePath: nil
        )
        let rebuilt = FrameModel(jsonValue: f.jsonValue)
        #expect(rebuilt == f)
    }

    @Test("image frame carries filePath through round-trip")
    func imageFrame() {
        let f = FrameModel(
            id: "img1", url: "file:///tmp/a.png", label: "a.png",
            x: 0, y: 0, w: 200, h: 100, num: 1,
            isImage: true, filePath: "/tmp/a.png"
        )
        let rebuilt = FrameModel(jsonValue: f.jsonValue)
        #expect(rebuilt?.isImage == true)
        #expect(rebuilt?.filePath == "/tmp/a.png")
    }

    @Test("non-object JSONValue returns nil instead of crashing")
    func nonObjectReturnsNil() {
        #expect(FrameModel(jsonValue: .null) == nil)
        #expect(FrameModel(jsonValue: .string("not an object")) == nil)
        #expect(FrameModel(jsonValue: .array([])) == nil)
    }

    @Test("missing required id/url returns nil")
    func missingRequiredReturnsNil() {
        let o: JSONValue = .object(["x": .number(1), "y": .number(2)])
        #expect(FrameModel(jsonValue: o) == nil)
    }

    @Test("missing optional numeric fields default to zero")
    func missingNumericsDefaultToZero() {
        let o: JSONValue = .object([
            "id": .string("f2"),
            "url": .string("https://example.com"),
        ])
        let f = FrameModel(jsonValue: o)
        #expect(f?.x == 0)
        #expect(f?.w == 0)
        #expect(f?.num == 0)
        #expect(f?.isImage == false)
    }

    // MARK: extras catchall
    //
    // Phase 6d item #5: image frames carry JS-only fields `imgUrl`, `natW`,
    // `natH` that Swift doesn't interpret but MUST preserve through the
    // typed-model ↔ JSON round-trip. Without the catchall, every Swift-side
    // mutation (Add-Frame, delete, move, …) would strip these fields the
    // first time the frame re-serialized, breaking the <img> source on reload
    // and the aspect-ratio anchor on resize. Mirrors the extras rules on
    // AnnotationModel — the same symmetry applies to any future JS-only
    // keys we haven't thought of yet.

    @Test("unknown JS-owned fields (imgUrl, natW, natH) round-trip via extras")
    func extrasCatchallPreservesUnknownFields() {
        // Raw incoming JSON from JS representing an image frame with the
        // image-specific fields the typed mirror doesn't enumerate.
        let o: JSONValue = .object([
            "id":      .string("img1"),
            "url":     .string("image://screenshot"),
            "label":   .string("screenshot"),
            "x":       .number(10),
            "y":       .number(20),
            "w":       .number(800),
            "h":       .number(600),
            "num":     .number(3),
            "isImage": .bool(true),
            "imgUrl":  .string("blob:wf-local//abc-123"),
            "natW":    .number(1920),
            "natH":    .number(1440),
        ])
        let f = FrameModel(jsonValue: o)
        #expect(f?.id == "img1")
        #expect(f?.isImage == true)
        // Image fields must have landed in extras (they're not typed).
        #expect(f?.extras["imgUrl"] == .string("blob:wf-local//abc-123"))
        #expect(f?.extras["natW"]   == .number(1920))
        #expect(f?.extras["natH"]   == .number(1440))
        // And the typed keys must NOT have leaked into extras.
        #expect(f?.extras["id"]      == nil)
        #expect(f?.extras["isImage"] == nil)

        // Round-trip: typed fields preserved AND extras preserved. This is
        // the whole contract the flip depends on.
        guard let model = f else {
            Issue.record("FrameModel parse returned nil"); return
        }
        let serialized = model.jsonValue
        guard case .object(let out) = serialized else {
            Issue.record("serialize did not produce object"); return
        }
        #expect(out["imgUrl"] == .string("blob:wf-local//abc-123"))
        #expect(out["natW"]   == .number(1920))
        #expect(out["natH"]   == .number(1440))
        #expect(out["isImage"] == .bool(true))
        #expect(out["id"]      == .string("img1"))
    }

    @Test("serialize preserves extras from load, typed fields overwrite stale carryover")
    func typedFieldsWinOverStaleExtras() {
        // Synthetic adversarial input: extras carries a value for a key
        // that's actually a typed property. Can't happen via the parser
        // (which filters typed keys out) but guards against mis-constructed
        // models and documents the "typed wins" invariant.
        let f = FrameModel(
            id: "f1", url: "https://example.com", label: "Hi",
            x: 5, y: 6, w: 100, h: 200, num: 7,
            isImage: false, filePath: nil,
            extras: ["url": .string("https://stale.example")] // stale
        )
        guard case .object(let out) = f.jsonValue else {
            Issue.record("serialize did not produce object"); return
        }
        #expect(out["url"] == .string("https://example.com"),
                "typed `url` must overwrite stale `url` in extras")
    }

    @Test("isImage=false + filePath=nil emit no sentinel keys")
    func asymmetricOnDiskShape() {
        // Regression guard: web frames shouldn't start carrying `isImage`/
        // `filePath` keys after a Swift round-trip — that would bloat every
        // doc on save. The extras catchall could accidentally reintroduce
        // these if the filter ever broke.
        let f = FrameModel(
            id: "f1", url: "https://example.com", label: "",
            x: 0, y: 0, w: 100, h: 100, num: 1,
            isImage: false, filePath: nil
        )
        guard case .object(let out) = f.jsonValue else {
            Issue.record("serialize did not produce object"); return
        }
        #expect(out["isImage"]  == nil)
        #expect(out["filePath"] == nil)
    }

    @Test("extras catchall survives repeated round-trips")
    func extrasSurviveMultipleRoundTrips() {
        // Simulates the Swift-side mutation loop: parse → mutate typed
        // field → serialize → parse → … The image-specific extras should
        // survive every hop unchanged.
        let seed: JSONValue = .object([
            "id":     .string("img1"),
            "url":    .string("image://"),
            "label":  .string("a"),
            "x":      .number(0), "y": .number(0),
            "w":      .number(100), "h": .number(100),
            "num":    .number(1),
            "isImage": .bool(true),
            "imgUrl": .string("blob:x"),
            "natW":   .number(640),
            "natH":   .number(480),
        ])
        var current = seed
        for i in 0..<3 {
            guard var m = FrameModel(jsonValue: current) else {
                Issue.record("FrameModel parse failed on iter \(i)"); return
            }
            m.x += 1 // touch a typed field each loop
            current = m.jsonValue
        }
        guard case .object(let out) = current else {
            Issue.record("final serialize did not produce object"); return
        }
        #expect(out["imgUrl"] == .string("blob:x"))
        #expect(out["natW"]   == .number(640))
        #expect(out["natH"]   == .number(480))
        #expect(out["x"]      == .number(3))
    }
}

// MARK: - LinkModel

@Suite("LinkModel · JSONValue round-trip")
struct LinkModelRoundTripTests {

    @Test("full link round-trips")
    func fullLink() {
        let l = LinkModel(id: "ln1", fromId: "a", fromSide: .bottom,
                          toId: "b", toSide: .top)
        let rebuilt = LinkModel(jsonValue: l.jsonValue)
        #expect(rebuilt == l)
    }

    @Test("missing sides default to right→left")
    func defaultSides() {
        let o: JSONValue = .object([
            "id": .string("ln1"),
            "fromId": .string("a"),
            "toId": .string("b"),
        ])
        let l = LinkModel(jsonValue: o)
        #expect(l?.fromSide == .right)
        #expect(l?.toSide == .left)
    }

    @Test("unknown side string falls back to default")
    func unknownSide() {
        let o: JSONValue = .object([
            "id": .string("ln1"),
            "fromId": .string("a"),
            "toId": .string("b"),
            "fromSide": .string("diagonal"),
            "toSide": .string("center"),
        ])
        let l = LinkModel(jsonValue: o)
        #expect(l?.fromSide == .right)
        #expect(l?.toSide == .left)
    }

    @Test("missing fromId/toId returns nil")
    func missingEndpoints() {
        let o: JSONValue = .object(["id": .string("ln1")])
        #expect(LinkModel(jsonValue: o) == nil)
    }
}

// MARK: - AnnotationModel

@Suite("AnnotationModel · JSONValue round-trip")
struct AnnotationModelRoundTripTests {

    @Test("bare-minimum annotation round-trips")
    func minimal() {
        let a = AnnotationModel(
            id: "a1", num: 1, frameId: "f1",
            xPct: 0.5, yPct: 0.25,
            color: "blue", comment: "",
            resolved: false, edits: [:],
            frameUrl: nil, frameLabel: nil
        )
        let rebuilt = AnnotationModel(jsonValue: a.jsonValue)
        #expect(rebuilt == a)
    }

    @Test("edits map round-trips")
    func editsRoundTrip() {
        let a = AnnotationModel(
            id: "a1", num: 1, frameId: "f1",
            xPct: 0, yPct: 0,
            color: "orange", comment: "fix this",
            resolved: true,
            edits: ["color": "red", "font-size": "14px"],
            frameUrl: "https://example.com", frameLabel: "Example"
        )
        let rebuilt = AnnotationModel(jsonValue: a.jsonValue)
        #expect(rebuilt?.edits == ["color": "red", "font-size": "14px"])
        #expect(rebuilt?.resolved == true)
        #expect(rebuilt?.frameUrl == "https://example.com")
    }

    @Test("missing color defaults to blue")
    func defaultColor() {
        let o: JSONValue = .object([
            "id": .string("a1"),
            "frameId": .string("f1"),
        ])
        let a = AnnotationModel(jsonValue: o)
        #expect(a?.color == "blue")
    }

    /// JS stores richer per-annotation state than Swift enumerates —
    /// `element` (DOM hit-test snapshot: tagName, componentName,
    /// computedStyles, screenshot data-URL, …), `initialScrollX/Y`
    /// (pin-follow anchors), plus any forward-added fields. These MUST
    /// survive the typed-mirror → JSONValue round-trip because every
    /// Swift-side mutation re-serializes the whole annotations array; if
    /// they're dropped, deleting one pin destroys pin-editor labels and
    /// screenshots on all the rest.
    @Test("unknown JS-owned fields (element, initialScrollX/Y) round-trip via extras")
    func extrasCatchallPreservesUnknownFields() {
        let o: JSONValue = .object([
            "id":       .string("a1"),
            "num":      .number(1),
            "frameId":  .string("f1"),
            "xPct":     .number(0.5),
            "yPct":     .number(0.25),
            "color":    .string("amber"),
            "comment":  .string("fixme"),
            "resolved": .bool(false),
            // JS-owned fields Swift doesn't model:
            "element": .object([
                "tagName":       .string("div"),
                "componentName": .string("Button"),
                "screenshot":    .string("data:image/png;base64,iVBOR..."),
                "computedStyles": .object([
                    "color": .string("rgb(255, 0, 0)"),
                ]),
            ]),
            "initialScrollX": .number(40),
            "initialScrollY": .number(120),
        ])
        let a = AnnotationModel(jsonValue: o)
        #expect(a?.extras["element"] != nil)
        #expect(a?.extras["initialScrollX"] == .number(40))
        #expect(a?.extras["initialScrollY"] == .number(120))

        // Round-trip: typed fields preserved AND extras preserved.
        let rebuilt = AnnotationModel(jsonValue: a!.jsonValue)
        #expect(rebuilt == a)
        guard case .object(let o2) = a!.jsonValue else {
            Issue.record("expected .object"); return
        }
        #expect(o2["element"] != nil)
        #expect(o2["initialScrollX"] == .number(40))
    }

    /// Guard against the silent-data-loss bug Swift mutations would cause
    /// if the typed mirror dropped unknown fields — the second pin would
    /// survive a round-trip even though only the first was touched.
    @Test("serialize preserves extras from load, typed fields overwrite stale carryover")
    func typedFieldsWinOverStaleExtras() {
        // Simulate: parse an annotation with a stale duplicate color key
        // buried in extras (can't happen today because parse filters typed
        // keys, but the invariant "typed wins on serialize" should still
        // hold). Mutate color, re-serialize — typed color in output, not
        // the stale one.
        var a = AnnotationModel(
            id: "a1", num: 1, frameId: "f1",
            xPct: 0, yPct: 0,
            color: "blue", comment: "",
            resolved: false, edits: [:],
            frameUrl: nil, frameLabel: nil,
            extras: ["color": .string("red")] // stale
        )
        a.color = "amber"
        guard case .object(let o) = a.jsonValue else {
            Issue.record("expected .object"); return
        }
        #expect(o["color"] == .string("amber"))
    }
}

// MARK: - ViewportModel

@Suite("ViewportModel · JSONValue round-trip")
struct ViewportModelRoundTripTests {

    @Test("round-trips")
    func roundTrip() {
        let v = ViewportModel(scale: 1.5, panX: -100, panY: 200)
        let rebuilt = ViewportModel(jsonValue: v.jsonValue)
        #expect(rebuilt == v)
    }

    @Test("non-object falls back to identity")
    func nonObjectIsIdentity() {
        let v = ViewportModel(jsonValue: .null)
        #expect(v.scale == 1)
        #expect(v.panX == 80)
        #expect(v.panY == 80)
    }

    @Test("missing fields use identity defaults")
    func missingFieldsDefault() {
        let v = ViewportModel(jsonValue: .object(["scale": .number(2)]))
        #expect(v.scale == 2)
        #expect(v.panX == 80) // identity.panX
    }
}

// MARK: - ViewportModel · pan/zoom math (Phase 6e Step 1)
//
// These tests pin down the pure functions that the native canvas gesture
// monitor calls on every scrollWheel / magnify tick. They're ported from
// the JS wheel handler at `Renderer/index.html` (the `py -= e.deltaY`,
// cursor-centric zoom block) — so the invariants to lock down are the
// same ones JS already enforces in practice:
//
//   * pan is pure addition (no scale interaction);
//   * zoom around a point leaves that point pinned in pixel space —
//     `px' + s' · ax_world == px + s · ax_world` for the chosen anchor;
//   * scale is clamped to [minScale, maxScale] and at the rails, pan
//     stays put (the guard inside `zoomed` bails out with `self`).
//
// Keeping these as pure-math tests (no AppKit, no store) means the
// gesture monitor in DocumentWindowController is thin translation glue
// and this suite is the single source of truth for the math.

@Suite("ViewportModel · pan math")
struct ViewportModelPanTests {

    @Test("pan adds deltas to both axes")
    func panAdds() {
        let v = ViewportModel(scale: 1.5, panX: 100, panY: 200)
        let p = v.panned(byX: 10, byY: -5)
        #expect(p.panX == 110)
        #expect(p.panY == 195)
        #expect(p.scale == 1.5) // scale untouched
    }

    @Test("zero pan is a no-op")
    func zeroPan() {
        let v = ViewportModel(scale: 2, panX: 80, panY: 80)
        #expect(v.panned(byX: 0, byY: 0) == v)
    }

    @Test("pan is independent of scale")
    func panIndependentOfScale() {
        let a = ViewportModel(scale: 0.25, panX: 0, panY: 0)
            .panned(byX: 30, byY: 40)
        let b = ViewportModel(scale: 4, panX: 0, panY: 0)
            .panned(byX: 30, byY: 40)
        #expect(a.panX == b.panX)
        #expect(a.panY == b.panY)
    }
}

@Suite("ViewportModel · zoom math")
struct ViewportModelZoomTests {

    /// Numeric tolerance for the "anchor stays pinned under cursor"
    /// invariant — double-precision multiplies in the zoom math can
    /// leave single-ulp residue vs. the ideal rational.
    private let eps: CGFloat = 1e-9

    @Test("scale is clamped to [minScale, maxScale]")
    func scaleClamp() {
        #expect(ViewportModel.clampScale(0)    == ViewportModel.minScale)
        #expect(ViewportModel.clampScale(-1)   == ViewportModel.minScale)
        #expect(ViewportModel.clampScale(0.04) == ViewportModel.minScale)
        #expect(ViewportModel.clampScale(0.1)  == 0.1)
        #expect(ViewportModel.clampScale(10)   == ViewportModel.maxScale)
        #expect(ViewportModel.clampScale(ViewportModel.maxScale) == ViewportModel.maxScale)
    }

    @Test("zoom multiplies scale and clamps")
    func zoomMultipliesAndClamps() {
        let v = ViewportModel(scale: 1, panX: 0, panY: 0)
        #expect(v.zoomed(multiplier: 2, aroundX: 0, aroundY: 0).scale == 2)
        // multiplier=1 is a no-op
        #expect(v.zoomed(multiplier: 1, aroundX: 0, aroundY: 0) == v)
        // overshoot clamps
        let far = v.zoomed(multiplier: 1000, aroundX: 0, aroundY: 0)
        #expect(far.scale == ViewportModel.maxScale)
    }

    @Test("zoom around cursor keeps the anchor pinned in screen space")
    func anchorStaysPinned() {
        // Given a viewport, screen pixel under cursor = px + s * worldX,
        // so the world point under the cursor is (ax - panX) / scale.
        // After zoom, the new pan should satisfy:
        //   px' + s' * worldX == ax
        // which is exactly the formula `zoomed` implements.
        let v = ViewportModel(scale: 1.5, panX: 200, panY: 150)
        let ax: CGFloat = 640
        let ay: CGFloat = 360
        let worldX = (ax - v.panX) / v.scale
        let worldY = (ay - v.panY) / v.scale

        for m in [0.5, 1.2, 2.0, 3.1] as [CGFloat] {
            let z = v.zoomed(multiplier: m, aroundX: ax, aroundY: ay)
            let screenX = z.panX + z.scale * worldX
            let screenY = z.panY + z.scale * worldY
            #expect(abs(screenX - ax) < eps)
            #expect(abs(screenY - ay) < eps)
            #expect(z.scale == v.scale * m)
        }
    }

    @Test("zoom at min rail: no pan drift when scale is already clamped")
    func minRailNoDrift() {
        let v = ViewportModel(scale: ViewportModel.minScale, panX: 100, panY: 80)
        let z = v.zoomed(multiplier: 0.1, aroundX: 500, aroundY: 500)
        #expect(z.scale == ViewportModel.minScale)
        #expect(z.panX  == v.panX)
        #expect(z.panY  == v.panY)
    }

    @Test("zoom at max rail: no pan drift when scale is already clamped")
    func maxRailNoDrift() {
        let v = ViewportModel(scale: ViewportModel.maxScale, panX: -40, panY: 220)
        let z = v.zoomed(multiplier: 10, aroundX: 0, aroundY: 0)
        #expect(z.scale == ViewportModel.maxScale)
        #expect(z.panX  == v.panX)
        #expect(z.panY  == v.panY)
    }

    @Test("zoom around origin only shifts pan by the scale ratio")
    func zoomAroundOrigin() {
        // Anchor = (0, 0) means `ax - panX == -panX` and
        // `panX' = -(-panX) * ratio = panX * ratio`. Useful sanity check.
        let v = ViewportModel(scale: 1, panX: 50, panY: -30)
        let z = v.zoomed(multiplier: 2, aroundX: 0, aroundY: 0)
        #expect(z.scale == 2)
        #expect(z.panX  == v.panX * 2)
        #expect(z.panY  == v.panY * 2)
    }
}

// MARK: - WorkspaceStore · apply

@MainActor
@Suite("WorkspaceStore · apply")
struct WorkspaceStoreApplyTests {

    @Test("apply populates typed arrays from payload")
    func applyPopulates() {
        let store = WorkspaceStore()
        var payload = DocumentPayload.empty
        payload.frames = [
            FrameModel(id: "f1", url: "u1", label: "L1",
                       x: 0, y: 0, w: 100, h: 100, num: 1,
                       isImage: false, filePath: nil).jsonValue,
            FrameModel(id: "f2", url: "u2", label: "L2",
                       x: 50, y: 50, w: 200, h: 200, num: 2,
                       isImage: false, filePath: nil).jsonValue,
        ]
        payload.links = [
            LinkModel(id: "ln1", fromId: "f1", fromSide: .right,
                      toId: "f2", toSide: .left).jsonValue,
        ]
        payload.nextNum = 3
        store.apply(payload)
        #expect(store.frames.count == 2)
        #expect(store.links.count == 1)
        #expect(store.nextFrameNum == 3)
    }

    @Test("apply skips malformed entries without failing")
    func skipsMalformed() {
        let store = WorkspaceStore()
        var payload = DocumentPayload.empty
        payload.frames = [
            FrameModel(id: "f1", url: "u1", label: "L1",
                       x: 0, y: 0, w: 0, h: 0, num: 1,
                       isImage: false, filePath: nil).jsonValue,
            .object(["bogus": .string("no id, no url")]),
            .string("not an object"),
        ]
        store.apply(payload)
        #expect(store.frames.count == 1)
        #expect(store.frames.first?.id == "f1")
    }

    @Test("version increments on each apply")
    func versionIncrements() {
        let store = WorkspaceStore()
        let start = store.version
        store.apply(.empty)
        store.apply(.empty)
        store.apply(.empty)
        #expect(store.version == start + 3)
    }

    @Test("observers fire on apply, and once on registration")
    func observersFire() {
        let store = WorkspaceStore()
        var count = 0
        let sub = store.observe { count += 1 }
        // Registration fires once synchronously.
        #expect(count == 1)
        store.apply(.empty)
        #expect(count == 2)
        store.apply(.empty)
        #expect(count == 3)
        // Keep the subscription alive for the duration of the test — the
        // deinit auto-cancels, and the test would otherwise race a cancel
        // against the last apply.
        _ = sub
    }

    @Test("frame(id:) returns nil for missing frames")
    func frameLookupMissing() {
        let store = WorkspaceStore()
        #expect(store.frame(id: "nope") == nil)
    }

    @Test("annotations(for:) filters by frameId")
    func annotationsFilter() {
        let store = WorkspaceStore()
        var payload = DocumentPayload.empty
        payload.annotations = [
            AnnotationModel(id: "a1", num: 1, frameId: "f1",
                            xPct: 0, yPct: 0, color: "blue", comment: "",
                            resolved: false, edits: [:],
                            frameUrl: nil, frameLabel: nil).jsonValue,
            AnnotationModel(id: "a2", num: 2, frameId: "f2",
                            xPct: 0, yPct: 0, color: "blue", comment: "",
                            resolved: false, edits: [:],
                            frameUrl: nil, frameLabel: nil).jsonValue,
            AnnotationModel(id: "a3", num: 3, frameId: "f1",
                            xPct: 0, yPct: 0, color: "blue", comment: "",
                            resolved: false, edits: [:],
                            frameUrl: nil, frameLabel: nil).jsonValue,
        ]
        store.apply(payload)
        #expect(store.annotations(for: "f1").count == 2)
        #expect(store.annotations(for: "f2").count == 1)
        #expect(store.annotations(for: "f9").isEmpty)
    }


    @Test("serialize round-trips through apply")
    func serializeRoundTrip() {
        let store = WorkspaceStore()
        var payload = DocumentPayload.empty
        payload.name = "Fixture"
        payload.version = 1
        payload.nextNum = 7
        payload.annNext = 3
        payload.frames = [
            fixtureFrame(id: "f1", num: 1).jsonValue,
            fixtureFrame(id: "f2", num: 2).jsonValue,
        ]
        payload.annotations = [
            fixtureAnnotation(id: "a1", frameId: "f1", num: 1).jsonValue,
        ]
        payload.links = [
            LinkModel(id: "ln1", fromId: "f1", fromSide: .right,
                      toId: "f2", toSide: .left).jsonValue,
        ]
        payload.canvas = ViewportModel(scale: 1.5, panX: -30, panY: 60).jsonValue
        store.apply(payload)

        let dumped = store.serialize()
        #expect(dumped.name == payload.name)
        #expect(dumped.version == payload.version)
        #expect(dumped.nextNum == payload.nextNum)
        #expect(dumped.annNext == payload.annNext)
        #expect(dumped.frames.count == payload.frames.count)
        #expect(dumped.annotations.count == payload.annotations.count)
        #expect(dumped.links.count == payload.links.count)

        // Round-trip the dumped payload — field-by-field equality on
        // JSONValue arrays is the easiest shape-check.
        let restored = WorkspaceStore()
        restored.apply(dumped)
        #expect(restored.frames.count == store.frames.count)
        #expect(restored.links.count  == store.links.count)
        #expect(restored.annotations.count == store.annotations.count)
        #expect(restored.viewport == store.viewport)
    }
}

// MARK: - WorkspaceStore · mutations

@MainActor
@Suite("WorkspaceStore · mutations")
struct WorkspaceStoreMutationTests {

    @Test("createFrame appends frame and notifies delegate")
    func createFrameFiresDelegate() {
        let store = WorkspaceStore()
        let delegate = RecordingDelegate()
        store.delegate = delegate
        let frame = fixtureFrame(id: "f1", num: 1)
        let created = store.createFrame(frame)
        #expect(created == frame)
        #expect(store.frames.count == 1)
        if case .frameCreated(let emitted) = delegate.last {
            #expect(emitted == frame)
        } else {
            Issue.record("expected .frameCreated, got \(String(describing: delegate.last))")
        }
    }

    @Test("createFrame rejects duplicate id")
    func createFrameRejectsDuplicate() {
        let store = WorkspaceStore()
        _ = store.createFrame(fixtureFrame(id: "f1", num: 1))
        let dup = store.createFrame(fixtureFrame(id: "f1", num: 2))
        #expect(dup == nil)
        #expect(store.frames.count == 1)
    }

    @Test("moveFrame no-op skips delegate")
    func moveFrameNoOpSkips() {
        let store = WorkspaceStore()
        _ = store.createFrame(fixtureFrame(id: "f1", num: 1))
        let delegate = RecordingDelegate()
        store.delegate = delegate
        // Same origin — no mutation should fire.
        store.moveFrame(id: "f1", to: CGPoint(x: 0, y: 0))
        #expect(delegate.events.isEmpty)
        // Real move — fires with the old origin as baseline for reversal.
        store.moveFrame(id: "f1", to: CGPoint(x: 100, y: 50))
        if case .frameMoved(let id, let oldOrigin) = delegate.last {
            #expect(id == "f1")
            #expect(oldOrigin == CGPoint(x: 0, y: 0))
        } else {
            Issue.record("expected .frameMoved, got \(String(describing: delegate.last))")
        }
    }

    @Test("resizeFrame clamps to at least 1×1")
    func resizeFrameClamps() {
        let store = WorkspaceStore()
        _ = store.createFrame(fixtureFrame(id: "f1", num: 1))
        store.resizeFrame(id: "f1", size: CGSize(width: -50, height: 0))
        let frame = store.frame(id: "f1")
        #expect(frame?.w == 1)
        #expect(frame?.h == 1)
    }

    @Test("renameFrame updates label and emits mutation")
    func renameFrame() {
        let store = WorkspaceStore()
        _ = store.createFrame(fixtureFrame(id: "f1", num: 1))
        let delegate = RecordingDelegate()
        store.delegate = delegate
        store.renameFrame(id: "f1", label: "Renamed")
        #expect(store.frame(id: "f1")?.label == "Renamed")
        if case .frameRenamed(let id) = delegate.last {
            #expect(id == "f1")
        } else {
            Issue.record("expected .frameRenamed")
        }
    }

    @Test("deleteFrame cascades to dependent links and annotations")
    func deleteFrameCascades() {
        let store = WorkspaceStore()
        _ = store.createFrame(fixtureFrame(id: "f1", num: 1))
        _ = store.createFrame(fixtureFrame(id: "f2", num: 2))
        _ = store.createFrame(fixtureFrame(id: "f3", num: 3))
        _ = store.createLink(LinkModel(id: "ln1", fromId: "f1",
                                       fromSide: .right, toId: "f2",
                                       toSide: .left))
        _ = store.createLink(LinkModel(id: "ln2", fromId: "f2",
                                       fromSide: .right, toId: "f3",
                                       toSide: .left))
        _ = store.createAnnotation(fixtureAnnotation(id: "a1",
                                                    frameId: "f2",
                                                    num: 1))
        _ = store.createAnnotation(fixtureAnnotation(id: "a2",
                                                    frameId: "f3",
                                                    num: 2))

        var deleted: WorkspaceMutation?
        let subscription = store.observe { if let m = store.mutationInFlight { deleted = m } }
        store.deleteFrame(id: "f2")
        withExtendedLifetime(subscription) {}

        #expect(store.frame(id: "f2") == nil)
        // Both links touched f2 — should be gone.
        #expect(store.links.map(\.id) == [])
        // a1 belonged to f2 — should be gone. a2 belongs to f3 — untouched.
        #expect(store.annotations.map(\.id) == ["a2"])

        // The mutation carries the frame plus its dependents so the
        // document's undo can rebuild the graph.
        if case .frameDeleted(let f, let anns, let lnks)? = deleted {
            #expect(f.id == "f2")
            #expect(anns.map(\.id) == ["a1"])
            #expect(Set(lnks.map(\.id)) == Set(["ln1", "ln2"]))
        } else {
            Issue.record("expected a .frameDeleted mutation")
        }
    }

    @Test("createLink rejects self, duplicate, and missing-endpoint")
    func createLinkValidation() {
        let store = WorkspaceStore()
        _ = store.createFrame(fixtureFrame(id: "f1", num: 1))
        _ = store.createFrame(fixtureFrame(id: "f2", num: 2))
        // self-link
        #expect(store.createLink(LinkModel(id: "ln1", fromId: "f1",
                                           fromSide: .right, toId: "f1",
                                           toSide: .left)) == nil)
        // missing endpoint
        #expect(store.createLink(LinkModel(id: "ln1", fromId: "f1",
                                           fromSide: .right, toId: "fX",
                                           toSide: .left)) == nil)
        // valid
        #expect(store.createLink(LinkModel(id: "ln1", fromId: "f1",
                                           fromSide: .right, toId: "f2",
                                           toSide: .left)) != nil)
        // duplicate id
        #expect(store.createLink(LinkModel(id: "ln1", fromId: "f2",
                                           fromSide: .right, toId: "f1",
                                           toSide: .left)) == nil)
        #expect(store.links.count == 1)
    }

    @Test("createAnnotation requires parent frame to exist")
    func createAnnotationRequiresFrame() {
        let store = WorkspaceStore()
        #expect(store.createAnnotation(fixtureAnnotation(id: "a1",
                                                        frameId: "missing",
                                                        num: 1)) == nil)
        _ = store.createFrame(fixtureFrame(id: "f1", num: 1))
        #expect(store.createAnnotation(fixtureAnnotation(id: "a1",
                                                        frameId: "f1",
                                                        num: 1)) != nil)
        // duplicate annotation id
        #expect(store.createAnnotation(fixtureAnnotation(id: "a1",
                                                        frameId: "f1",
                                                        num: 2)) == nil)
    }

    @Test("updateAnnotation applies partial updates")
    func updateAnnotationPartial() {
        let store = WorkspaceStore()
        _ = store.createFrame(fixtureFrame(id: "f1", num: 1))
        _ = store.createAnnotation(fixtureAnnotation(id: "a1",
                                                    frameId: "f1",
                                                    num: 1))
        // Only comment.
        store.updateAnnotation(id: "a1", comment: "new comment",
                               color: nil, edits: nil)
        #expect(store.annotations.first?.comment == "new comment")
        #expect(store.annotations.first?.color == "blue") // unchanged
        // Only color.
        store.updateAnnotation(id: "a1", comment: nil, color: "red",
                               edits: nil)
        #expect(store.annotations.first?.color == "red")
        #expect(store.annotations.first?.comment == "new comment") // unchanged
        // Only edits.
        store.updateAnnotation(id: "a1", comment: nil, color: nil,
                               edits: ["font-size": "18px"])
        #expect(store.annotations.first?.edits == ["font-size": "18px"])
    }

    @Test("toggleAnnotationResolved flips and emits previous flag")
    func toggleResolved() {
        let store = WorkspaceStore()
        _ = store.createFrame(fixtureFrame(id: "f1", num: 1))
        _ = store.createAnnotation(fixtureAnnotation(id: "a1",
                                                    frameId: "f1",
                                                    num: 1))
        let delegate = RecordingDelegate()
        store.delegate = delegate
        store.toggleAnnotationResolved(id: "a1")
        #expect(store.annotations.first?.resolved == true)
        if case .annotationResolvedToggled(let id, let was) = delegate.last {
            #expect(id == "a1")
            #expect(was == false)
        } else {
            Issue.record("expected .annotationResolvedToggled")
        }
        store.toggleAnnotationResolved(id: "a1")
        #expect(store.annotations.first?.resolved == false)
    }

    @Test("Explicit comment status is idempotent and survives serialization with color and edits")
    func explicitCommentStatusPersists() {
        let store = WorkspaceStore()
        _ = store.createFrame(fixtureFrame(id: "f1", num: 1))
        var comment = fixtureAnnotation(id: "a1", frameId: "f1", num: 1)
        comment.comment = "Keep the heading aligned"
        comment.edits = ["font-size": "36px"]
        _ = store.createAnnotation(comment)
        let delegate = RecordingDelegate()
        store.delegate = delegate
        store.setAnnotationResolved(id: "a1", resolved: true)
        store.setAnnotationResolved(id: "a1", resolved: true)
        store.setAnnotationResolved(id: "missing", resolved: true)
        #expect(delegate.events.count == 1)
        store.updateAnnotation(id: "a1", comment: nil, color: "purple", edits: nil)
        let restored = WorkspaceStore()
        restored.apply(store.serialize())
        #expect(restored.annotations.first?.resolved == true)
        #expect(restored.annotations.first?.color == "purple")
        #expect(restored.annotations.first?.comment == comment.comment)
        #expect(restored.annotations.first?.edits == comment.edits)
        restored.setAnnotationResolved(id: "a1", resolved: false)
        #expect(restored.annotations.first?.resolved == false)
    }

    @Test("setViewport dedupes unchanged values")
    func setViewportDedupes() {
        let store = WorkspaceStore()
        let delegate = RecordingDelegate()
        store.delegate = delegate
        let vp = ViewportModel(scale: 2, panX: 10, panY: 20)
        store.setViewport(vp)
        // Identical second write — must NOT produce a second event,
        // otherwise pan/zoom renders would amplify into a dirty-flag storm.
        store.setViewport(vp)
        #expect(delegate.events.count == 1)
        store.setViewport(ViewportModel(scale: 2, panX: 11, panY: 20))
        #expect(delegate.events.count == 2)
    }

    @Test("num allocators bump counters and survive serialize")
    func allocators() {
        let store = WorkspaceStore()
        #expect(store.allocateFrameNum() == 1)
        #expect(store.allocateFrameNum() == 2)
        #expect(store.allocateAnnotationNum() == 1)
        #expect(store.allocateAnnotationNum() == 2)
        let dumped = store.serialize()
        #expect(dumped.nextNum == 3)
        #expect(dumped.annNext == 3)
    }

    @Test("every mutation bumps version")
    func mutationsBumpVersion() {
        let store = WorkspaceStore()
        let v0 = store.version
        _ = store.createFrame(fixtureFrame(id: "f1", num: 1))
        #expect(store.version == v0 + 1)
        store.moveFrame(id: "f1", to: CGPoint(x: 10, y: 10))
        #expect(store.version == v0 + 2)
        store.resizeFrame(id: "f1", size: CGSize(width: 400, height: 300))
        #expect(store.version == v0 + 3)
        store.renameFrame(id: "f1", label: "New")
        #expect(store.version == v0 + 4)
    }
}

// MARK: - Helpers

/// Delegate stub that records every mutation event it receives so tests
/// can assert on both count and discriminator without matching inside
/// the closure. Held by tests for the duration of a single store.
@MainActor
final class RecordingDelegate: WorkspaceStoreDelegate {
    var events: [WorkspaceMutation] = []
    var last: WorkspaceMutation? { events.last }
    func workspaceStore(_ store: WorkspaceStore,
                        didApplyMutation mutation: WorkspaceMutation) {
        events.append(mutation)
    }
}

/// Minimal FrameModel fixture with deterministic coordinates. Tests that
/// need specific fields override locally; this keeps the mutation-suite
/// setup noise-free.
func fixtureFrame(id: String, num: Int) -> FrameModel {
    FrameModel(
        id: id, url: "https://example.com", label: "L\(num)",
        x: 0, y: 0, w: 200, h: 100, num: num,
        isImage: false, filePath: nil
    )
}

/// Minimal AnnotationModel fixture. `color` defaults to the same "blue"
/// that JS uses, so tests checking for colour change have a stable
/// baseline.
func fixtureAnnotation(id: String, frameId: String, num: Int) -> AnnotationModel {
    AnnotationModel(
        id: id, num: num, frameId: frameId,
        xPct: 0.5, yPct: 0.5,
        color: "blue", comment: "",
        resolved: false, edits: [:],
        frameUrl: nil, frameLabel: nil
    )
}

// MARK: - Area comments

@Suite("Area comments")
struct AreaCommentTests {

    private func annotation(extras: [String: JSONValue]) -> AnnotationModel {
        AnnotationModel(id: "a1", num: 1, frameId: "f1", xPct: 10, yPct: 40, color: "blue",
                        comment: "", resolved: false, edits: [:], frameUrl: nil, frameLabel: nil, extras: extras)
    }

    @Test func areaSizeRoundTripsThroughJSON() {
        var a = annotation(extras: [:])
        #expect(a.areaSizePct == nil)
        a.areaSizePct = CGSize(width: 30, height: 20)
        let back = AnnotationModel(jsonValue: a.jsonValue)
        #expect(back?.areaSizePct == CGSize(width: 30, height: 20))
        a.areaSizePct = nil
        guard case .object(let o) = a.jsonValue else { Issue.record("expected .object"); return }
        #expect(o["area"] == nil)
    }

    @Test func pinModelCarriesArea() {
        var a = annotation(extras: [:])
        #expect(PinModel.from(a).hasArea == false)
        a.areaSizePct = CGSize(width: 30, height: 20)
        let pin = PinModel.from(a)
        #expect(pin.hasArea)
        #expect(pin.areaWPct == 30)
        #expect(pin.areaHPct == 20)
    }

    @Test func areaSummaryDescribesRegionAndContents() {
        let a = annotation(extras: ["element": .object([
            "area": .object(["x": .number(128), "y": .number(320), "width": .number(384), "height": .number(160)]),
            "areaElements": .array([.object(["selector": .string("div.card"), "text": .string("Revenue")])]),
        ])])
        #expect(a.areaSummary == "region x 128, y 320, 384×160 CSS px of the viewport; contains div.card \"Revenue\"")
        #expect(annotation(extras: [:]).areaSummary == nil)
    }
}
