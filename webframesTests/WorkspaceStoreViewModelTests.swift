//
//  WorkspaceStoreViewModelTests.swift
//  webframesTests
//
//  Tests for the Phase 6e Step 0 converters that translate authoritative
//  Swift workspace models into the three native-UI view feeds:
//
//    AnnotationModel + FrameModel?  →  AnnotationInfo   (panel)
//    AnnotationModel                →  PinModel         (per-frame overlay)
//    LinkModel + two FrameModels    →  NativeLink       (bezier renderer)
//
//  Plus the ported `frameAnchor(_:side:)` geometry helper.
//
//  These converters are ported verbatim from the JS serializers in
//  `Renderer/index.html` (`serializeAnnotations`, `pushPinsToAllFrames`,
//  `pushLinksToNative`, `frameAnchor`). The tests lock down that parity:
//  each input fixture has a hand-computed "this is exactly what the JS
//  side would emit" expected value. If the JS serializer drifts (constant
//  changes, new fallback chain, etc.) these tests will red-flag it.
//
//  The converters are pure functions (no actor isolation), so the suite
//  doesn't need `@MainActor` — unlike WorkspaceModelsTests which does.
//

import Foundation
import CoreGraphics
import AppKit
import Testing
@testable import Web_Frames

// MARK: - AnnotationInfo.from(annotation:frame:)

@Suite("AnnotationInfo · from(annotation:frame:)")
struct AnnotationInfoFromTests {

    @Test("preserves typed fields verbatim")
    func typedFieldsVerbatim() {
        let fr = fixtureFrame(id: "f1", num: 1)
        let a = AnnotationModel(
            id: "a1", num: 7, frameId: "f1",
            xPct: 0.25, yPct: 0.75,
            color: "amber", comment: "hi",
            resolved: true, edits: [:],
            frameUrl: nil, frameLabel: nil
        )
        let info = AnnotationInfo.from(annotation: a, frame: fr)
        #expect(info.id == "a1")
        #expect(info.num == 7)
        #expect(info.color == "amber")
        #expect(info.comment == "hi")
        #expect(info.resolved == true)
    }

    @Test("frameLabel prefers live frame.label over stored snapshot")
    func frameLabelPrefersLive() {
        // User renamed the frame after the pin was dropped. Observer path
        // should pick up the new label, not the stale snapshot.
        var fr = fixtureFrame(id: "f1", num: 1)
        fr.label = "new name"
        let a = AnnotationModel(
            id: "a1", num: 1, frameId: "f1",
            xPct: 0, yPct: 0,
            color: "blue", comment: "",
            resolved: false, edits: [:],
            frameUrl: "https://old.example", frameLabel: "old name"
        )
        let info = AnnotationInfo.from(annotation: a, frame: fr)
        #expect(info.frameLabel == "new name")
    }

    @Test("frameLabel falls back to stored frameLabel if live label is empty")
    func frameLabelFallbackToStored() {
        var fr = fixtureFrame(id: "f1", num: 1)
        fr.label = ""  // user blanked it out
        let a = AnnotationModel(
            id: "a1", num: 1, frameId: "f1",
            xPct: 0, yPct: 0,
            color: "blue", comment: "",
            resolved: false, edits: [:],
            frameUrl: "https://old.example", frameLabel: "snapshot"
        )
        let info = AnnotationInfo.from(annotation: a, frame: fr)
        #expect(info.frameLabel == "snapshot")
    }

    @Test("frameLabel falls back to frameUrl if both labels are absent")
    func frameLabelFallbackToURL() {
        let a = AnnotationModel(
            id: "a1", num: 1, frameId: "gone",
            xPct: 0, yPct: 0,
            color: "blue", comment: "",
            resolved: false, edits: [:],
            frameUrl: "https://snap", frameLabel: nil
        )
        // `frame: nil` simulates the orphan case (pin outlived its frame).
        let info = AnnotationInfo.from(annotation: a, frame: nil)
        #expect(info.frameLabel == "https://snap")
    }

