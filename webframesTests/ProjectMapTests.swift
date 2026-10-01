import Testing
import Foundation
@testable import Web_Frames

@Suite("Project map and inventory") @MainActor struct ProjectMapTests {
    func fixture(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for (path, text) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        return root
    }
    @Test func nextRoutesAndTransitiveInventory() throws {
        let root = try fixture([
            "src/app/(main)/page.tsx": "import { Card } from '@/components/Card'; export default function Home() { return <Card/> }",
            "src/app/(main)/projects/page.tsx": "export default function Projects() { return <main/> }",
            "src/app/projects/[id]/page.tsx": "export default function Detail() { return <main/> }",
            "src/app/layout.tsx": "import { Nav } from '@/components/Nav'; export default function Layout() { return <Nav/> }",
            "src/app/@modal/page.tsx": "export default function Modal() { return <div/> }",
            "src/app/_private/page.tsx": "export default function Private() { return <div/> }",
            "src/components/Card.tsx": "import { Badge } from './Badge'; export const Card = () => <Badge/>;",
            "src/components/Badge.tsx": "export function Badge() { return <span/> }",
            "src/components/Nav.tsx": "export function Nav() { return <a href='/projects'>Projects</a> }",
            "src/styles.css": ":root { --brand: #6855de; --gap: 16px; } /* --fake: red; */",
            "node_modules/other/app/page.tsx": "function Fake() { return <div/> }"
        ]); defer { try? FileManager.default.removeItem(at: root) }
        let map = try WebProjectScanner.scan(root: root)
        #expect(map.routes.map(\.path) == ["/", "/projects", "/projects/[id]"])
        #expect(map.routes.last?.dynamic == true)
        #expect(map.components.first { $0.name == "Badge" }?.pages == ["/"])
        #expect(map.components.first { $0.name == "Nav" }?.pages.count == 3)
        #expect(map.routes.first?.links == ["/projects"])
        #expect(Set(map.tokens.map(\.name)) == Set(["--brand", "--gap"]))
        #expect(!map.components.contains { $0.name == "Fake" })
    }
    @Test func skipsSymlinksAndFakeDeclarations() throws {
        let root = try fixture(["index.html": "<main/>", "Card.tsx": "// function Fake() {}\nconst message = 'function Nope() {}';\nexport function Card() { return <div/> }"])
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let map = try WebProjectScanner.scan(root: root)
        #expect(map.components.map(\.name) == ["Card"])
        #expect(map.routes.map(\.path) == ["/"])
    }
    @Test func buildRescanAndPersistencePreserveUserWork() throws {
        var map = ProjectMapSnapshot(name: "Demo", rootPath: "/demo", framework: "Next.js")
        map.routes = [ProjectRoute(path: "/", source: "app/page.tsx", dynamic: false, selected: true, links: ["/about"]), ProjectRoute(path: "/about", source: "app/about/page.tsx", dynamic: false, selected: true)]
        let store = WorkspaceStore()
        map = try ProjectMapBuilder.build(map, store: store)
        let id = try #require(map.routes.first?.frameID)
        let source = try #require(map.webSource)
        #expect(source.address == "http://localhost:3000")
        #expect(store.frame(id: id)?.extras["webSourceID"] == .string(source.id))
        store.moveFrame(id: id, to: CGPoint(x: 400, y: 500))
        let ann = AnnotationModel(id: "comment", num: 1, frameId: id, xPct: 10, yPct: 10, color: "#00ff00", comment: "Keep this", resolved: false, edits: [:], frameUrl: "", frameLabel: "")
        store.createAnnotation(ann)
        map.baseURL = "http://localhost:4321"
        map = try ProjectMapBuilder.build(map, store: store)
        #expect(store.frames.count == 2)
        #expect(store.frame(id: id)?.x == 400)
        #expect(store.annotations == [ann])
        #expect(store.links.count == 1)
        #expect(store.frame(id: id)?.url == "http://localhost:4321/")
        #expect(map.webSource?.address == "http://localhost:4321")
        let payload = try JSONDecoder().decode(DocumentPayload.self, from: JSONEncoder().encode(store.serialize()))
        let restored = WorkspaceStore(); restored.apply(payload)
        #expect(restored.projectMap == map)
        #expect(restored.annotations == [ann])
        var rescan = map; rescan.routes.removeLast()
        let merged = ProjectMapBuilder.merged(rescan, previous: map)
        #expect(merged.routes.last?.missing == true)
        #expect(merged.routes.first?.frameID == id)
    }
    @Test func rejectsUnsafeURLsAndValidatesBeforeMutation() throws {
        for path in ["//evil.test", "/../secret", "/[id]", "/\\evil"] {
            #expect(throws: (any Error).self) { try ProjectMapBuilder.pageURL(base: "http://localhost:3000", path: path) }
        }
        #expect(throws: (any Error).self) { try ProjectMapBuilder.pageURL(base: "file:///tmp", path: "/") }
        var map = ProjectMapSnapshot(name: "Demo", rootPath: "/demo", framework: "Next.js")
        map.routes = [ProjectRoute(path: "/", source: "app/page.tsx", dynamic: false, selected: true), ProjectRoute(path: "/[id]", source: "app/[id]/page.tsx", dynamic: true, selected: true)]
        let store = WorkspaceStore()
        #expect(throws: (any Error).self) { try ProjectMapBuilder.build(map, store: store) }
        #expect(store.frames.isEmpty)
    }
    @Test func htmlModuleInventoryAndDictionaryRoundTrip() throws {
        let root = try fixture(["index.html": "<script type='module' src='./main.js'></script>", "main.js": "import { Card } from './components.js'; Card();", "components.js": "export function Card() { return `<article>Hello</article>` }"])
        defer { try? FileManager.default.removeItem(at: root) }
        let map = try WebProjectScanner.scan(root: root)
        #expect(map.components.first?.pages == ["/"])
        var payload = DocumentPayload(); payload.projectMap = map
        #expect(DocumentPayload(fromDictionary: payload.asDictionary).projectMap == map)
    }
    @Test func olderDocumentsStillDecode() throws {
        let data = Data(#"{"version":1,"name":"Old","frames":[],"annotations":[],"links":[],"canvas":null,"nextNum":1,"annNext":1}"#.utf8)
        #expect(try JSONDecoder().decode(DocumentPayload.self, from: data).projectMap == nil)
    }
}
