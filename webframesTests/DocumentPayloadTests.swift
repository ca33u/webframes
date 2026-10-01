//
//  DocumentPayloadTests.swift
//  webframesTests
//
//  Covers the on-disk / bridge contract for `DocumentPayload` and its
//  `JSONValue` wrapper. These are the shapes that persist the entire
//  canvas state to a `.webframes` file and that round-trip through the
//  JS bridge, so regressions here silently corrupt user projects.
//

import Foundation
import Testing
@testable import Web_Frames

// MARK: - JSONValue

@Suite("JSONValue")
struct JSONValueTests {

    // MARK: Codable round-trip

    /// Every variant must survive `encode → decode` unchanged. Uses
    /// `[JSONValue]` as the root because the top-level "fragment" rule
    /// (a bare string/number/bool at the JSON root) is flaky across
    /// older JSONDecoders; wrapping in an array sidesteps that without
    /// changing what we test.
    @Test("all variants round-trip via Codable")
    func allVariantsRoundTrip() throws {
        let samples: [JSONValue] = [
            .null,
            .bool(true), .bool(false),
            .number(0), .number(-1.5), .number(1e9),
            .string(""), .string("hello"), .string("тест 🐳"),
            .array([.number(1), .number(2), .string("x")]),
            .object([
                "a": .number(1),
                "b": .string("y"),
                "nested": .array([.bool(true), .null]),
            ]),
        ]

        let data = try JSONEncoder().encode(samples)
        let decoded = try JSONDecoder().decode([JSONValue].self, from: data)

        #expect(decoded == samples)
    }

    @Test("unsupported JSON root throws")
    func unsupportedRoot() {
        // A top-level date is not a JSON primitive — the decoder should
        // reject it cleanly rather than silently coercing.
        let badJSON = Data("not-json".utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(JSONValue.self, from: badJSON)
        }
    }

    // MARK: from(_:) / foundation

    @Test("from(_:) coerces NSNull / Bool / Int / Double / String")
    func fromScalarTypes() {
        #expect(JSONValue.from(NSNull()) == .null)
        #expect(JSONValue.from(true)     == .bool(true))
        #expect(JSONValue.from(false)    == .bool(false))
        #expect(JSONValue.from(42)       == .number(42))
        #expect(JSONValue.from(3.14)     == .number(3.14))
        #expect(JSONValue.from("x")      == .string("x"))
    }

    /// NSNumber carries both bools and numbers; the bridge must pick the
    /// right variant. CFBoolean discrimination is the only reliable way
    /// — regressions here turn `true` into `1.0` inside the payload.
    @Test("from(_:) distinguishes NSNumber booleans from numerics")
    func fromNSNumberBooleanDiscriminator() {
        let boolTrue  = NSNumber(value: true)
        let boolFalse = NSNumber(value: false)
        let intOne    = NSNumber(value: 1)
        let doublePi  = NSNumber(value: 3.14)

        #expect(JSONValue.from(boolTrue)  == .bool(true))
        #expect(JSONValue.from(boolFalse) == .bool(false))
        #expect(JSONValue.from(intOne)    == .number(1))
        #expect(JSONValue.from(doublePi)  == .number(3.14))
    }

    @Test("from(_:) recurses into arrays and dicts")
    func fromNestedCollections() {
        let input: [String: Any] = [
            "list": [1, "two", true, NSNull()],
            "inner": ["k": 2.5],
        ]
        let v = JSONValue.from(input)

        guard case .object(let obj) = v else {
            Issue.record("expected .object, got \(v)")
            return
        }
        #expect(obj["list"] == .array([.number(1), .string("two"), .bool(true), .null]))
        #expect(obj["inner"] == .object(["k": .number(2.5)]))
    }

    @Test("from(_:) returns .null for unsupported types")
    func fromUnsupportedType() {
        // Date isn't a JSON primitive and the wrapper intentionally drops
        // it rather than trying to stringify — keeps the JS side in sync
        // with Swift's JSON contract.
        let v = JSONValue.from(Date(timeIntervalSince1970: 0))
        #expect(v == .null)
    }

    @Test("foundation is the inverse of from(_:)")
    func foundationIsInverse() {
        let original: [String: JSONValue] = [
            "a": .number(1),
            "b": .string("x"),
            "c": .array([.bool(true), .null]),
            "d": .object(["k": .number(2)]),
        ]
        let round = JSONValue.from(JSONValue.object(original).foundation)
        #expect(round == .object(original))
    }
}

// MARK: - DocumentPayload

@Suite("DocumentPayload")
struct DocumentPayloadTests {

    // MARK: Codable

    @Test("empty payload round-trips through JSONEncoder/Decoder")
    func emptyPayloadCodable() throws {
        let empty = DocumentPayload.empty
        let data = try JSONEncoder().encode(empty)
        let decoded = try JSONDecoder().decode(DocumentPayload.self, from: data)
        #expect(decoded == empty)
        // Spot-check the defaults in case `.empty` is ever edited.
        #expect(decoded.version == DocumentPayload.currentVersion)
        #expect(decoded.name == "Untitled")
        #expect(decoded.nextNum == 1)
        #expect(decoded.annNext == 1)
        #expect(decoded.frames.isEmpty)
        #expect(decoded.annotations.isEmpty)
        #expect(decoded.links.isEmpty)
        #expect(decoded.canvas == .null)
    }

    @Test("populated payload round-trips through JSONEncoder/Decoder")
    func populatedPayloadCodable() throws {
        let payload = Self.samplePayload()
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(DocumentPayload.self, from: data)
        #expect(decoded == payload)
    }

    @Test("unicode name survives round-trip")
    func unicodeNameRoundTrip() throws {
        var p = DocumentPayload.empty
        p.name = "Проект № 1 — 🚀"
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(DocumentPayload.self, from: data)
        #expect(decoded.name == p.name)
    }

