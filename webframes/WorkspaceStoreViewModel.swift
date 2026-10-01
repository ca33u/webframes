import AppKit
import Foundation

// MARK: - Workspace → native UI converters
//
// Phase 6e Step 0 plumbing. `CanvasHost` subscribes to `WorkspaceStore`
// and, on every mutation, runs the authoritative Swift state through
// the converters below to rebuild the three diff-reconciled UI feeds:
//
//   * `[AnnotationInfo]`       → AnnotationPanel.setAnnotations
//   * `[String: [PinModel]]`   → FrameManager.setPins(frameId:pins:)
//   * `[NativeLink]`           → LinkLayerView.setLinks
//
// The JS push paths (`pushAnnotationsToNative`, `pushPinsToAllFrames`,
// `pushLinksToNative`) still run in parallel through this step —
// they're the authoritative UI driver until Step C of Phase 6e removes
// the JS round-trip. Running both is deliberate: the two paths produce
// identical outputs, and the downstream reconcilers (`setAnnotations`,
// `setPins`, `setLinks` — all diff-based) absorb the duplicate writes
// as no-ops. When the JS path comes out, the observer path keeps
// driving the UI unchanged.
//
// Conversion logic is ported verbatim from the JS serializers in
// `Renderer/index.html`:
//   * `serializeAnnotations`  (line 1911)
//   * `pushPinsToAllFrames`   (line 1852)
//   * `pushLinksToNative`     (line 1883) + `frameAnchor` (line 346)
//
// A 1px geometry drift here would detach rendered arrows from frame
// chrome during the parallel phase — constants mirror the JS source
// exactly (2px of border width, 35px of titlebar height).

// MARK: AnnotationInfo

extension AnnotationInfo {

    /// Convert a workspace annotation into the panel-facing row struct.
    ///
    /// `frame` is the annotation's current frame, or `nil` if the pin
    /// outlived its frame (possible during a delete cascade mid-flight,
    /// or if stored state was tampered with on disk). The fallback chain
    /// handles the orphan case — see `frameLabel` below.
    ///
    /// The `screenshot` field is always populated when the underlying
    /// annotation has one — `AnnotationPanel` owns the screenshots-on/off
    /// toggle (`screenshotsEnabled` private var) and gates display
    /// internally via `AnnotationItemView(showScreenshot:)`. That keeps
    /// the observer path free of a per-push re-serialization when the
    /// user flips the checkbox.
    static func from(
        annotation a: AnnotationModel,
        frame fr: FrameModel?
    ) -> AnnotationInfo {
        // frameLabel preference chain matches serializeAnnotations():
        //   live frame.label  →  ann.frameLabel  →  ann.frameUrl  →  "page"
        // Prefer the live label because the user may have renamed the
        // frame after the pin was dropped; the stored `frameLabel` is
        // just a snapshot from creation time, useful only as a fallback.
        let frameLabel: String
        if let liveLabel = fr?.label, !liveLabel.isEmpty {
            frameLabel = liveLabel
        } else if let stored = a.frameLabel, !stored.isEmpty {
            frameLabel = stored
        } else if let url = a.frameUrl, !url.isEmpty {
            frameLabel = url
        } else {
            frameLabel = "page"
        }

        // Viewport "{w}×{h}" against the *current* frame size — matches
        // the JS which reads `fr.w` / `fr.h` at serialize time, not at
        // drop time. Rendered widths are integer CSS pixels in JS so we
        // round here to keep the string identical across the two paths.
        let viewport: String?
        if let fr {
            let w = Int(fr.w.rounded())
            let h = Int(fr.h.rounded())
            viewport = "\(w)×\(h)"
        } else {
            viewport = nil
        }

        // `element` is a JS-owned DOM snapshot stored as a JSONValue
        // object inside `AnnotationModel.extras`. Round-trip preservation
        // lives on the model (see AnnotationModel.extras note) — here we
        // just read the fields we need without taking ownership of the
        // shape. Missing extras → "—" selector, nil screenshot, matching
        // serializeAnnotations's `a.element?.x || '—'` chain.
        var selector = "—"
        var screenshot: NSImage?
        if case .object(let element) = a.extras["element"] ?? .null {
            func str(_ k: String) -> String? {
                if case .string(let s) = element[k] ?? .null, !s.isEmpty {
                    return s
                }
                return nil
            }
            selector = str("selector") ?? str("path") ?? str("tagName") ?? "—"
            if let dataURL = str("screenshot"),
               let comma = dataURL.firstIndex(of: ","),
               let data = Data(
                base64Encoded: String(dataURL[dataURL.index(after: comma)...])
               ) {
                screenshot = NSImage(data: data)
            }
        }

        // JS emits `Object.keys(a.edits)` in insertion order. Swift
        // dictionaries are unordered, so we sort here for deterministic
        // output — the chip row is a passive label strip with no stable
        // ordering contract on either side, and sorted keys make tests
        // reproducible without sacrificing user experience.
        let editKeys = Array(a.edits.keys).sorted()

        return AnnotationInfo(
            id: a.id,
            num: a.num,
            color: a.color,
            comment: a.comment,
            resolved: a.resolved,
            frameLabel: frameLabel,
            viewport: viewport,
            selector: selector,
            screenshot: screenshot,
            resolutionNote: a.extras["resolvedBy"].flatMap { if case .string(let actor) = $0 { return (a.resolved ? "Resolved by " : "Reopened by ") + actor }; return nil },
            editKeys: editKeys
        )
    }
}

