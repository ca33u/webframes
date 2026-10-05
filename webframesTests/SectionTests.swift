import AppKit
import Testing
@testable import Web_Frames

@MainActor
@Suite("Sections")
struct SectionTests {

    private func frame(_ id: String, _ x: CGFloat, _ y: CGFloat) -> FrameModel {
        FrameModel(id: id, url: "https://example.com/\(id)", label: id, x: x, y: y, w: 390, h: 845, num: 1, isImage: false, filePath: nil)
    }

    private func store(_ frames: [FrameModel]) -> WorkspaceStore {
        let store = WorkspaceStore()
        for f in frames { _ = store.createFrame(f) }
        return store
    }

    @Test func framesBelongToTheSmallestSectionContainingThem() throws {
        let s = store([frame("a", 0, 0), frame("b", 500, 0), frame("c", 3000, 0)])
        let big = try #require(s.createSection(name: "Flow", rect: CGRect(x: -100, y: -100, width: 1200, height: 1200)))
        let small = try #require(s.createSection(name: "Step", rect: CGRect(x: 450, y: -50, width: 500, height: 1000)))
        #expect(s.section(containing: "a")?.id == big.id)
        #expect(s.section(containing: "b")?.id == small.id)
        #expect(s.section(containing: "c") == nil)
        // Dropping a frame into the area makes it a member.
        s.moveFrame(id: "c", to: CGPoint(x: 0, y: 200))
        #expect(s.section(containing: "c")?.id == big.id)
        #expect(s.frames(in: big).map(\.id) == ["a", "c"])
    }

    @Test func editsAreUndoableAndKeepFrames() throws {
        let s = store([frame("a", 0, 0)])
        let before = s.sections
        let section = try #require(s.createSection(name: "Onboarding", rect: CGRect(x: -50, y: -50, width: 600, height: 1000)))
        s.renameSection(id: section.id, name: "Welcome")
        s.setSectionRect(id: section.id, rect: CGRect(x: 0, y: 0, width: 100, height: 100), action: "Resize Section")
        #expect(s.section(containing: "a") == nil)   // shrunk away from the frame
        let edited = s.sections
        s.restoreSections(before, action: "Create Section")
        #expect(s.sections.isEmpty)
        s.restoreSections(edited, action: "Create Section")
        #expect(s.sections.first?.name == "Welcome")
        s.deleteSection(id: section.id)
        #expect(s.sections.isEmpty && s.frames.count == 1)
    }

    @Test func emptySectionsAndAreaRoundTripThroughTheDocument() throws {
        let s = store([frame("a", 0, 0)])
        let drawn = try #require(s.createSection(name: "Later", rect: CGRect(x: 2000, y: 0, width: 800, height: 600)))
        s.setSectionCollapsed(id: drawn.id, collapsed: true)
        let reloaded = WorkspaceStore()
        reloaded.apply(s.serialize())
        #expect(reloaded.sections.count == 1)
        #expect(reloaded.sections.first?.rect == CGRect(x: 2000, y: 0, width: 800, height: 600))
        #expect(reloaded.sections.first?.collapsed == true)
        #expect(reloaded.sections.first?.name == "Later")

        let plain = WorkspaceStore()
        plain.apply(store([frame("x", 0, 0)]).serialize())
        let json = try JSONEncoder().encode(plain.serialize())
        #expect(!(String(data: json, encoding: .utf8) ?? "").contains("sections"))
    }

    @Test func wrapAreaAndEdgeDragsKeepAMinimumSize() throws {
        let area = try #require(SectionModel.area(of: [frame("a", 0, 0), frame("b", 500, 100)]))
        #expect(area.minX == -SectionModel.padding && area.minY == -SectionModel.padding)
        #expect(area.maxX == 500 + 390 + CardGeometry.chromeWidth + SectionModel.padding)
        #expect(SectionModel.area(of: []) == nil)

        let r = CGRect(x: 0, y: 0, width: 400, height: 300)
        let min = SectionModel.minimumSize
        #expect(SectionEdge.apply(nil, to: r, dx: 10, dy: 20, minimum: min) == CGRect(x: 10, y: 20, width: 400, height: 300))
        #expect(SectionEdge.apply(.right, to: r, dx: 100, dy: 999, minimum: min) == CGRect(x: 0, y: 0, width: 500, height: 300))
        #expect(SectionEdge.apply(.topLeft, to: r, dx: -50, dy: -40, minimum: min) == CGRect(x: -50, y: -40, width: 450, height: 340))
        let squashed = SectionEdge.apply(.bottomRight, to: r, dx: -1000, dy: -1000, minimum: min)
        #expect(squashed.size == min)
    }

    @Test func agentContextAndCopiedTextNameTheSection() {
        let frames = [frame("a", 0, 0)]
        let section = SectionModel(id: "s1", name: "Onboarding", rect: CGRect(x: -40, y: -40, width: 600, height: 1000))
        let ann = AnnotationModel(id: "n1", num: 1, frameId: "a", xPct: 10, yPct: 10, color: "blue",
                                  comment: "Bigger title", resolved: false, edits: [:],
                                  frameUrl: nil, frameLabel: "a", extras: [:])
        let context = CodexCommentContextBuilder.make(annotations: [ann], frames: frames, sections: [section])
        #expect(context.comments.first?.section == "Onboarding")
        let text = AnnotationCopyFormatter.fullText(annotations: [ann], frames: frames, sections: [section])
        #expect(text.contains("Section: Onboarding"))
    }

    @Test func sidebarGroupsCollapsesAndListsEmptySections() {
        let sidebar = FramesSidebar(frame: NSRect(x: 0, y: 0, width: 260, height: 600))
        let frames = [frame("a", 0, 0), frame("b", 500, 0), frame("c", 1000, 0)]
        func ids(_ view: NSView) -> [String] {
            view.subviews.flatMap { sub -> [String] in
                let own = sub.accessibilityIdentifier()
                return (own.isEmpty ? [] : [own]) + ids(sub)
            }
        }
        let flow = SectionModel(id: "s1", name: "Flow", rect: CGRect(x: 450, y: -50, width: 1000, height: 1000))
        let empty = SectionModel(id: "s2", name: "Later", rect: CGRect(x: 5000, y: 0, width: 400, height: 400))
        sidebar.setFrames(frames, sections: [flow, empty], projectMap: nil)
        let open = ids(sidebar)
        #expect(open.contains("webframes.framesSidebar.section.s1"))
        #expect(open.contains("webframes.framesSidebar.section.s2"))
        #expect(open.contains("webframes.framesSidebar.row.b"))
        var collapsed = flow; collapsed.collapsed = true
        sidebar.setFrames(frames, sections: [collapsed, empty], projectMap: nil)
        let after = ids(sidebar)
        #expect(!after.contains("webframes.framesSidebar.row.b"))
        #expect(after.contains("webframes.framesSidebar.row.a"))
    }
}
