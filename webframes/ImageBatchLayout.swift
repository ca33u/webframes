import CoreGraphics

/// Packs the visual card sizes, including chrome, in input order.
enum ImageBatchLayout {
    static func positions(for frames: [FrameModel], centeredAt center: CGPoint,
                          availableWidth: CGFloat, avoiding existing: [FrameModel] = []) -> [CGPoint] {
        guard !frames.isEmpty else { return [] }
        let gap: CGFloat = 48
        let sizes = frames.map { CardGeometry.cardSize(width: $0.w, height: $0.h) }
        let widest = sizes.map(\.width).max()!
        let fitting = max(1, Int(max(1, availableWidth + gap) / max(1, widest + gap)))
        let columns = min(frames.count, min(fitting, Int(Double(frames.count).squareRoot().rounded(.up))))
        let rows = (frames.count + columns - 1) / columns
        var widths = [CGFloat](repeating: 0, count: columns)
        var heights = [CGFloat](repeating: 0, count: rows)
        for (i, size) in sizes.enumerated() {
            widths[i % columns] = max(widths[i % columns], size.width)
            heights[i / columns] = max(heights[i / columns], size.height)
        }
        let size = CGSize(width: widths.reduce(0, +) + gap * CGFloat(columns - 1),
                          height: heights.reduce(0, +) + gap * CGFloat(rows - 1))
        var origin = CGPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded())
        let area = CGRect(origin: origin, size: size)
        let obstacles = existing.map { CGRect(x: $0.x, y: $0.y, width: $0.w + CardGeometry.chromeWidth, height: $0.h + CardGeometry.chromeHeight) }
        if obstacles.contains(where: { $0.insetBy(dx: -gap, dy: -gap).intersects(area) }),
           let first = obstacles.first {
            let occupied = obstacles.dropFirst().reduce(first) { $0.union($1) }
            let options = [CGPoint(x: occupied.maxX + gap, y: origin.y),
                           CGPoint(x: occupied.minX - gap - size.width, y: origin.y),
                           CGPoint(x: origin.x, y: occupied.maxY + gap),
                           CGPoint(x: origin.x, y: occupied.minY - gap - size.height)]
            origin = options.min {
                hypot($0.x - origin.x, $0.y - origin.y) < hypot($1.x - origin.x, $1.y - origin.y)
            }!
        }
        var result: [CGPoint] = []
        var y = origin.y
        for row in 0..<rows {
            var x = origin.x
            for column in 0..<columns where row * columns + column < frames.count {
                result.append(CGPoint(x: x, y: y))
                x += widths[column] + gap
            }
            y += heights[row] + gap
        }
        return result
    }
}
