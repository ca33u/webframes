import AppKit

@MainActor final class PDFPageSelectionView: NSView, NSTextFieldDelegate {
    let rangeField = NSTextField()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let pageCount: Int
    private let limit: Int
    var onValidityChange: ((Bool) -> Void)?
    var selectedPages: [Int]? { try? PDFPageImporter.pages(rangeField.stringValue, pageCount: pageCount, limit: limit) }

    init(pageCount: Int, limit: Int) {
        self.pageCount = pageCount; self.limit = limit
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 100))
        rangeField.placeholderString = "All pages, or 1–3, 7"
        rangeField.setAccessibilityIdentifier("pdfPageRange")
        rangeField.setAccessibilityLabel("PDF page numbers or ranges")
        rangeField.delegate = self
        let label = NSTextField(labelWithString: "Pages")
        status.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [label, rangeField, status]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 8; stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), rangeField.widthAnchor.constraint(equalTo: widthAnchor), status.widthAnchor.constraint(equalTo: widthAnchor)])
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func controlTextDidChange(_ obj: Notification) { refresh() }
    func refresh() {
        if let pages = selectedPages {
            status.stringValue = "\(pages.count) page\(pages.count == 1 ? "" : "s") → \(pages.count) frame\(pages.count == 1 ? "" : "s"). Added together with one Undo."
            status.textColor = .secondaryLabelColor; onValidityChange?(true)
        } else {
            status.stringValue = "Choose up to \(limit) pages, using numbers from 1 to \(pageCount)."
            status.textColor = .systemRed; onValidityChange?(false)
        }
    }
}

/// Prepare the complete batch before mutating either the panel or the board.
/// Cancelling a page picker, a render, or the owning task discards all prepared pages.
@MainActor enum PDFImportUI {
    static func prepare(_ urls: [URL], window: NSWindow,
                        imageItems: @escaping (URL) -> [[String: Any]],
                        completion: @escaping ([[String: Any]]) -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            var items: [[String: Any]] = [], pdfCount = 0, imageBytes = 0
            var fileName = ""
            do {
                for url in urls {
                    fileName = url.lastPathComponent
                    try Task.checkCancellation()
                    if !PDFPageImporter.isPDF(url) { items += imageItems(url); continue }
                    let loader = Task.detached(priority: .userInitiated) { try PDFPageImporter.load(url) }
                    let source = try await withTaskCancellationHandler(operation: { try await loader.value }, onCancel: { loader.cancel() })
                    try Task.checkCancellation()
                    guard window.isVisible else { throw CancellationError() }
                    guard pdfCount < PDFPageImporter.maxPages else { throw PDFImportError.tooManyPages }
                    guard let selection = await choosePages(source, limit: PDFPageImporter.maxPages - pdfCount, window: window) else { throw CancellationError() }
                    try Task.checkCancellation()
                    let pages = try await render(source, pages: selection, window: window)
                    pdfCount += pages.count; imageBytes += pages.reduce(0) { $0 + $1.png.count }
                    guard imageBytes <= PDFPageImporter.maxImageBytes else { throw PDFImportError.imagesTooLarge }
                    items += pages.map(\.specItem)
                }
                try Task.checkCancellation()
                guard window.isVisible else { throw CancellationError() }
                completion(items)
            } catch is CancellationError {
                completion([])
            } catch {
                completion([])
                guard window.isVisible else { return }
                let alert = NSAlert(); alert.messageText = "Couldn’t import PDF pages"
                alert.informativeText = "\(fileName)\n\n\(error.localizedDescription)"; alert.addButton(withTitle: "OK")
                _ = await alert.beginSheetModal(for: window)
            }
        }
    }

    private static func choosePages(_ source: PDFImportSource, limit: Int, window: NSWindow) async -> [Int]? {
        let alert = NSAlert(); alert.messageText = "Import PDF pages"
        alert.informativeText = "\(source.fileName) · \(source.pageCount) pages\nEach selected page becomes an image frame saved with this board."
        alert.addButton(withTitle: "Import Pages"); alert.addButton(withTitle: "Cancel")
        alert.window.setAccessibilityIdentifier("pdfPageSelection")
        let view = PDFPageSelectionView(pageCount: source.pageCount, limit: limit)
        view.onValidityChange = { [weak alert] valid in alert?.buttons.first?.isEnabled = valid }
        alert.accessoryView = view; view.refresh()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn ? view.selectedPages : nil)
                }
                alert.window.makeFirstResponder(view.rangeField)
            }
        }, onCancel: {
            Task { @MainActor in
                if alert.window.sheetParent != nil { window.endSheet(alert.window, returnCode: .abort) }
            }
        })
    }

    private static func render(_ source: PDFImportSource, pages: [Int], window: NSWindow) async throws -> [ImportedPDFPage] {
        let worker = Task.detached(priority: .userInitiated) { try PDFPageImporter.render(source, pages: pages) }
        let alert = NSAlert(); alert.messageText = "Importing \(pages.count) PDF pages…"
        alert.informativeText = "\(source.fileName)\nPreparing images. The board will change only when all selected pages are ready."
        alert.addButton(withTitle: "Cancel")
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 320, height: 20))
        spinner.isIndeterminate = true; spinner.startAnimation(nil); alert.accessoryView = spinner
        alert.beginSheetModal(for: window) { _ in worker.cancel() }
        defer { if alert.window.sheetParent != nil { window.endSheet(alert.window) } }
        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        guard !worker.isCancelled else { throw CancellationError() }
        return result
    }
}
