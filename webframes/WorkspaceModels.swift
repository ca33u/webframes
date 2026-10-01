import Foundation
import CoreGraphics

// MARK: - WorkspaceModels
//
// Typed Swift mirrors of the workspace state that still lives authoritatively
// in the canvas JS (`frames[]`, `links[]`, `annotations[]`, `scale/px/py`).
// Phase 6d will flip the source-of-truth to Swift; these models are the
// foundation for that flip — additive today, used by `WorkspaceStore` as a
// shadow copy that's kept in sync by `NativeBridge.applyDocStateChanged`.
//
// Design choices:
//
//  * Structs, not classes — workspace state is value-semantic; mutations
//    should be explicit (`store.apply(…)`) rather than aliased references.
//  * Optional fields are declared optional only where JS genuinely treats
//    them as optional (e.g. `isImage`, `filePath`, `comment`). Non-optional
//    fields have safe defaults so decode from a half-filled JSONValue can't
//    throw — see `init(jsonValue:)` below.
//  * Every model round-trips through `JSONValue` so it plugs into the
//    existing `DocumentPayload` serialization without changing on-disk
//    format. No schema migration required.

// MARK: Frame

/// One iframe card on the canvas. Mirrors the JS `frames[]` entry.
///
/// Field shape follows what the JS actually stores. Extra fields that only
/// exist for in-memory transient state (e.g. the `element` captured-DOM-node
/// on an annotation) are intentionally not mirrored.
///
/// Forward-compat note
/// -------------------
/// Image frames carry JS-only fields Swift doesn't interpret (`imgUrl` —
/// a data-URL or object-URL for the bitmap, `natW` / `natH` — the natural
/// pixel dimensions used to compute aspect ratio on resize). Swift has no
/// need to look at them, but we MUST preserve them through the typed-model
/// ↔ JSON round-trip — otherwise every Swift-side mutation strips them
/// from sibling frames, wiping out the `<img>` source and breaking resize
/// aspect-lock. Same pattern as `AnnotationModel.extras`.
///
/// `extras` holds any JSON fields not enumerated in `typedKeys` below.
/// Parse fills it with everything that isn't a known key; serialize emits
/// `extras` first and then overwrites with known typed fields, so typed
/// values always win when a key appears in both. Same rules as on
/// `AnnotationModel` — kept symmetrical so future catchall additions slot
/// in consistently.
struct FrameModel: Hashable {
    /// Stable frame id. JS generates these as `"f" + Date.now() + Math.random()`
    /// for user-created frames; document-restored frames carry whatever id
    /// was on disk. Treated as opaque everywhere.
    var id: String
    /// Navigation URL. `file:///` for local files dropped from disk,
    /// `wf-github://…` for GitHub files, plain `https://` otherwise.
    var url: String
    /// Display label shown in the frame's titlebar. Derived by JS from the
    /// URL at create-time; user can edit.
    var label: String
    /// Frame position in canvas-world coordinates (pre-viewport transform).
    var x: CGFloat
    var y: CGFloat
    /// Frame size in canvas-world units. Resize is driven by `ResizeGripView`
    /// which writes world-space dimensions directly.
    var w: CGFloat
    var h: CGFloat
    /// Sequential frame number shown in the card header ("#1", "#2", …).
    /// Independent of creation order because deletions don't renumber.
    var num: Int
    /// True if this is an image-frame (PNG/JPG etc. dropped on the canvas)
    /// rather than a web iframe. Image frames skip URL load and render the
    /// dropped file via `<img>`.
    var isImage: Bool
    /// Sandbox-accessible path for image frames. Nil for web frames.
    var filePath: String?
    /// Opaque passthrough for JS-owned frame fields Swift doesn't interpret
    /// (`imgUrl` / `natW` / `natH` on image frames, plus any future
    /// additions). Defaults to empty so existing call sites that use the
    /// synthesized memberwise init don't need to pass it. See the type-level
    /// note for rationale.
    var extras: [String: JSONValue] = [:]
}

extension FrameModel {
    /// Keys enumerated as typed properties above. Parse subtracts this set
    /// from the incoming JSON object to populate `extras`, and serialize
    /// writes typed properties last so they always win over any stale
    /// carryover in `extras`.
    fileprivate static let typedKeys: Set<String> = [
        "id", "url", "label", "x", "y", "w", "h", "num", "isImage", "filePath",
    ]

