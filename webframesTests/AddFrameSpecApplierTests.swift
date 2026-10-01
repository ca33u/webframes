import Testing
import Foundation
import CoreGraphics
@testable import Web_Frames

/// Phase 6e Step 70b — byte-for-byte parity tests for the native port
/// of JS `applyAddFrameSpec`. We can't diff generated ids (Date.now +
/// random), so tests inject a deterministic id / num generator and
/// assert on every other field.
@MainActor
struct AddFrameSpecApplierTests {

    // Deterministic counter + id helpers the tests wire up.
    private func counter() -> (() -> Int) {
        var n = 0
        return { n += 1; return n }
    }
    private func ids() -> (() -> String) {
        var i = 0
        return { i += 1; return "id\(i)" }
    }

    @Test("local: normalizes missing scheme to http://")
    func localNormalizes() {
        let spec: [String: Any] = [
            "kind": "local", "url": "example.com", "label": "",
            "w": 1280, "h": 800,
        ]
        let out = AddFrameSpecApplier.frames(
            for: spec, existingFrameCount: 0, viewport: .identity,
            allocateNum: counter(), generateId: ids()
        )
        #expect(out.count == 1)
        #expect(out[0].url == "http://example.com")
        #expect(out[0].label == "http://example.com") // empty label → URL
        #expect(out[0].w == 1280)
        #expect(out[0].h == 800)
        #expect(out[0].num == 1)
        #expect(out[0].isImage == false)
    }

    @Test("local: preserves existing https scheme")
    func localPreservesHttps() {
        let spec: [String: Any] = [
            "kind": "local", "url": "HTTPS://Secure.Example.com",
            "label": "Secure", "w": 1280, "h": 800,
        ]
        let out = AddFrameSpecApplier.frames(
            for: spec, existingFrameCount: 0, viewport: .identity,
            allocateNum: counter(), generateId: ids()
        )
        #expect(out[0].url == "HTTPS://Secure.Example.com")
        #expect(out[0].label == "Secure")
    }

    @Test("local: empty URL returns no frames")
    func localEmptyURLRejected() {
        let spec: [String: Any] = [
            "kind": "local", "url": "   ", "label": "",
            "w": 1280, "h": 800,
        ]
        let out = AddFrameSpecApplier.frames(
            for: spec, existingFrameCount: 0, viewport: .identity,
            allocateNum: counter(), generateId: ids()
        )
        #expect(out.isEmpty)
    }

    @Test("web page: localhost defaults to HTTP and public hosts to HTTPS")
    func webPageChoosesScheme() {
        let local = AddFrameSpecApplier.frames(
            for: ["kind": "web", "url": "localhost:5173", "label": "", "w": 1280, "h": 800],
            existingFrameCount: 0, viewport: .identity,
            allocateNum: counter(), generateId: ids()
        )
        let publicPage = AddFrameSpecApplier.frames(
            for: ["kind": "web", "url": "example.com", "label": "", "w": 1280, "h": 800],
            existingFrameCount: 0, viewport: .identity,
            allocateNum: counter(), generateId: ids()
        )
        #expect(local.first?.url == "http://localhost:5173")
        #expect(publicPage.first?.url == "https://example.com")
    }

    @Test("folder: empty files array returns no frames")
    func folderEmptyReturnsEmpty() {
        let spec: [String: Any] = [
            "kind": "folder", "folderId": "F1",
            "files": [String](),
            "w": 1280, "h": 800,
        ]
        let out = AddFrameSpecApplier.frames(
            for: spec, existingFrameCount: 0, viewport: .identity,
            allocateNum: counter(), generateId: ids()
        )
        #expect(out.isEmpty)
    }