// MARK: PinModel

extension PinModel {

    /// Convert an annotation into its per-frame pin-overlay representation.
    ///
    /// `initialScrollX` / `initialScrollY` are the scroll offset captured
    /// at pin-drop time so the dot tracks the element it was dropped on
    /// as the user scrolls the frame's web content. They live in the
    /// JS-owned `extras` bag (AnnotationModel doesn't type them because
    /// Swift doesn't interpret the value — it just preserves it through
    /// the JSON round-trip).
    static func from(_ a: AnnotationModel) -> PinModel {
        func num(_ k: String) -> CGFloat {
            if case .number(let n) = a.extras[k] ?? .null {
                return CGFloat(n)
            }
            return 0
        }
        return PinModel(
            id: a.id,
            num: a.num,
            color: a.color,
            xPct: a.xPct,
            yPct: a.yPct,
            initialScrollX: num("initialScrollX"),
            initialScrollY: num("initialScrollY"),
            areaWPct: a.areaSizePct?.width ?? 0,
            areaHPct: a.areaSizePct?.height ?? 0
        )
    }
}

// MARK: NativeLink

extension NativeLink {

    /// Convert a link + its two resolved endpoint frames into the renderer
    /// struct. Caller supplies selection / hover state from whatever
    /// source owns link picking today — as of Phase 6e Step 2 that's
    /// `CanvasHost.selectedLinkId` / `hoveredLinkId`, populated from the
    /// native `LinkLayerView` hit-testing. Both the workspace observer
    /// path and the JS `links-set` envelope read from the same host
    /// properties, so whichever path fires last produces consistent
    /// flags.
    static func from(
        link: LinkModel,
        fromFrame: FrameModel,
        toFrame: FrameModel,
        selected: Bool,
        hovered: Bool
    ) -> NativeLink {
        let inferred = link.id.hasPrefix("map-edge-")
        let effectiveFromSide: LinkSide = inferred ? .bottom : link.fromSide
        let effectiveToSide: LinkSide = inferred ? .bottom : link.toSide
        let fromAnchor = frameAnchor(fromFrame, side: effectiveFromSide)
        let toAnchor   = frameAnchor(toFrame, side: effectiveToSide)
        return NativeLink(
            id: link.id,
            from: fromAnchor,
            fromSide: effectiveFromSide,
            to: toAnchor,
            toSide: effectiveToSide,
            selected: selected,
            // JS `pushLinksToNative` flattens selection-wins on top of
            // hover so the renderer never sees both flags lit. Mirror
            // the flatten here — LinkLayerView draws `.hovered` tint
            // only when `!selected && hovered`, same as before.
            hovered: !selected && hovered,
            bends: inferred ? nil : link.bends
        )
    }
}

// MARK: frameAnchor

/// World-space anchor for a link endpoint against the given frame edge.
///
/// Ported from `frameAnchor(f, side)` at index.html:346. Must match the
/// JS geometry exactly — a 1pt drift here detaches rendered arrows from
/// frame chrome at the endpoint. Constants are:
///
///   * `totalW = f.w + 2`    — 2px card border on the x-axis
///   * `totalH = f.h + 35`   — 35pt titlebar stripe on the y-axis
///
/// Top-left is `(f.x, f.y)`; edges read:
///   left   → mid-left    of the card including border + titlebar
///   right  → mid-right
///   top    → top-center  (on the titlebar edge)
///   bottom → bottom-center (on the card bottom border)
func frameAnchor(_ f: FrameModel, side: LinkSide) -> CGPoint {
    let totalW = f.w + CardGeometry.chromeWidth
    let totalH = f.h + CardGeometry.chromeHeight
    switch side {
    case .left:
        return CGPoint(x: f.x,                  y: f.y + totalH / 2)
    case .right:
        return CGPoint(x: f.x + totalW,         y: f.y + totalH / 2)
    case .top:
        return CGPoint(x: f.x + totalW / 2,     y: f.y)
    case .bottom:
        return CGPoint(x: f.x + totalW / 2,     y: f.y + totalH)
    }
}