    init?(jsonValue: JSONValue) {
        guard case .object(let o) = jsonValue,
              case .string(let id)    = o["id"]    ?? .null,
              case .string(let url)   = o["url"]   ?? .null else { return nil }
        self.id = id
        self.url = url
        self.label    = FrameModel.string(o["label"]) ?? ""
        self.x        = CGFloat(FrameModel.number(o["x"]) ?? 0)
        self.y        = CGFloat(FrameModel.number(o["y"]) ?? 0)
        self.w        = CGFloat(FrameModel.number(o["w"]) ?? 0)
        self.h        = CGFloat(FrameModel.number(o["h"]) ?? 0)
        self.num      = Int(FrameModel.number(o["num"]) ?? 0)
        self.isImage  = FrameModel.bool(o["isImage"]) ?? false
        self.filePath = FrameModel.string(o["filePath"])
        // Everything else falls into extras — covers `imgUrl`, `natW`,
        // `natH` on image frames and any future JS-added fields Swift
        // doesn't know about yet.
        var rest: [String: JSONValue] = [:]
        for (k, v) in o where !FrameModel.typedKeys.contains(k) {
            rest[k] = v
        }
        self.extras = rest
    }

    var jsonValue: JSONValue {
        // Start with extras so typed fields below can overwrite any
        // stale carryover (shouldn't happen since extras filters them on
        // parse, but makes the invariant "typed wins" syntactically true).
        var o: [String: JSONValue] = extras
        o["id"]    = .string(id)
        o["url"]   = .string(url)
        o["label"] = .string(label)
        o["x"]     = .number(Double(x))
        o["y"]     = .number(Double(y))
        o["w"]     = .number(Double(w))
        o["h"]     = .number(Double(h))
        o["num"]   = .number(Double(num))
        // Preserve the asymmetric on-disk shape: `isImage` is emitted only
        // when true, `filePath` only when non-nil. Matters for schema
        // stability — web frames that never held these keys shouldn't
        // start carrying them after a round-trip through Swift.
        if isImage       { o["isImage"]  = .bool(true) }
        else             { o.removeValue(forKey: "isImage") }
        if let p = filePath { o["filePath"] = .string(p) }
        else                { o.removeValue(forKey: "filePath") }
        return .object(o)
    }

    // MARK: small helpers

    fileprivate static func string(_ v: JSONValue?) -> String? {
        if case .string(let s) = v { return s } else { return nil }
    }
    fileprivate static func number(_ v: JSONValue?) -> Double? {
        if case .number(let n) = v { return n } else { return nil }
    }
    fileprivate static func bool(_ v: JSONValue?) -> Bool? {
        if case .bool(let b) = v { return b } else { return nil }
    }
}

// MARK: Link

// `LinkSide` is defined once in `LinkLayerView.swift` (String raw-value enum
// over {left, right, top, bottom}) — reused here rather than redeclared so
// there's a single source of truth across the bridge envelope, link renderer,
// and workspace model. Hashable is automatic for String raw-value enums;
// the extension below just adds a couple of workspace-model helpers.
extension LinkSide {
    static let defaultFrom: LinkSide = .right
    static let defaultTo:   LinkSide = .left

    /// All four sides in the order JS emits them. Hand-rolled instead of
    /// `CaseIterable` because the base enum lives in `LinkLayerView.swift`
    /// and adding `: CaseIterable` there cross-cuts the link renderer's
    /// type declarations — a small static array here is cleaner and won't
    /// drift because the enum itself is sealed (closed set of four sides).
    static let all: [LinkSide] = [.left, .right, .top, .bottom]
}

/// Directed bezier arrow between two frames. JS stores `{id?, fromId,
/// fromSide?, toId, toSide?}` — sides default to right/left if absent, id
/// defaults to a timestamped random string.
struct LinkModel: Hashable {
    var id: String
    var fromId: String
    var fromSide: LinkSide
    var toId: String
    var toSide: LinkSide
    /// Fields written by a newer Web Frames; carried through untouched.
    /// "bends" holds user-placed segment coordinates (world units).
    var extras: [String: JSONValue] = [:]

    var bends: [CGFloat]? {
        guard case .array(let values)? = extras["bends"] else { return nil }
        let numbers = values.compactMap { value -> CGFloat? in
            if case .number(let n) = value { return CGFloat(n) } else { return nil }
        }
        return numbers.isEmpty ? nil : numbers
    }
}

