import AppKit
import Testing
@testable import Web_Frames

@MainActor
@Suite("Comments panel")
struct AnnotationPanelTests {

    private func preferences() throws -> (UserDefaults, String) {
        let suite = "webframes-comment-filter-tests." + UUID().uuidString
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

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
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = AnnotationPanel(preferences: defaults)
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
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = AnnotationPanel(preferences: defaults)
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
        let (defaults, suite) = try preferences()
        let host = CanvasHost(document: doc, preferences: defaults)
        defer { host.tearDown(); doc.updateChangeCount(.changeCleared); doc.close(); defaults.removePersistentDomain(forName: suite) }
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

    @Test func filterChoicePersistsOnDiskAndRestoresBothButtonStates() throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        var panel = AnnotationPanel(preferences: defaults)
        #expect(!panel.hidesResolved)
        for hidden in [true, false] {
            let toggle = try #require(find(NSButton.self, in: panel, where: { $0.accessibilityIdentifier() == "comments.hideResolved" }))
            toggle.performClick(nil)
            #expect(panel.hidesResolved == hidden)
            // Flush only in the test so a separate process can verify the
            // saved preference, independently of UserDefaults' memory cache.
            #expect(defaults.synchronize())
            let query = Process()
            query.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            query.arguments = ["read", suite, AnnotationPanel.hidesResolvedPreferenceKey]
            let output = Pipe()
            query.standardOutput = output
            query.standardError = Pipe()
            try query.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            query.waitUntilExit()
            #expect(query.terminationStatus == 0)
            #expect(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == (hidden ? "1" : "0"))

            let freshDefaults = try #require(UserDefaults(suiteName: suite))
            panel = AnnotationPanel(preferences: freshDefaults)
            #expect(panel.hidesResolved == hidden)
            let restoredToggle = try #require(find(NSButton.self, in: panel, where: { $0.accessibilityIdentifier() == "comments.hideResolved" }))
            #expect(restoredToggle.state == (hidden ? .on : .off))
            #expect(restoredToggle.accessibilityLabel() == (hidden ? "Show Resolved Comments" : "Hide Resolved Comments"))
        }
    }

    @Test(arguments: [true, false])
    func savedFilterAppliesToRestoredBoardWithoutClicking(hidden: Bool) throws {
        let (defaults, suite) = try preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        AnnotationPanel(preferences: defaults).setHidesResolved(hidden)
        #expect(defaults.synchronize())

        let source = try PostLaunchWorkflowTests().document()
        let reopened = try PostLaunchWorkflowTests().document()
        defer {
            source.updateChangeCount(.changeCleared); source.close()
            reopened.updateChangeCount(.changeCleared); reopened.close()
        }
        source.workspace.createFrame(FrameModel(id: "f", url: "about:blank", label: "Review", x: 100, y: 100,
            w: 300, h: 400, num: 1, isImage: false, filePath: nil))
        for (id, resolved, num) in [("open", false, 1), ("done", true, 2)] {
            var ann = AnnotationModel(id: id, num: num, frameId: "f", xPct: CGFloat(num * 20), yPct: 20,
                color: "blue", comment: id, resolved: resolved, edits: [:], frameUrl: nil, frameLabel: nil)
            if resolved { ann.areaSizePct = CGSize(width: 20, height: 30) }
            source.workspace.createAnnotation(ann)
        }
        let snapshot = source.workspace.serialize()
        try reopened.read(from: JSONEncoder().encode(snapshot), ofType: WebFramesDocument.fileTypeIdentifier)
        let freshDefaults = try #require(UserDefaults(suiteName: suite))
        let host = CanvasHost(document: reopened, preferences: freshDefaults)
        defer { host.tearDown() }
        let table = try #require(find(NSTableView.self, in: host.annotationPanel))
        let card = try #require(host.frameLayer.subviews.compactMap { $0 as? FrameCardView }.first)
        let overlay = card.container.pinOverlay
        let pins = overlay.subviews.compactMap { $0 as? PinDotView }
        let areas = overlay.layer?.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
        #expect(host.annotationPanel.hidesResolved == hidden)
        #expect(table.numberOfRows == (hidden ? 1 : 2))
        #expect(pins.count == (hidden ? 1 : 2))
        #expect(areas.count == (hidden ? 0 : 1))
        #expect(pins.contains { $0.accessibilityLabel() == "Comment 1" })
        #expect(pins.contains { $0.accessibilityLabel() == "Resolved comment 2" } == !hidden)
        #expect(reopened.workspace.serialize() == snapshot)
    }
}
