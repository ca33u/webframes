import AppKit

@MainActor
enum CodexCommentImages {
    static func make(frames: [FrameModel]) throws -> [String: String] {
        guard frames.count <= 5 else { throw AstraError.message("Fix with \(AgentProvider.current.name) can inspect up to 5 screenshot frames at once. Resolve or export the other comments first.") }
        var images: [String: String] = [:]
        for frame in frames {
            guard case .string(let value) = frame.extras["imgUrl"], value.hasPrefix("data:image/"),
                  let comma = value.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
                  let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
                throw AstraError.message("Could not read screenshot “\(frame.label)”. Reimport the image and try again.")
            }
            let scale = min(1, 1600 / max(image.size.width, image.size.height))
            let width = max(1, Int(image.size.width * scale)), height = max(1, Int(image.size.height * scale))
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw AstraError.message("Could not prepare screenshot “\(frame.label)”.")
            }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
                throw AstraError.message("Could not encode screenshot “\(frame.label)”.")
            }
            let url = "data:image/png;base64," + png.base64EncodedString()
            guard url.count <= 9_000_000 else { throw AstraError.message("Screenshot “\(frame.label)” is too large for \(AgentProvider.current.name).") }
            images[frame.id] = url
        }
        return images
    }
}