extension LinkModel {
    init?(jsonValue: JSONValue) {
        guard case .object(let o) = jsonValue,
              case .string(let from) = o["fromId"] ?? .null,
              case .string(let to)   = o["toId"]   ?? .null else { return nil }
        self.fromId   = from
        self.toId     = to
        self.id       = FrameModel.string(o["id"]) ?? "ln\(from)-\(to)"
        self.fromSide = FrameModel.string(o["fromSide"]).flatMap(LinkSide.init(rawValue:)) ?? .defaultFrom
        self.toSide   = FrameModel.string(o["toSide"]).flatMap(LinkSide.init(rawValue:)) ?? .defaultTo
        self.extras   = o.filter { !["id", "fromId", "fromSide", "toId", "toSide"].contains($0.key) }
    }

    var jsonValue: JSONValue {
        var o = extras
        o["id"] = .string(id)
        o["fromId"] = .string(fromId)
        o["fromSide"] = .string(fromSide.rawValue)
        o["toId"] = .string(toId)
        o["toSide"] = .string(toSide.rawValue)
        return .object(o)
    }
}

// MARK: Annotation

/// One pin/annotation dropped onto a frame. Mirrors the JS `annotations[]`
/// entry. A lot of fields are optional because the on-disk payload is filled
/// in progressively — a fresh pin has only id/frameId/xPct/yPct/num, and the
/// pin-editor save layer fills comment/color/edits afterward.
///
/// Forward-compat note
/// -------------------
/// The JS side stores richer-than-Swift-knows state on each annotation — at
/// time of writing that's `element` (a DOM hit-test snapshot containing
/// tagName / componentName / computedStyles / screenshot data-URL / …) and
/// `initialScrollX/Y` (pin-follow scroll anchors). Swift doesn't interpret
/// those fields, but we MUST preserve them through the
/// typed-model ↔ JSON round-trip — otherwise every Swift-side mutation
/// strips them from sibling annotations, destroying pin-editor labels,
/// screenshots, and scroll follow on reopen.
///
/// The `extras` catchall holds any JSON fields not enumerated above. Parse
/// fills it with everything that isn't a known key; serialize emits `extras`
/// first and then overwrites with known typed fields, so the typed values
/// win when a key appears in both. This means Swift can round-trip today's
/// schema AND any JS-added fields without a matching Swift change.
struct AnnotationModel: Hashable {
    var id: String
    var num: Int
    var frameId: String
    /// Frame-local percentage coordinates, stored 0…1. Rendered position is
    /// `(xPct * frameW, yPct * frameH)` at the current viewport.
    var xPct: CGFloat
    var yPct: CGFloat
    /// Color name (`"blue"`, `"green"`, `"orange"`, `"pink"`, …). The JS
    /// `COLORS` array defines the palette; native `PinOverlayView` / pin
    /// editor maps the strings to CGColor.
    var color: String
    /// User-entered text. Empty string until the pin editor saves.
    var comment: String
    /// Whether the pin is marked resolved (greyed out in the panel, struck
    /// through in chips).
    var resolved: Bool
    /// Style-edit map from the pin editor. `{ property: "new value", … }`.
    var edits: [String: String]
    /// Frame snapshot at creation time (URL + label). Kept so the panel can
    /// label orphaned annotations whose frame was deleted.
    var frameUrl: String?
    var frameLabel: String?
    /// Opaque passthrough for JS-owned annotation fields Swift doesn't
    /// interpret (`element`, `initialScrollX`, `initialScrollY`, and any
    /// future additions). Defaults to empty so existing call sites that
    /// use the synthesized memberwise init don't need to pass it.
    /// See the type-level note for rationale.
    var extras: [String: JSONValue] = [:]
}

extension AnnotationModel {
    /// Keys enumerated as typed properties above. Parse subtracts this set
    /// from the incoming JSON object to populate `extras`, and serialize
    /// writes typed properties last so they always win over any stale
    /// carryover in `extras`.
    fileprivate static let typedKeys: Set<String> = [
        "id", "num", "frameId", "xPct", "yPct", "color", "comment",
        "resolved", "edits", "frameUrl", "frameLabel",
    ]

