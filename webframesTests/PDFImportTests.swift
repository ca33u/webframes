import AppKit
import PDFKit
import Testing
@testable import Web_Frames

@Suite("PDF page import", .serialized) @MainActor struct PDFImportTests {
    private func fixture(count: Int = 3) throws -> Data {
        let output = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: output))
        let context = try #require(CGContext(consumer: consumer, mediaBox: nil, nil))
        for index in 0..<count {
            var box = index == 1 ? CGRect(x: 0, y: 0, width: 400, height: 200) : CGRect(x: 0, y: 0, width: 220, height: 300)
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            context.setFillColor(NSColor.white.cgColor); context.fill(box)
            context.setFillColor(NSColor.red.cgColor); context.fill(CGRect(x: 5, y: 5, width: 30, height: 30))
            context.setFillColor(NSColor.blue.cgColor); context.fill(CGRect(x: box.width - 35, y: box.height - 35, width: 30, height: 30))
            if index == 2 {
                context.setFillColor(NSColor.green.cgColor); context.fill(CGRect(x: 40, y: 20, width: 120, height: 160))
            }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: "PDF page \(index + 1)", attributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
                .draw(at: CGPoint(x: 45, y: 70))
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF()
        let document = try #require(PDFDocument(data: output as Data))
        if count > 1 { document.page(at: 1)?.rotation = 90 }
        if count > 2 { document.page(at: 2)?.setBounds(CGRect(x: 40, y: 20, width: 120, height: 160), for: .cropBox) }
        let annotation = PDFAnnotation(bounds: CGRect(x: 100, y: 110, width: 40, height: 40), forType: .square, withProperties: nil)
        annotation.color = .orange; annotation.interiorColor = .orange; document.page(at: 0)?.addAnnotation(annotation)
        if count > 1 {
            let rotated = PDFAnnotation(bounds: CGRect(x: 100, y: 110, width: 40, height: 40), forType: .square, withProperties: nil)
            rotated.color = .orange; rotated.interiorColor = .orange; document.page(at: 1)?.addAnnotation(rotated)
        }
        if count > 2 {
            let cropped = PDFAnnotation(bounds: CGRect(x: 70, y: 40, width: 30, height: 30), forType: .square, withProperties: nil)
            cropped.color = .orange; cropped.interiorColor = .orange; document.page(at: 2)?.addAnnotation(cropped)
        }
        return try #require(document.dataRepresentation())
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WebFrames-PDF-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }

    @Test func pageRangesAreBoundedSortedAndDeduplicated() throws {
        #expect(try PDFPageImporter.pages("3, 1–2, 2", pageCount: 7) == [1, 2, 3])
        #expect(try PDFPageImporter.pages("", pageCount: 3) == [1, 2, 3])
        for text in ["0", "4", "2-1", "1,", "-1", "1-2-3", "word", "1, 99999999999999999999"] {
            #expect(throws: (any Error).self) { try PDFPageImporter.pages(text, pageCount: 3) }
        }
        #expect(throws: (any Error).self) { try PDFPageImporter.pages("", pageCount: 51) }
        #expect(throws: (any Error).self) { try PDFPageImporter.pages("1-500000", pageCount: 500000) }
        #expect(try PDFPageImporter.pages("10-12", pageCount: 500000) == [10, 11, 12])
    }

    @Test func rendersRotationCropAnnotationsAndOpaqueBackground() throws {
        let data = try fixture(), source = try PDFPageImporter.source(data: data, fileName: "Research.v2.pdf")
        let pages = try PDFPageImporter.render(source, pages: [1, 2, 3])
        #expect(pages.map(\.origin.pageNumber) == [1, 2, 3])
        #expect(pages.map(\.width) == [440, 400, 240]); #expect(pages.map(\.height) == [600, 800, 320])
        let first = try #require(NSBitmapImageRep(data: pages[0].png))
        let annotation = try #require(first.colorAt(x: 240, y: 340)?.usingColorSpace(.deviceRGB))
        #expect(annotation.redComponent > 0.9 && annotation.greenComponent > 0.3 && annotation.greenComponent < 0.8)
        let white = try #require(first.colorAt(x: 90, y: 25)?.usingColorSpace(.deviceRGB))
        #expect(white.redComponent > 0.95 && white.greenComponent > 0.95 && white.alphaComponent == 1)
        let rotated = try #require(NSBitmapImageRep(data: pages[1].png))
        let rotatedAnnotation = try #require(rotated.colorAt(x: 260, y: 240)?.usingColorSpace(.deviceRGB))
        #expect(rotatedAnnotation.redComponent > 0.9 && rotatedAnnotation.greenComponent > 0.3 && rotatedAnnotation.greenComponent < 0.8)
        let cropped = try #require(NSBitmapImageRep(data: pages[2].png))
        let green = try #require(cropped.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        #expect(green.greenComponent > 0.9 && green.redComponent < 0.1)
        let croppedAnnotation = try #require(cropped.colorAt(x: 90, y: 250)?.usingColorSpace(.deviceRGB))
        #expect(croppedAnnotation.redComponent > 0.9 && croppedAnnotation.greenComponent > 0.3 && croppedAnnotation.greenComponent < 0.8)
        if let path = ProcessInfo.processInfo.environment["WEBFRAMES_PDF_EVIDENCE_DIR"] {
            let root = URL(fileURLWithPath: path); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent("Research.v2.pdf"))
            for page in pages { try page.png.write(to: root.appendingPathComponent("page-\(page.origin.pageNumber).png")) }
        }
    }

    @Test func customFrameNameKeepsPageNumbersAndMetadata() throws {
        let source = try PDFPageImporter.source(data: fixture(), fileName: "Research.v2.pdf")
        let items = try PDFPageImporter.render(source, pages: [1, 3]).map(\.specItem)
        var number = 0
        let frames = AddFrameSpecApplier.frames(for: ["kind": "image", "images": items, "label": "Competitor A"],
            existingFrameCount: 0, viewport: .identity, allocateNum: { number += 1; return number }, generateId: { UUID().uuidString })
        #expect(frames.map(\.label) == ["Competitor A · Page 1", "Competitor A · Page 3"])
        #expect(frames.allSatisfy { $0.extras["pdfPage"] != nil && $0.filePath == nil })
    }

    @Test func rejectsCorruptLockedAndOversizedFiles() throws {
        #expect(throws: (any Error).self) { try PDFPageImporter.source(data: Data("Not a PDF".utf8), fileName: "bad.pdf") }
        let document = try #require(PDFDocument(data: fixture()))
        let locked = try #require(document.dataRepresentation(options: [PDFDocumentWriteOption.ownerPasswordOption: "owner-test", PDFDocumentWriteOption.userPasswordOption: "user-test"]))
        #expect(throws: (any Error).self) { try PDFPageImporter.source(data: locked, fileName: "locked.pdf") }
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("huge.pdf"); FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url); try file.truncate(atOffset: UInt64(PDFPageImporter.maxFileBytes + 1)); try file.close()
        #expect(throws: (any Error).self) { try PDFPageImporter.load(url) }
    }

    @Test func cancelledRenderingDoesNotReturnPartialPages() async throws {
        let source = try PDFPageImporter.source(data: fixture(), fileName: "Cancel.pdf")
        let result = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return Result { try PDFPageImporter.render(source, pages: [1, 2, 3]) }
        }.value
        #expect(throws: CancellationError.self) { try result.get() }
    }

    private func saveView(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["WEBFRAMES_PDF_EVIDENCE_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path).appendingPathComponent(name))
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        Issue.record("Timed out waiting for PDF import UI"); throw CancellationError()
    }
    private func choose(_ range: String?, in window: NSWindow) async throws {
        try await waitFor { window.attachedSheet?.accessibilityIdentifier() == "pdfPageSelection" }
        let sheet = try #require(window.attachedSheet), views = descendants(try #require(sheet.contentView))
        if let range {
            let field = try #require(views.compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "pdfPageRange" })
            field.stringValue = range
            (field.delegate as? PDFPageSelectionView)?.refresh()
        }
        try saveView(try #require(sheet.contentView), name: "page-selection.png")
        let title = range == nil ? "Cancel" : "Import Pages"
        let button = try #require(views.compactMap { $0 as? NSButton }.first { $0.title == title })
        #expect(button.isEnabled); button.performClick(nil)
    }

    @Test func panelSelectionAndCancelKeepPendingImagesAtomic() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("Research.v2.pdf"); try fixture().write(to: pdf)
        let source = try PDFPageImporter.load(pdf), image = root.appendingPathComponent("existing.png")
        try PDFPageImporter.render(source, pages: [1])[0].png.write(to: image)
        let panel = ImageTabPanel(onValidityChange: {})
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = panel; window.orderFront(nil)
        defer { panel.reset(); window.orderOut(nil) }
        panel.addFilesFromURLs([image]); #expect(panel.canConfirm)
        let otherPDF = root.appendingPathComponent("Other.pdf"); try fixture().write(to: otherPDF)
        panel.addFilesFromURLs([pdf, otherPDF]); #expect(!panel.canConfirm)
        try await waitFor { window.attachedSheet?.accessibilityIdentifier() == "pdfPageSelection" }
        let firstSheet = window.attachedSheet
        try await choose("2", in: window)
        try await waitFor { window.attachedSheet?.accessibilityIdentifier() == "pdfPageSelection" && window.attachedSheet !== firstSheet }
        try await choose(nil, in: window); try await waitFor { panel.canConfirm && window.attachedSheet == nil }
        #expect((panel.currentSpec()?["images"] as? [[String: Any]])?.count == 1)
        panel.addFilesFromURLs([pdf]); try await choose("1, 3", in: window)
        try await waitFor { panel.canConfirm && window.attachedSheet == nil }
        let items = try #require(panel.currentSpec()?["images"] as? [[String: Any]])
        #expect(items.count == 3)
        #expect(items[1]["label"] as? String == "Research.v2 · Page 1")
        #expect(items[2]["label"] as? String == "Research.v2 · Page 3")
    }

    private func imagePanel(in host: CanvasHost) throws -> ImageTabPanel {
        let modal = try #require(descendants(host).compactMap { $0 as? AddFrameModal }.first)
        let tabs = try #require(descendants(modal).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 4 })
        #expect(tabs.label(forSegment: 3) == "Image / PDF")
        tabs.selectedSegment = 3; _ = tabs.sendAction(try #require(tabs.action), to: tabs.target)
        return try #require(descendants(modal).compactMap { $0 as? ImageTabPanel }.first)
    }

    @Test func fullAddFramesModalImportsAndClosingItCancelsPendingPicker() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("Research.v2.pdf"); try fixture().write(to: pdf)
        let document = makeTestDocument(); defer { document.updateChangeCount(.changeCleared); document.close() }
        let host = CanvasHost(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil); defer { host.dismissAddFrameModal(); window.orderOut(nil) }
        host.presentAddFrameModal()
        let panel = try imagePanel(in: host)
        panel.addFilesFromURLs([pdf]); try await choose("1, 3", in: window)
        try await waitFor { panel.canConfirm && window.attachedSheet == nil }
        host.layoutSubtreeIfNeeded()
        let confirm = try #require(descendants(host).compactMap { $0 as? NSButton }.first { $0.title == "Add Frames" })
        #expect(confirm.isEnabled && host.bounds.contains(host.convert(confirm.bounds, from: confirm)))
        try saveView(host, name: "add-frames-modal.png")
        confirm.performClick(nil)
        #expect(document.workspace.frames.map(\.label) == ["Research.v2 · Page 1", "Research.v2 · Page 3"])
        #expect(!host.isModalPresented)
        host.presentAddFrameModal()
        let nextPanel = try imagePanel(in: host); nextPanel.addFilesFromURLs([pdf])
        try await waitFor { window.attachedSheet?.accessibilityIdentifier() == "pdfPageSelection" }
        host.dismissAddFrameModal()
        try await waitFor { window.attachedSheet == nil }
        #expect(document.workspace.frames.count == 2 && nextPanel.currentSpec() == nil)
    }

    @Test func canvasPDFPasteIsOneUndoAndSurvivesReopenWithoutSourcePDF() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("Research.v2.pdf"); try fixture().write(to: pdf)
        let document = makeTestDocument(); defer { document.updateChangeCount(.changeCleared); document.close() }
        let undo = try #require(document.undoManager); undo.groupsByEvent = false
        undo.beginUndoGrouping()
        document.workspace.createFrame(FrameModel(id: "original", url: "about:blank", label: "Original", x: 0, y: 0, w: 500, h: 500, num: 1, isImage: false, filePath: nil, extras: [:]))
        document.workspace.createAnnotation(AnnotationModel(id: "comment", num: 1, frameId: "original", xPct: 10, yPct: 20, color: "blue", comment: "Keep this", resolved: false, edits: [:]))
        undo.endUndoGrouping(); undo.removeAllActions()
        let host = CanvasHost(document: document)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil); defer { window.orderOut(nil) }
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.writeObjects([pdf as NSURL]); #expect(host.pasteImageFrames(from: board))
        #expect(document.workspace.frames.count == 1)
        try await choose("2-3", in: window); try await waitFor { document.workspace.frames.count == 3 && window.attachedSheet == nil }
        let frames = document.workspace.frames.filter(\.isImage)
        #expect(frames.map(\.label) == ["Research.v2 · Page 2", "Research.v2 · Page 3"])
        #expect(frames[0].extras["pdfPage"] == .object(["fileName": .string("Research.v2.pdf"), "pageNumber": .number(2), "pageCount": .number(3)]))
        let originals = document.workspace.frames
        undo.undo(); #expect(document.workspace.frames.map(\.id) == ["original"])
        #expect(document.workspace.annotations.count == 1)
        undo.redo(); #expect(document.workspace.frames == originals)
        try FileManager.default.removeItem(at: pdf)
        let reopened = makeTestDocument(); defer { reopened.updateChangeCount(.changeCleared); reopened.close() }
        try reopened.read(from: document.fileWrapper(ofType: WebFramesDocument.fileTypeIdentifier), ofType: WebFramesDocument.fileTypeIdentifier)
        #expect(reopened.workspace.frames == originals)
        #expect(reopened.workspace.annotations.first?.comment == "Keep this")
        let images = try CodexCommentImages.make(frames: reopened.workspace.frames.filter(\.isImage))
        #expect(images.count == 2)
    }
}