    @Test("github: public repo uses htmlpreview proxy")
    func githubPublic() {
        let spec: [String: Any] = [
            "kind": "github", "owner": "acme", "repo": "site",
            "branch": "main", "files": ["docs/a.html"],
            "w": 1280, "h": 800,
        ]
        let out = AddFrameSpecApplier.frames(
            for: spec, existingFrameCount: 0, viewport: .identity,
            allocateNum: counter(), generateId: ids()
        )
        #expect(out.count == 1)
        #expect(out[0].url ==
            "https://htmlpreview.github.io/?https://github.com/acme/site/blob/main/docs/a.html")
        #expect(out[0].label == "a")
    }

    @Test("github: private repo stores a credential-free URL")
    func githubPrivate() {
        let spec: [String: Any] = [
            "kind": "github", "owner": "acme", "repo": "site",
            "branch": "dev", "token": "tok_xyz",
            "files": ["index.html"],
            "w": 1280, "h": 800,
        ]
        let out = AddFrameSpecApplier.frames(
            for: spec, existingFrameCount: 0, viewport: .identity,
            allocateNum: counter(), generateId: ids()
        )
        #expect(out[0].url ==
            "wf-github://acme/site/dev/index.html")
    }

    @Test("image: scales oversized width to 1440 cap, preserves aspect")
    func imageScalesWidth() {
        let spec: [String: Any] = [
            "kind": "image",
            "images": [[
                "name": "my_screenshot.png",
                "dataURL": "data:image/png;base64,AAA",
                "natW": 2880, "natH": 1800,
            ]],
        ]
        let out = AddFrameSpecApplier.frames(
            for: spec, existingFrameCount: 0, viewport: .identity,
            allocateNum: counter(), generateId: ids()
        )
        #expect(out.count == 1)
        #expect(out[0].w == 1440)
        // 1440 / 2880 * 1800 = 900
        #expect(out[0].h == 900)
        #expect(out[0].label == "my screenshot") // extension + underscore
        #expect(out[0].url == "image://my screenshot")
        #expect(out[0].isImage == true)
        // Image fields survive via extras
        if case .string(let u)? = out[0].extras["imgUrl"] {
            #expect(u == "data:image/png;base64,AAA")
        } else { Issue.record("missing imgUrl in extras") }
    }

    @Test("image: user-provided label overrides filename-derived label")
    func imageUserLabelWins() {
        let spec: [String: Any] = [
            "kind": "image", "label": "My Batch",
            "images": [
                ["name": "a.png", "dataURL": "data:x,1", "natW": 400, "natH": 300],
                ["name": "b.png", "dataURL": "data:x,2", "natW": 400, "natH": 300],
            ],
        ]
        let out = AddFrameSpecApplier.frames(
            for: spec, existingFrameCount: 0, viewport: .identity,
            allocateNum: counter(), generateId: ids()
        )
        #expect(out.count == 2)
        #expect(out.allSatisfy { $0.label == "My Batch" })
    }

    @Test("image: missing dimensions defaults to 800h")
    func imageDefaultHeight() {
        let spec: [String: Any] = [
            "kind": "image",
            "images": [[
                "name": "unknown.png",
                "dataURL": "data:x,1",
            ]],
        ]
        let out = AddFrameSpecApplier.frames(
            for: spec, existingFrameCount: 0, viewport: .identity,
            allocateNum: counter(), generateId: ids()
        )
        // natW is 0 → clamp defaults kick in: w = min(1280, 1440) = 1280, h = 800
        #expect(out[0].w == 1280)
        #expect(out[0].h == 800)
    }

    @Test("unknown kind returns empty list")
    func unknownKind() {
        let spec: [String: Any] = ["kind": "unsupported"]
        let out = AddFrameSpecApplier.frames(
            for: spec, existingFrameCount: 0, viewport: .identity,
            allocateNum: counter(), generateId: ids()
        )
        #expect(out.isEmpty)
    }

    @Test("drop origin shifts right by existing-count + index stride")
    func dropOriginMath() {
        // width clamped at 600 + 48 gap per column, and JS uses
        // (80 + n*stride - px) / scale for x, (80 - py) / scale for y.
        let vp = ViewportModel(scale: 1, panX: 0, panY: 0)
        let p0 = AddFrameSpecApplier.dropOrigin(index: 0, width: 1280,
                                                existing: 0, viewport: vp)
        let p1 = AddFrameSpecApplier.dropOrigin(index: 1, width: 1280,
                                                existing: 0, viewport: vp)
        let p2 = AddFrameSpecApplier.dropOrigin(index: 0, width: 1280,
                                                existing: 2, viewport: vp)
        #expect(p0.x == 80)
        // stride = min(1280,600)+48 = 648. Typed constants keep the macro from
        // inferring the right-hand side as a different numeric type.
        let stride: CGFloat = 648
        #expect(p1.x == 80 + stride)
        #expect(p2.x == 80 + stride * 2)
        #expect(p0.y == 80)
    }

    @Test("drop origin undoes viewport transform")
    func dropOriginViewport() {
        // With px=100, py=50, scale=2: x = (80 - 100)/2 = -10, y = (80 - 50)/2 = 15
        let vp = ViewportModel(scale: 2, panX: 100, panY: 50)
        let p = AddFrameSpecApplier.dropOrigin(index: 0, width: 1280,
                                               existing: 0, viewport: vp)
        #expect(p.x == -10)
        #expect(p.y == 15)
    }

    @Test("default id generator returns unique-looking ids")
    func defaultIds() {
        let a = AddFrameSpecApplier.defaultIdGenerator()
        let b = AddFrameSpecApplier.defaultIdGenerator()
        #expect(a.hasPrefix("f"))
        #expect(b.hasPrefix("f"))
        #expect(a != b) // collisions astronomically unlikely
    }
}