    @Test("frameLabel defaults to \"page\" when all sources are empty")
    func frameLabelDefaultsToPage() {
        let a = AnnotationModel(
            id: "a1", num: 1, frameId: "gone",
            xPct: 0, yPct: 0,
            color: "blue", comment: "",
            resolved: false, edits: [:],
            frameUrl: nil, frameLabel: nil
        )
        let info = AnnotationInfo.from(annotation: a, frame: nil)
        #expect(info.frameLabel == "page")
    }

    @Test("viewport reads current frame dimensions, not drop-time snapshot")
    func viewportReadsCurrentFrame() {
        var fr = fixtureFrame(id: "f1", num: 1)
        fr.w = 1440
        fr.h = 900
        let a = fixtureAnnotation(id: "a1", frameId: "f1", num: 1)
        let info = AnnotationInfo.from(annotation: a, frame: fr)
        #expect(info.viewport == "1440×900")
    }

    @Test("viewport is nil when the frame is gone")
    func viewportNilWhenOrphan() {
        let a = fixtureAnnotation(id: "a1", frameId: "gone", num: 1)
        let info = AnnotationInfo.from(annotation: a, frame: nil)
        #expect(info.viewport == nil)
    }

    @Test("selector pulls from element.selector first")
    func selectorPrefersSelector() {
        var a = fixtureAnnotation(id: "a1", frameId: "f1", num: 1)
        a.extras["element"] = .object([
            "selector": .string("#hero > button"),
            "path":     .string("body > div > button"),
            "tagName":  .string("BUTTON"),
        ])
        let info = AnnotationInfo.from(annotation: a, frame: nil)
        #expect(info.selector == "#hero > button")
    }

    @Test("selector falls back to path when selector missing")
    func selectorFallbackToPath() {
        var a = fixtureAnnotation(id: "a1", frameId: "f1", num: 1)
        a.extras["element"] = .object([
            "path":    .string("body > div"),
            "tagName": .string("DIV"),
        ])
        let info = AnnotationInfo.from(annotation: a, frame: nil)
        #expect(info.selector == "body > div")
    }

    @Test("selector falls back to tagName when path missing")
    func selectorFallbackToTagName() {
        var a = fixtureAnnotation(id: "a1", frameId: "f1", num: 1)
        a.extras["element"] = .object([
            "tagName": .string("BUTTON"),
        ])
        let info = AnnotationInfo.from(annotation: a, frame: nil)
        #expect(info.selector == "BUTTON")
    }

    @Test("selector defaults to \"—\" when element extras missing entirely")
    func selectorDefault() {
        let a = fixtureAnnotation(id: "a1", frameId: "f1", num: 1)
        let info = AnnotationInfo.from(annotation: a, frame: nil)
        #expect(info.selector == "—")
    }

    @Test("empty string fields are skipped in the selector fallback chain")
    func selectorSkipsEmptyStrings() {
        // JS `a.element?.selector || a.element?.path || ...` treats empty
        // string as falsy — the Swift port must do the same, else a bug
        // would render " " or "" in place of the expected fallback.
        var a = fixtureAnnotation(id: "a1", frameId: "f1", num: 1)
        a.extras["element"] = .object([
            "selector": .string(""),
            "path":     .string(""),
            "tagName":  .string("IMG"),
        ])
        let info = AnnotationInfo.from(annotation: a, frame: nil)
        #expect(info.selector == "IMG")
    }

    @Test("screenshot is populated when element.screenshot is a data-URL")
    func screenshotDecoded() {
        // 1×1 transparent PNG — shortest data URL that actually decodes.
        // Generated once so the test fixture is self-contained.
        let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgAAIAAAUAAeImBZsAAAAASUVORK5CYII="
        let dataURL = "data:image/png;base64,\(pixel)"
        var a = fixtureAnnotation(id: "a1", frameId: "f1", num: 1)
        a.extras["element"] = .object([
            "selector":   .string("img"),
            "screenshot": .string(dataURL),
        ])
        let info = AnnotationInfo.from(annotation: a, frame: nil)
        #expect(info.screenshot != nil)
    }