    /// Forward-compat: a .webframes file written by a newer build may
    /// carry fields we don't know yet. The current decoder only reads
    /// the keys declared on the struct, so unknown keys are ignored and
    /// the rest of the payload still decodes.
    @Test("unknown top-level fields are ignored")
    func forwardCompatDecode() throws {
        let json = """
        {
          "version": 1,
          "name": "Alpha",
          "frames": [],
          "annotations": [],
          "links": [],
          "canvas": null,
          "nextNum": 1,
          "annNext": 1,
          "futureField": { "whatever": true }
        }
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(DocumentPayload.self, from: data)
        #expect(decoded.name == "Alpha")
    }

    /// A file that's not a JSON object must fail with a decoding error
    /// — NSDocument translates that to `NSFileReadCorruptFileError` for
    /// the user. Validates the boundary between "empty but valid" and
    /// "truly corrupt".
    @Test("garbage bytes fail to decode")
    func corruptPayloadFailsDecode() {
        let bad = Data("not a webframes file".utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(DocumentPayload.self, from: bad)
        }
    }

    // MARK: asDictionary / init(fromDictionary:)

    @Test("asDictionary exposes every persisted field")
    func asDictionaryShape() {
        let p = Self.samplePayload()
        let dict = p.asDictionary

        #expect(dict["version"] as? Int == p.version)
        #expect(dict["name"] as? String == p.name)
        #expect(dict["nextNum"] as? Int == p.nextNum)
        #expect(dict["annNext"] as? Int == p.annNext)
        #expect((dict["frames"] as? [Any])?.count == p.frames.count)
        #expect((dict["annotations"] as? [Any])?.count == p.annotations.count)
        #expect((dict["links"] as? [Any])?.count == p.links.count)
        #expect(dict["canvas"] != nil)
    }

    @Test("init(fromDictionary:) ↔ asDictionary is a round-trip")
    func bridgeDictRoundTrip() {
        let original = Self.samplePayload()
        let rebuilt = DocumentPayload(fromDictionary: original.asDictionary)
        #expect(rebuilt == original)
    }

    @Test("init(fromDictionary:) applies defaults for missing fields")
    func bridgeDictDefaults() {
        let rebuilt = DocumentPayload(fromDictionary: [:])
        #expect(rebuilt.version == 1)
        #expect(rebuilt.name == "Untitled")
        #expect(rebuilt.nextNum == 1)
        #expect(rebuilt.annNext == 1)
        #expect(rebuilt.frames.isEmpty)
        #expect(rebuilt.annotations.isEmpty)
        #expect(rebuilt.links.isEmpty)
        #expect(rebuilt.canvas == .null)
    }

    /// When the canvas bridge passes a dict *with* a name, the init
    /// honours it. (The higher-level contract — that `applyCanvasState`
    /// drops the incoming name and keeps the native one — is enforced
    /// in `WebFramesDocument`, not here.)
    @Test("init(fromDictionary:) honours a name when present")
    func bridgeDictHonoursName() {
        let rebuilt = DocumentPayload(fromDictionary: ["name": "Alpha"])
        #expect(rebuilt.name == "Alpha")
    }

    @Test("init(fromDictionary:) falls back to Untitled when name is wrong type")
    func bridgeDictMalformedName() {
        // A number where a string is expected — the bridge should not
        // crash, it should fall through to the "Untitled" default.
        let rebuilt = DocumentPayload(fromDictionary: ["name": 42])
        #expect(rebuilt.name == "Untitled")
    }

    @Test("init(fromDictionary:) preserves nested frame shape")
    func bridgeDictNestedShape() {
        let frame: [String: Any] = [
            "id": "f-1",
            "url": "https://example.com",
            "label": "Home",
            "x": 10, "y": 20, "w": 1024, "h": 768,
            "num": 1,
        ]
        let dict: [String: Any] = ["frames": [frame]]
        let rebuilt = DocumentPayload(fromDictionary: dict)

        #expect(rebuilt.frames.count == 1)
        guard case .object(let obj) = rebuilt.frames[0] else {
            Issue.record("expected frame to be an object")
            return
        }
        #expect(obj["id"] == .string("f-1"))
        #expect(obj["url"] == .string("https://example.com"))
        #expect(obj["w"]  == .number(1024))
    }

    // MARK: - Helpers

    /// A non-trivial payload hitting every field. Centralised so every
    /// round-trip test exercises the same shape — makes diff-on-failure
    /// trivial.
    private static func samplePayload() -> DocumentPayload {
        var p = DocumentPayload.empty
        p.version = 1
        p.name = "Sample Project"
        p.nextNum = 3
        p.annNext = 2
        p.frames = [
            .object([
                "id": .string("f-1"),
                "url": .string("https://example.com"),
                "label": .string("Home"),
                "x": .number(0), "y": .number(0),
                "w": .number(1024), "h": .number(768),
                "num": .number(1),
            ]),
            .object([
                "id": .string("f-2"),
                "url": .string("https://example.org"),
                "label": .string("Docs"),
                "x": .number(1100), "y": .number(0),
                "w": .number(800), "h": .number(600),
                "num": .number(2),
            ]),
        ]
        p.annotations = [
            .object([
                "id": .string("a-1"),
                "frameId": .string("f-1"),
                "xPct": .number(0.5),
                "yPct": .number(0.25),
                "label": .string("Note"),
            ]),
        ]
        p.links = [
            .object([
                "fromId": .string("f-1"),
                "toId":   .string("f-2"),
            ]),
        ]
        p.canvas = .object([
            "scale": .number(1.0),
            "px":    .number(0),
            "py":    .number(0),
        ])
        return p
    }
}
