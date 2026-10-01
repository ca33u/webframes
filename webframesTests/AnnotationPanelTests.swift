import AppKit
import Testing
@testable import Web_Frames

@MainActor
@Suite("Comments panel")
struct AnnotationPanelTests {

    private func find<T: NSView>(_ type: T.Type, in view: NSView, where match: (T) -> Bool = { _ in true }) -> T? {
        if let v = view as? T, match(v) { return v }
        for sub in view.subviews { if let v = find(type, in: sub, where: match) { return v } }
        return nil
    }

    private func info(_ id: String, _ num: Int, comment: String, resolved: Bool = false) -> AnnotationInfo {
        AnnotationInfo(id: id, num: num, color: "blue", comment: comment, resolved: resolved,
                       frameLabel: "IMG 0458", viewport: "1290×2796", selector: "—",
                       screenshot: nil, editKeys: [])
    }

    @Test func listsCommentsInATableAndCountsOpenOnesOnFix() throws {
        let panel = AnnotationPanel()
        panel.frame = NSRect(x: 0, y: 0, width: 320, height: 640)
        panel.setAnnotations([
            info("a1", 1, comment: "Short"),
            info("a2", 2, comment: String(repeating: "A long comment that wraps over several lines. ", count: 6)),
            info("a3", 3, comment: "Done", resolved: true),
        ])
        panel.layoutSubtreeIfNeeded()

        let table = try #require(find(NSTableView.self, in: panel))
        #expect(table.numberOfRows == 3)
        #expect(table.rect(ofRow: 1).height > table.rect(ofRow: 0).height)
        let fix = try #require(find(NSButton.self, in: panel, where: { $0.accessibilityIdentifier() == "comments.fixWithCodex" }))
        #expect(fix.title.hasSuffix("· 2"))
        #expect(fix.isEnabled)
        #expect(fix.bezelColor == WFDesign.accent)

        panel.setAnnotations([info("a3", 3, comment: "Done", resolved: true)])
        #expect(!fix.isEnabled)
    }
}
