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

    @Test func resolvedRowsAreMutedAndReopeningRestoresNormalAppearance() throws {
        let panel = AnnotationPanel()
        panel.setAnnotations([info("done", 1, comment: "Done", resolved: true), info("open", 2, comment: "Still open")])
        let table = try #require(find(NSTableView.self, in: panel))
        let done = try #require(panel.tableView(table, viewFor: nil, row: 0))
        let open = try #require(panel.tableView(table, viewFor: nil, row: 1))
        #expect(done.alphaValue < open.alphaValue)
        #expect(done.accessibilityLabel()?.hasPrefix("Resolved comment") == true)
        let reopen = try #require(find(NSButton.self, in: done))
        #expect(reopen.isEnabled)
        panel.setAnnotations([info("done", 1, comment: "Reopened")])
        let reopened = try #require(panel.tableView(table, viewFor: nil, row: 0))
        #expect(reopened.alphaValue == 1)
        #expect(reopened.accessibilityLabel()?.hasPrefix("Comment") == true)
    }

    @Test func filterButtonHidesRowsPinsAndAreasAndResolveUndoUpdatesBoth() throws {
        let doc = try PostLaunchWorkflowTests().document()
        let controller = DocumentWindowController(document: doc)
        defer { controller.close(); doc.updateChangeCount(.changeCleared); doc.close() }
        let undo = try #require(doc.undoManager)
        undo.groupsByEvent = false
        undo.disableUndoRegistration()
        doc.workspace.createFrame(FrameModel(id: "f", url: "about:blank", label: "Review", x: 100, y: 100,
            w: 300, h: 400, num: 1, isImage: false, filePath: nil))
        for (id, resolved, x) in [("done", true, CGFloat(20)), ("open", false, CGFloat(60))] {
            var ann = AnnotationModel(id: id, num: resolved ? 1 : 2, frameId: "f", xPct: x, yPct: 20,
                color: "blue", comment: id, resolved: resolved, edits: [:], frameUrl: nil, frameLabel: nil)
            ann.areaSizePct = CGSize(width: 20, height: 30)
            doc.workspace.createAnnotation(ann)
        }
        undo.enableUndoRegistration()
        let host = controller.canvasHost
        let panel = host.annotationPanel
        let table = try #require(find(NSTableView.self, in: panel))
        let toggle = try #require(find(NSButton.self, in: panel, where: { $0.accessibilityIdentifier() == "comments.hideResolved" }))
        let card = try #require(host.frameLayer.subviews.compactMap { $0 as? FrameCardView }.first)
        let overlay = card.container.pinOverlay
        func pins() -> [PinDotView] { overlay.subviews.compactMap { $0 as? PinDotView } }
        func areas() -> [CAShapeLayer] { overlay.layer?.sublayers?.compactMap { $0 as? CAShapeLayer } ?? [] }
        #expect(table.numberOfRows == 2 && pins().count == 2 && areas().count == 2)
        let resolved = try #require(pins().first { $0.accessibilityLabel() == "Resolved comment 1" })
        let open = try #require(pins().first { $0.accessibilityLabel() == "Comment 2" })
        #expect(resolved.alphaValue < open.alphaValue)
        #expect(resolved.layer?.shadowOpacity == 0)
        let areaAlphas = areas().compactMap { $0.strokeColor?.alpha }.sorted()
        #expect(areaAlphas.count == 2 && areaAlphas[0] < areaAlphas[1])

        let before = doc.workspace.serialize()
        toggle.performClick(nil)
        #expect(panel.hidesResolved && toggle.state == .on)
        #expect(toggle.accessibilityLabel() == "Show Resolved Comments")
        #expect(table.numberOfRows == 1 && pins().count == 1 && areas().count == 1)
        #expect(pins().first?.accessibilityLabel() == "Comment 2")
        // Hidden pins must not retain invisible mouse targets.
        #expect(overlay.hitTest(NSPoint(x: resolved.frame.midX, y: resolved.frame.midY)) == nil)
        #expect(doc.workspace.serialize() == before && !undo.canUndo)

        // Row zero now belongs to the second annotation. Its action must
        // resolve that annotation, not the hidden original first row.
        let cell = try #require(panel.tableView(table, viewFor: nil, row: 0))
        let status = try #require(find(NSButton.self, in: cell, where: { $0.accessibilityIdentifier() == "commentStatus.open" }))
        undo.beginUndoGrouping(); status.performClick(nil); undo.endUndoGrouping()
        #expect(doc.workspace.annotations.allSatisfy { $0.resolved })
        #expect(table.numberOfRows == 0 && pins().isEmpty && areas().isEmpty)
        #expect(find(NSTextField.self, in: panel, where: { $0.stringValue == "All comments resolved" })?.isHidden == false)
        undo.undo()
        #expect(table.numberOfRows == 1 && pins().count == 1 && areas().count == 1)
        #expect(doc.workspace.annotations.first { $0.id == "open" }?.resolved == false)
        toggle.performClick(nil)
        #expect(!panel.hidesResolved && toggle.state == .off)
        #expect(table.numberOfRows == 2 && pins().count == 2 && areas().count == 2)
        #expect(doc.workspace.serialize() == before)
    }

    @Test func pinPayloadPreservesResolvedStatusAndOlderPayloadsDefaultToOpen() throws {
        let old = try #require(PinModel.parse(["id": "old", "num": 1]))
        #expect(!old.resolved)
        let done = try #require(PinModel.parse(["id": "done", "num": 2, "resolved": true]))
        #expect(done.resolved)
        var ann = PostLaunchWorkflowTests().annotation("resolved")
        ann.resolved = true
        #expect(PinModel.from(ann).resolved)
    }
}