    @Test("screenshot is nil when absent — panel gates display itself")
    func screenshotNilWhenAbsent() {
        let a = fixtureAnnotation(id: "a1", frameId: "f1", num: 1)
        let info = AnnotationInfo.from(annotation: a, frame: nil)
        #expect(info.screenshot == nil)
    }

    @Test("editKeys lists sorted keys from the edits dict")
    func editKeysSorted() {
        var a = fixtureAnnotation(id: "a1", frameId: "f1", num: 1)
        a.edits = [
            "color": "red",
            "background": "blue",
            "font-size": "14px",
        ]
        let info = AnnotationInfo.from(annotation: a, frame: nil)
        #expect(info.editKeys == ["background", "color", "font-size"])
    }

    @Test("editKeys is empty when edits map is empty")
    func editKeysEmpty() {
        let a = fixtureAnnotation(id: "a1", frameId: "f1", num: 1)
        let info = AnnotationInfo.from(annotation: a, frame: nil)
        #expect(info.editKeys.isEmpty)
    }
}

// MARK: - PinModel.from(_:)

@Suite("PinModel · from(_:)")
struct PinModelFromTests {

    @Test("basic fields copied")
    func basicFields() {
        let a = AnnotationModel(
            id: "a1", num: 3, frameId: "f1",
            xPct: 0.1, yPct: 0.9,
            color: "red", comment: "",
            resolved: false, edits: [:],
            frameUrl: nil, frameLabel: nil
        )
        let pin = PinModel.from(a)
        #expect(pin.id == "a1")
        #expect(pin.num == 3)
        #expect(pin.color == "red")
        #expect(pin.xPct == 0.1)
        #expect(pin.yPct == 0.9)
    }

    @Test("initialScrollX/Y pulled from extras")
    func initialScrollFromExtras() {
        var a = fixtureAnnotation(id: "a1", frameId: "f1", num: 1)
        a.extras["initialScrollX"] = .number(42)
        a.extras["initialScrollY"] = .number(128)
        let pin = PinModel.from(a)
        #expect(pin.initialScrollX == 42)
        #expect(pin.initialScrollY == 128)
    }

    @Test("missing initialScroll* default to zero")
    func initialScrollDefaultZero() {
        let a = fixtureAnnotation(id: "a1", frameId: "f1", num: 1)
        let pin = PinModel.from(a)
        #expect(pin.initialScrollX == 0)
        #expect(pin.initialScrollY == 0)
    }

    @Test("non-number extras for initialScroll* default to zero")
    func initialScrollNonNumber() {
        // If the extras bag holds a string or other non-number (shouldn't
        // happen in practice but the JSON is untyped), default to zero —
        // matches JS `a.initialScrollX || 0`.
        var a = fixtureAnnotation(id: "a1", frameId: "f1", num: 1)
        a.extras["initialScrollX"] = .string("nope")
        a.extras["initialScrollY"] = .bool(true)
        let pin = PinModel.from(a)
        #expect(pin.initialScrollX == 0)
        #expect(pin.initialScrollY == 0)
    }
}

// MARK: - frameAnchor

@Suite("frameAnchor(_:side:)")
struct FrameAnchorTests {

    // Fixture frame at (100, 200) with a 300×150 content area. `frameAnchor`
    // uses `totalW = w + 2` (2px border) and `totalH = h + 35` (35pt
    // titlebar), so the card spans x: 100…402, y: 200…385.
    private func fixture() -> FrameModel {
        FrameModel(id: "f1", url: "u", label: "L",
                   x: 100, y: 200, w: 300, h: 150, num: 1,
                   isImage: false, filePath: nil)
    }

