import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Keeps screenshots at the resolution that is actually used.
///
/// Coding agents never see more than about 2048 px: Claude downsizes images
/// whose long edge exceeds ~1568 px (or ~1.15 MP); OpenAI fits "high detail"
/// images into 2048×2048 and then scales the short side to 768 px. Web
/// Frames does not export images, so nothing needs the original pixels
/// back. Keeping Retina originals (an iPhone screenshot is 1290×2796, a
/// Mac one often 2880+ wide) only makes projects large and slow.
nonisolated enum ImageOptimizer {
    /// Long-edge cap for screen-shaped images (up to `tallRatio`).
    static let maxLongEdge = 2048
    /// Taller images are page captures: cap the width instead, so the
    /// text stays readable, and the total pixel count.
    static let tallRatio = 2.5
    static let maxTallWidth = 1440
    static let maxPixels = 16_000_000
    /// Frame pictures may be stored as JPEG when that is clearly smaller.
    static let jpegQuality = 0.9
    static let jpegAdvantage = 0.7

    enum Use {
        /// Image frames: shown on the canvas and re-encoded to PNG before
        /// going to an agent, so JPEG storage is fine.
        case frame
        /// Comment screenshots go to the agent as they are; the connector
        /// accepts PNG only.
        case commentScreenshot
    }

    struct Result: Equatable {
        let data: Data
        let mime: String
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// The scale that brings `width`×`height` within the caps (≤ 1).
    static func scale(width: Int, height: Int) -> Double {
        let w = Double(width), h = Double(height)
        let ratio = max(w, h) / max(1, min(w, h))
        let pixelCap = (Double(maxPixels) / (w * h)).squareRoot()
        if h > w && ratio > tallRatio {
            return min(1, Double(maxTallWidth) / w, pixelCap)
        }
        return min(1, Double(maxLongEdge) / max(w, h), pixelCap)
    }

    /// Downscales and re-encodes when that helps; nil keeps the original
    /// (vector, animated, already compact, or unreadable).
    static func optimize(_ data: Data, mime: String, use: Use = .frame) -> Result? {
        let lower = mime.lowercased()
        guard lower != "image/svg+xml", lower != "image/gif",
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }

        let factor = scale(width: width, height: height)
        let needsResize = factor < 0.999
        let pngOrJPEG = lower == "image/png" || lower == "image/jpeg" || lower == "image/jpg"
        if !needsResize && pngOrJPEG && use == .commentScreenshot { return nil }

        let longSide = max(1, Int((Double(max(width, height)) * factor).rounded()))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let png = encode(image, as: .png, quality: nil) else { return nil }
        var best = Result(data: png, mime: "image/png", pixelWidth: image.width, pixelHeight: image.height)
        if use == .frame, !hasAlpha(image), let jpeg = encode(image, as: .jpeg, quality: jpegQuality),
           Double(jpeg.count) < Double(png.count) * jpegAdvantage {
            best = Result(data: jpeg, mime: "image/jpeg", pixelWidth: image.width, pixelHeight: image.height)
        }
        // Keep the original when re-encoding would not make it smaller.
        guard needsResize || !pngOrJPEG || best.data.count < data.count * 9 / 10 else { return nil }
        return best.data.count < data.count || !pngOrJPEG ? best : nil
    }

    /// Same for a `data:image/…;base64,` URL; returns the input when nothing
    /// is gained.
    static func optimize(dataURL: String, use: Use = .frame) -> String {
        guard dataURL.hasPrefix("data:image/"), let comma = dataURL.firstIndex(of: ","),
              dataURL[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) else { return dataURL }
        let mime = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma].dropLast(";base64".count))
        guard let result = optimize(data, mime: mime, use: use) else { return dataURL }
        return "data:\(result.mime);base64," + result.data.base64EncodedString()
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default:
            // Screenshots often carry an alpha channel that is fully opaque.
            return !isOpaque(image)
        }
    }

    /// Samples the image's alpha on a small grid.
    private static func isOpaque(_ image: CGImage) -> Bool {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 255 }
    }

    private static func encode(_ image: CGImage, as type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
