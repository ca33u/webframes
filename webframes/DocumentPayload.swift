import Foundation

/// On-disk shape of a `.webframes` document.
///
/// Mirrors the keys that the canvas JS (`saveState` / `restoreState` in
/// `index.html`) used to write into localStorage, now encoded as a single
/// JSON blob persisted by `WebFramesDocument`.
///
/// Contract with the canvas:
///   * Swift → canvas: `doc-load-state` with `payload: DocumentPayload` after
///     the webview finishes loading.
///   * canvas → Swift: `doc-state-changed` with the same shape, debounced,
///     on every mutation that previously called `saveState()`.
///
/// The payload is kept intentionally loose (`[String: AnyCodable]`-adjacent)
/// so the JS side stays the source of truth for frame/annotation fields and
/// adding a new one does not require a Swift migration.
struct DocumentPayload: Codable, Equatable {

    /// Version of the on-disk schema. Bumped when the shape of any stored
    /// field changes in a way that the JS loader cannot tolerate.
    var version: Int = DocumentPayload.currentVersion

    /// The newest schema this build understands. Files from a newer Web
    /// Frames are refused instead of being opened and silently re-saved in
    /// an older shape.
    /// 2: `.webframes` is a package with images stored as files (see
    /// DocumentPackage). A version-2 JSON may also be a single file with
    /// inline images; version 1 is always a single file.
    static let currentVersion = 2

    /// User-editable project name shown in the titlebar. Defaults to
    /// "Untitled" for a fresh document; persists alongside the canvas state.
    var name: String = "Untitled"

    /// `[{ id, url, label, x, y, w, h, num }]` — excludes local:// / image
    /// frames; see `saveState()` in index.html.
    var frames: [JSONValue] = []

    /// `[{ id, frameId, xPct, yPct, label, ... }]`
    var annotations: [JSONValue] = []

    /// `[{ fromId, toId }]`
    var links: [JSONValue] = []

    /// `{ scale, px, py }` — canvas pan/zoom.
    var canvas: JSONValue = .null

    /// Running counters — the JS side bumps these when creating a new frame
    /// or annotation; persisting means numbering survives a reload.
    var nextNum: Int = 1
    var annNext: Int = 1

    var projectMap: ProjectMapSnapshot?
    var fixSource: FixSourceReference?

    static let empty = DocumentPayload()
}

/// Minimal JSON-value wrapper so we can round-trip arbitrary canvas objects
/// (frames/annotations) without having to mirror their fields in Swift.
/// Keeps the Swift side agnostic to JS schema evolution.
enum JSONValue: Codable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self)   { self = .bool(v);   return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:         try c.encodeNil()
        case .bool(let v):  try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Converts a Foundation object (as produced by JSONSerialization) into
    /// a `JSONValue`. Unsupported types become `.null`.
    ///
    /// `nonisolated` because under SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor
    /// this method would otherwise inherit MainActor — and callers include
    /// nonisolated bridge-message handling and Codable synthesis, which
    /// would then warn. The body touches no isolated state (pure value
    /// recursion), so nonisolated is sound.
    nonisolated static func from(_ any: Any) -> JSONValue {
        // NSNumber has to be discriminated *before* any `as Bool`/`as Int`/
        // `as Double` case, because Swift's NSNumber bridge will happily
        // cast NSNumber(value: 1) to Bool(true) and NSNumber(value: 0) to
        // Bool(false). CFBoolean-type-ID is the only reliable way to tell
        // a boxed Bool from a boxed numeric. Once we're here, Swift Bool /
        // Int / Double all bridge to NSNumber too, so this single branch
        // covers every numeric/boolean path.
        if let num = any as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return .bool(num.boolValue) }
            return .number(num.doubleValue)
        }
        switch any {
        case is NSNull: return .null
        case let v as String: return .string(v)
        case let v as [Any]: return .array(v.map(JSONValue.from))
        case let v as [String: Any]:
            var o: [String: JSONValue] = [:]
            for (k, val) in v { o[k] = JSONValue.from(val) }
            return .object(o)
        default: return .null
        }
    }

    /// Unwraps into a Foundation object suitable for JSONSerialization /
    /// `WebMessenger.dispatch`. Inverse of `from(_:)`. Nonisolated for the
    /// same reason as `from(_:)` — pure value-type operation.
    nonisolated var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.foundation)
        case .object(let v):
            var o: [String: Any] = [:]
            for (k, val) in v { o[k] = val.foundation }
            return o
        }
    }
}

extension DocumentPayload {
    /// Serializes to a `[String: Any]` dict suitable for `WebMessenger.dispatch`.
    /// Nonisolated so the nonisolated `init(fromDictionary:)` / `asDictionary`
    /// bridge path doesn't force the default MainActor isolation.
    nonisolated var asDictionary: [String: Any] {
        var result: [String: Any] = [
            "version": version,
            "name":    name,
            "frames":  frames.map(\.foundation),
            "annotations": annotations.map(\.foundation),
            "links":   links.map(\.foundation),
            "canvas":  canvas.foundation,
            "nextNum": nextNum,
            "annNext": annNext,
        ]
        if let fixSource, let data = try? JSONEncoder().encode(fixSource),
           let value = try? JSONSerialization.jsonObject(with: data) { result["fixSource"] = value }
        if let projectMap, let data = try? JSONEncoder().encode(projectMap),
           let value = try? JSONSerialization.jsonObject(with: data) { result["projectMap"] = value }
        return result
    }

    /// Builds a payload from a raw dict received via the JS bridge. Nonisolated
    /// — see `JSONValue.from(_:)` for rationale.
    ///
    /// The canvas JS does not mutate `name` (that's driven by the native
    /// titlebar field), so the bridge-built payload carries the existing
    /// name through unchanged; callers splice in the current name before
    /// calling this when they have a reason to replace it.
    nonisolated init(fromDictionary dict: [String: Any]) {
        self.version     = (dict["version"] as? Int) ?? 1
        self.name        = (dict["name"] as? String) ?? "Untitled"
        self.nextNum     = (dict["nextNum"] as? Int) ?? 1
        self.annNext     = (dict["annNext"] as? Int) ?? 1
        self.frames      = (dict["frames"] as? [Any])?.map(JSONValue.from) ?? []
        self.annotations = (dict["annotations"] as? [Any])?.map(JSONValue.from) ?? []
        self.links       = (dict["links"] as? [Any])?.map(JSONValue.from) ?? []
        self.canvas      = dict["canvas"].map(JSONValue.from) ?? .null
        if let raw = dict["fixSource"], JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw) {
            self.fixSource = try? JSONDecoder().decode(FixSourceReference.self, from: data)
        }
        if let raw = dict["projectMap"], JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw) {
            self.projectMap = try? JSONDecoder().decode(ProjectMapSnapshot.self, from: data)
        }
    }
}

nonisolated struct FixSourceReference: Codable, Equatable {
    var path: String
    var bookmark: Data?
}
