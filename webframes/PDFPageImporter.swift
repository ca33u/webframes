import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

nonisolated struct PDFPageOrigin: Codable, Hashable, Sendable {
    let fileName: String
    let pageNumber: Int
    let pageCount: Int

    var isValid: Bool {
        !fileName.isEmpty && fileName == (fileName as NSString).lastPathComponent
            && pageNumber > 0 && pageNumber <= pageCount
    }

    @MainActor var jsonValue: JSONValue {
        .object(["fileName": .string(fileName), "pageNumber": .number(Double(pageNumber)),
                 "pageCount": .number(Double(pageCount))])
    }
}

nonisolated struct PDFImportSource: Sendable {
    let data: Data
    let fileName: String
    let pageCount: Int
}

nonisolated struct ImportedPDFPage: Sendable {
    let png: Data
    let width: Int
    let height: Int
    let origin: PDFPageOrigin

    @MainActor var specItem: [String: Any] {
        let title = "\((origin.fileName as NSString).deletingPathExtension) · Page \(origin.pageNumber)"
        return ["name": title, "label": title, "dataURL": "data:image/png;base64," + png.base64EncodedString(),
                "natW": width, "natH": height,
                "pdfPage": ["fileName": origin.fileName, "pageNumber": origin.pageNumber, "pageCount": origin.pageCount]]
    }
}

nonisolated enum PDFImportError: LocalizedError {
    case unreadable, locked, fileTooLarge, tooManyPages, invalidPages, rendering(Int), imagesTooLarge
    var errorDescription: String? {
        switch self {
        case .unreadable: return "This file is not a readable PDF with pages."
        case .locked: return "This PDF is locked. Unlock it in Preview and save an unlocked copy before importing."
        case .fileTooLarge: return "Choose a PDF smaller than 100 MB."
        case .tooManyPages: return "Import up to 50 PDF pages at a time. Choose a smaller range."
        case .invalidPages: return "Enter page numbers such as 1–3, 7, within this PDF’s page count."
        case .rendering(let page): return "Page \(page) could not be rendered. No pages were added."
        case .imagesTooLarge: return "These pages produce too much image data. Import a smaller range."
        }
    }
}

/// Each worker opens its own PDFDocument. No PDFKit objects cross actor boundaries.
nonisolated enum PDFPageImporter {
    static let maxPages = 50
    static let maxFileBytes = 100 * 1024 * 1024
    static let maxImageBytes = 64 * 1024 * 1024
    static let maxLongEdge = 2048

    static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }

    static func load(_ url: URL) throws -> PDFImportSource {
        try Task.checkCancellation()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw PDFImportError.unreadable }
        guard let size = values.fileSize, size <= maxFileBytes else { throw PDFImportError.fileTooLarge }
        return try source(data: Data(contentsOf: url), fileName: url.lastPathComponent)
    }

    static func source(data: Data, fileName: String) throws -> PDFImportSource {
        guard data.count <= maxFileBytes else { throw PDFImportError.fileTooLarge }
        guard let document = PDFDocument(data: data) else { throw PDFImportError.unreadable }
        guard !document.isLocked else { throw PDFImportError.locked }
        guard document.pageCount > 0 else { throw PDFImportError.unreadable }
        return PDFImportSource(data: data, fileName: fileName, pageCount: document.pageCount)
    }

    /// One-based, sorted and deduplicated. Validate bounds before expanding any range.
    static func pages(_ text: String, pageCount: Int, limit: Int = maxPages) throws -> [Int] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pageCount > 0 else { throw PDFImportError.unreadable }
        if text.isEmpty {
            guard pageCount <= limit else { throw PDFImportError.tooManyPages }
            return Array(1...pageCount)
        }
        var result = Set<Int>()
        for part in text.replacingOccurrences(of: "–", with: "-").split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count),
                  let first = Int(bounds[0].trimmingCharacters(in: .whitespaces)), first >= 1,
                  let last = Int(bounds.last!.trimmingCharacters(in: .whitespaces)), last >= first,
                  last <= pageCount else { throw PDFImportError.invalidPages }
            guard last - first + 1 <= limit else { throw PDFImportError.tooManyPages }
            result.formUnion(first...last)
            guard result.count <= limit else { throw PDFImportError.tooManyPages }
        }
        return result.sorted()
    }

    static func render(_ source: PDFImportSource, pages: [Int]) throws -> [ImportedPDFPage] {
        guard !pages.isEmpty, pages == Array(Set(pages)).sorted(),
              pages.allSatisfy({ $0 >= 1 && $0 <= source.pageCount }) else { throw PDFImportError.invalidPages }
        guard pages.count <= maxPages else { throw PDFImportError.tooManyPages }
        guard let document = PDFDocument(data: source.data), !document.isLocked,
              document.pageCount == source.pageCount else { throw PDFImportError.unreadable }
        var bytes = 0
        return try pages.map { number in
            try Task.checkCancellation()
            return try autoreleasepool {
                guard let page = document.page(at: number - 1), page.pageRef != nil else { throw PDFImportError.rendering(number) }
                let box = page.bounds(for: .cropBox)
                guard box.width.isFinite, box.height.isFinite, box.minX.isFinite, box.minY.isFinite,
                      box.maxX.isFinite, box.maxY.isFinite, box.width > 0, box.height > 0 else { throw PDFImportError.rendering(number) }
                let rotated = ((page.rotation % 360 + 360) % 360) % 180 != 0
                let width = rotated ? box.height : box.width, height = rotated ? box.width : box.height
                let scale = min(2, CGFloat(maxLongEdge) / max(width, height))
                let w = max(1, Int((width * scale).rounded())), h = max(1, Int((height * scale).rounded()))
                guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PDFImportError.rendering(number) }
                let target = CGRect(x: 0, y: 0, width: w, height: h)
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(target)
                context.scaleBy(x: scale, y: scale)
                // PDFKit handles crop origins, inherent rotation and annotation/form
                // appearance transforms together; applying them separately doubles rotation.
                page.displaysAnnotations = true
                page.draw(with: .cropBox, to: context)
                guard let image = context.makeImage() else { throw PDFImportError.rendering(number) }
                let output = NSMutableData()
                guard let encoder = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw PDFImportError.rendering(number) }
                CGImageDestinationAddImage(encoder, image, nil)
                guard CGImageDestinationFinalize(encoder) else { throw PDFImportError.rendering(number) }
                let data = output as Data; bytes += data.count
                guard bytes <= maxImageBytes else { throw PDFImportError.imagesTooLarge }
                return ImportedPDFPage(png: data, width: w, height: h,
                    origin: PDFPageOrigin(fileName: source.fileName, pageNumber: number, pageCount: source.pageCount))
            }
        }
    }
}