    @Test("right side: mid-right of the card including border")
    func rightAnchor() {
        let p = frameAnchor(fixture(), side: .right)
        #expect(p.x == 402)   // 100 + (300 + 2)
        #expect(p.y == 292.5) // 200 + (150 + 35) / 2
    }

    @Test("left side: mid-left at the x origin")
    func leftAnchor() {
        let p = frameAnchor(fixture(), side: .left)
        #expect(p.x == 100)
        #expect(p.y == 292.5)
    }

    @Test("top side: top-center on the titlebar edge (y == f.y)")
    func topAnchor() {
        let p = frameAnchor(fixture(), side: .top)
        #expect(p.x == 251) // 100 + (300 + 2) / 2
        #expect(p.y == 200) // f.y
    }

    @Test("bottom side: bottom-center on the card bottom border")
    func bottomAnchor() {
        let p = frameAnchor(fixture(), side: .bottom)
        #expect(p.x == 251)
        #expect(p.y == 385) // 200 + (150 + 35)
    }
}

// MARK: - NativeLink.from(link:fromFrame:toFrame:selected:hovered:)

@Suite("NativeLink · from(link:fromFrame:toFrame:selected:hovered:)")
struct NativeLinkFromTests {

    private func fromFrame() -> FrameModel {
        FrameModel(id: "f1", url: "u1", label: "L1",
                   x: 0, y: 0, w: 100, h: 50, num: 1,
                   isImage: false, filePath: nil)
    }

    private func toFrame() -> FrameModel {
        FrameModel(id: "f2", url: "u2", label: "L2",
                   x: 500, y: 400, w: 100, h: 50, num: 2,
                   isImage: false, filePath: nil)
    }

    @Test("anchors computed via frameAnchor on both ends")
    func anchorsComputed() {
        let link = LinkModel(id: "ln1", fromId: "f1", fromSide: .right,
                             toId: "f2", toSide: .left)
        let nl = NativeLink.from(link: link,
                                 fromFrame: fromFrame(),
                                 toFrame: toFrame(),
                                 selected: false, hovered: false)
        // f1 right-anchor: (0+102, 0+(50+35)/2) = (102, 42.5)
        #expect(nl.from.x == 102)
        #expect(nl.from.y == 42.5)
        // f2 left-anchor: (500, 400+42.5) = (500, 442.5)
        #expect(nl.to.x == 500)
        #expect(nl.to.y == 442.5)
    }

    @Test("preserves link id and side metadata")
    func preservesMetadata() {
        let link = LinkModel(id: "ln1", fromId: "f1", fromSide: .bottom,
                             toId: "f2", toSide: .top)
        let nl = NativeLink.from(link: link,
                                 fromFrame: fromFrame(),
                                 toFrame: toFrame(),
                                 selected: false, hovered: false)
        #expect(nl.id == "ln1")
        #expect(nl.fromSide == .bottom)
        #expect(nl.toSide == .top)
    }

    @Test("selection wins over hover — matches JS flatten")
    func selectionFlattensHover() {
        // JS `pushLinksToNative` emits `hovered: !isSelected && l.id === hoveredLinkId`
        // so both flags never ship lit simultaneously. A regression here
        // would mean selected links paint the hover tint instead of the
        // selection ring.
        let link = LinkModel(id: "ln1", fromId: "f1", fromSide: .right,
                             toId: "f2", toSide: .left)
        let nl = NativeLink.from(link: link,
                                 fromFrame: fromFrame(),
                                 toFrame: toFrame(),
                                 selected: true, hovered: true)
        #expect(nl.selected == true)
        #expect(nl.hovered == false)
    }

    @Test("hover shows through when not selected")
    func hoverShowsWhenUnselected() {
        let link = LinkModel(id: "ln1", fromId: "f1", fromSide: .right,
                             toId: "f2", toSide: .left)
        let nl = NativeLink.from(link: link,
                                 fromFrame: fromFrame(),
                                 toFrame: toFrame(),
                                 selected: false, hovered: true)
        #expect(nl.selected == false)
        #expect(nl.hovered == true)
    }
}