    init?(jsonValue: JSONValue) {
        guard case .object(let o) = jsonValue,
              case .string(let id)      = o["id"]      ?? .null,
              case .string(let frameId) = o["frameId"] ?? .null else { return nil }
        self.id       = id
        self.frameId  = frameId
        self.num      = Int(FrameModel.number(o["num"]) ?? 0)
        self.xPct     = CGFloat(FrameModel.number(o["xPct"]) ?? 0)
        self.yPct     = CGFloat(FrameModel.number(o["yPct"]) ?? 0)
        self.color    = FrameModel.string(o["color"]) ?? "blue"
        self.comment  = FrameModel.string(o["comment"]) ?? ""
        self.resolved = FrameModel.bool(o["resolved"]) ?? false
        self.frameUrl   = FrameModel.string(o["frameUrl"])
        self.frameLabel = FrameModel.string(o["frameLabel"])
        if case .object(let editsDict) = o["edits"] ?? .null {
            var m: [String: String] = [:]
            for (k, v) in editsDict { if case .string(let s) = v { m[k] = s } }
            self.edits = m
        } else { self.edits = [:] }
        // Everything else falls into extras — covers `element`,
        // `initialScrollX`, `initialScrollY`, and any future JS-added
        // fields Swift doesn't know about yet.
        var rest: [String: JSONValue] = [:]
        for (k, v) in o where !AnnotationModel.typedKeys.contains(k) {
            rest[k] = v
        }
        self.extras = rest
    }

    var jsonValue: JSONValue {
        // Start with extras so typed fields below can overwrite any
        // stale carryover (shouldn't happen since extras filters them on
        // parse, but makes the invariant "typed wins" syntactically true).
        var o: [String: JSONValue] = extras
        o["id"]       = .string(id)
        o["num"]      = .number(Double(num))
        o["frameId"]  = .string(frameId)
        o["xPct"]     = .number(Double(xPct))
        o["yPct"]     = .number(Double(yPct))
        o["color"]    = .string(color)
        o["comment"]  = .string(comment)
        o["resolved"] = .bool(resolved)
        if edits.isEmpty {
            o.removeValue(forKey: "edits")
        } else {
            var e: [String: JSONValue] = [:]
            for (k, v) in edits { e[k] = .string(v) }
            o["edits"] = .object(e)
        }
        if let u = frameUrl   { o["frameUrl"]   = .string(u) }
        else                  { o.removeValue(forKey: "frameUrl") }
        if let l = frameLabel { o["frameLabel"] = .string(l) }
        else                  { o.removeValue(forKey: "frameLabel") }
        return .object(o)
    }

    /// One-line description of an area comment for agents and copied text:
    /// the region in CSS pixels of the page viewport and what is inside it.
    /// Nil for a point comment.
    nonisolated var areaSummary: String? {
        guard case .object(let el) = extras["element"] ?? .null,
              case .object(let a) = el["area"] ?? .null,
              case .number(let x) = a["x"] ?? .null, case .number(let y) = a["y"] ?? .null,
              case .number(let w) = a["width"] ?? .null, case .number(let h) = a["height"] ?? .null else { return nil }
        var text = "region x \(Int(x)), y \(Int(y)), \(Int(w))×\(Int(h)) CSS px of the viewport"
        if case .array(let items) = el["areaElements"] ?? .null {
            let parts: [String] = items.prefix(12).compactMap { item in
                guard case .object(let o) = item, case .string(let sel) = o["selector"] ?? .null else { return nil }
                if case .string(let t) = o["text"] ?? .null, !t.isEmpty { return "\(sel) \"\(t)\"" }
                return sel
            }
            if !parts.isEmpty { text += "; contains " + parts.joined(separator: ", ") }
        }
        return text
    }

    /// Size of an area comment, in the same percent units as `xPct`/`yPct`.
    /// The area's top-left corner is the pin position. Nil for a point
    /// comment. Stored in `extras["area"]` as `{wPct, hPct}` so older
    /// versions keep it and show the pin at the corner.
    var areaSizePct: CGSize? {
        get {
            guard case .object(let o) = extras["area"] ?? .null,
                  case .number(let w) = o["wPct"] ?? .null, case .number(let h) = o["hPct"] ?? .null,
                  w > 0, h > 0 else { return nil }
            return CGSize(width: w, height: h)
        }
        set {
            if let s = newValue {
                extras["area"] = .object(["wPct": .number(Double(s.width)), "hPct": .number(Double(s.height))])
            } else {
                extras.removeValue(forKey: "area")
            }
        }
    }
}

