import CoreGraphics

/// Geometry is in canvas coordinates; the attraction radius is in screen points.
nonisolated enum FrameSnapping {
    struct Guide: Equatable {
        let start: CGPoint
        let end: CGPoint
    }
    struct Result {
        var delta: CGPoint
        var guides: [Guide]
    }
    static func snap(bounds: CGRect, delta: CGPoint, targets: [CGRect], scale: CGFloat) -> Result {
        guard scale.isFinite, scale > 0, !targets.isEmpty else { return Result(delta: delta, guides: []) }
        let moved = bounds.offsetBy(dx: delta.x, dy: delta.y)
        let threshold = 6 / scale
        func nearest(horizontal: Bool) -> (CGFloat, CGFloat, CGRect)? {
            let anchors = horizontal ? [moved.minX, moved.midX, moved.maxX] : [moved.minY, moved.midY, moved.maxY]
            var best: (CGFloat, CGFloat, CGRect)?
            for target in targets {
                let values = horizontal ? [target.minX, target.midX, target.maxX] : [target.minY, target.midY, target.maxY]
                for value in values {
                    for anchor in anchors {
                        let correction = value - anchor
                        guard abs(correction) <= threshold else { continue }
                        if best == nil || abs(correction) < abs(best!.0) ||
                            (abs(correction) == abs(best!.0) && value < best!.1) {
                            best = (correction, value, target)
                        }
                    }
                }
            }
            return best
        }
        let x = nearest(horizontal: true), y = nearest(horizontal: false)
        let snapped = moved.offsetBy(dx: x?.0 ?? 0, dy: y?.0 ?? 0)
        let padding = 8 / scale
        var guides: [Guide] = []
        if let x {
            guides.append(Guide(start: CGPoint(x: x.1, y: min(snapped.minY, x.2.minY) - padding),
                                end: CGPoint(x: x.1, y: max(snapped.maxY, x.2.maxY) + padding)))
        }
        if let y {
            guides.append(Guide(start: CGPoint(x: min(snapped.minX, y.2.minX) - padding, y: y.1),
                                end: CGPoint(x: max(snapped.maxX, y.2.maxX) + padding, y: y.1)))
        }
        return Result(delta: CGPoint(x: delta.x + (x?.0 ?? 0), y: delta.y + (y?.0 ?? 0)), guides: guides)
    }
}