// MARK: Viewport

/// Canvas pan/zoom. Mirrors the `{scale, px, py}` triple emitted by JS.
/// `scale` is clamped 0.05…5 at the input layer; we don't re-clamp here.
struct ViewportModel: Hashable {
    var scale: CGFloat
    var panX:  CGFloat
    var panY:  CGFloat
    /// Fields written by a newer Web Frames; carried through untouched.
    var extras: [String: JSONValue] = [:]

    static let identity = ViewportModel(scale: 1, panX: 80, panY: 80)
}

extension ViewportModel {
    init(jsonValue: JSONValue) {
        guard case .object(let o) = jsonValue else {
            self = .identity
            return
        }
        self.scale = CGFloat(FrameModel.number(o["scale"]) ?? 1)
        self.panX  = CGFloat(FrameModel.number(o["px"]) ?? 80)
        self.panY  = CGFloat(FrameModel.number(o["py"]) ?? 80)
        self.extras = o.filter { !["scale", "px", "py"].contains($0.key) }
    }

    var jsonValue: JSONValue {
        var o = extras
        o["scale"] = .number(Double(scale))
        o["px"] = .number(Double(panX))
        o["py"] = .number(Double(panY))
        return .object(o)
    }
}

// MARK: Viewport — pan/zoom math
//
// Pure helpers used by the Phase 6e Step 1 gesture monitor in
// `DocumentWindowController`. Kept off AppKit / NSEvent so they can be
// exercised from unit tests without a window.
//
// Clamp and zoom-around-cursor formulae mirror `wheel` + `dockZoom*` in
// index.html byte-for-byte so the flipped path produces the same
// numerical viewport JS used to compute — any drift would surface as a
// subtle cursor-anchor shift under the user's pointer mid-zoom.
extension ViewportModel {

    /// Matches JS `Math.min(5,Math.max(0.05,...))` at every zoom site.
    static let minScale: CGFloat = 0.05
    static let maxScale: CGFloat = 5

    /// Clamp any scalar to the JS-matching zoom range.
    static func clampScale(_ s: CGFloat) -> CGFloat {
        max(minScale, min(maxScale, s))
    }

    /// Pan by a world-unit delta.
    ///
    /// Sign convention: `panX`/`panY` are added, NOT subtracted. Callers
    /// feed AppKit-native scroll deltas (trackpad natural-scroll: up-swipe
    /// produces `scrollingDeltaY > 0`), which are sign-flipped from the
    /// DOM `WheelEvent.deltaY` that the JS handler at `index.html:664`
    /// uses with `py -= e.deltaY`. Net physical direction is identical.
    func panned(byX dx: CGFloat, byY dy: CGFloat) -> ViewportModel {
        ViewportModel(scale: scale, panX: panX + dx, panY: panY + dy, extras: extras)
    }

    /// Absolute-set pan. Phase 6e Step 8 click-drag pan uses this to
    /// apply each tick against the gesture-start anchor rather than
    /// accumulating per-tick deltas — drift-free in the face of
    /// dropped events or coarse sampling.
    func withPan(x: CGFloat, y: CGFloat) -> ViewportModel {
        ViewportModel(scale: scale, panX: x, panY: y, extras: extras)
    }

    /// Scale around an anchor point in the same coordinate system as
    /// `panX` / `panY` (canvas-local, top-left origin). Mirrors the JS
    /// cursor-centric zoom at `index.html:671`:
    ///
    ///   px' = ax - (ax - px) * (ns / scale)
    ///
    /// Net effect: the pixel under the cursor stays under the cursor as
    /// the canvas zooms. Result is clamped to [minScale, maxScale]. If
    /// the clamp pins the scale to the same value (already at the rail),
    /// the viewport is returned unchanged — no pan drift on over-zoom.
    func zoomed(multiplier m: CGFloat,
                aroundX ax: CGFloat,
                aroundY ay: CGFloat) -> ViewportModel {
        let ns = Self.clampScale(scale * m)
        guard ns != scale else { return self }
        let ratio = ns / scale
        return ViewportModel(
            scale: ns,
            panX:  ax - (ax - panX) * ratio,
            panY:  ay - (ay - panY) * ratio,
            extras: extras
        )
    }
}
