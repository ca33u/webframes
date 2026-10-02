import AppKit

/// Pure world-coordinate geometry; the caller groups these moves into one undo step.
enum FrameArrangement: String, CaseIterable {
    case left = "Align Left", horizontalCenter = "Align Horizontal Centers", right = "Align Right"
    case top = "Align Top", verticalCenter = "Align Vertical Centers", bottom = "Align Bottom"
    case horizontalSpacing = "Distribute Horizontally", verticalSpacing = "Distribute Vertically"
    case tidyUp = "Tidy Up"

    func positions(for frames: [FrameModel]) -> [String: CGPoint] {
        guard frames.count >= 2 else { return [:] }
        if self == .tidyUp { return Self.tidyPositions(frames) }
        let minX = frames.map(\.x).min()!, minY = frames.map(\.y).min()!
        let maxX = frames.map { $0.x + $0.w }.max()!, maxY = frames.map { $0.y + $0.h }.max()!
        var result = Dictionary(uniqueKeysWithValues: frames.map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
        if self == .horizontalSpacing || self == .verticalSpacing {
            guard frames.count >= 3 else { return [:] }
            let horizontal = self == .horizontalSpacing
            let sorted = frames.sorted {
                let a = horizontal ? $0.x : $0.y, b = horizontal ? $1.x : $1.y
                return a == b ? $0.id < $1.id : a < b
            }
            // Keep the first and last cards fixed, including when their sizes differ.
            let first = sorted.first!, last = sorted.last!
            let start = horizontal ? first.x : first.y
            let end = horizontal ? last.x + last.w : last.y + last.h
            let occupied = sorted.reduce(CGFloat.zero) { $0 + (horizontal ? $1.w : $1.h) }
            let gap = (end - start - occupied) / CGFloat(sorted.count - 1)
            var cursor = start
            for f in sorted {
                result[f.id] = CGPoint(x: horizontal ? cursor : f.x, y: horizontal ? f.y : cursor)
                cursor += (horizontal ? f.w : f.h) + gap
            }
            return result
        }
        for f in frames {
            var p = CGPoint(x: f.x, y: f.y)
            switch self {
            case .left: p.x = minX
            case .horizontalCenter: p.x = (minX + maxX - f.w) / 2
            case .right: p.x = maxX - f.w
            case .top: p.y = minY
            case .verticalCenter: p.y = (minY + maxY - f.h) / 2
            case .bottom: p.y = maxY - f.h
            default: break
            }
            result[f.id] = p
        }
        return result
    }
}

// MARK: - Tidy up

extension FrameArrangement {
    /// Figma's Tidy Up: a grid with equal gaps, keeping reading order (rows
    /// top to bottom, left to right within a row) and roughly the current
    /// overall shape. Columns take their widest frame, rows their tallest;
    /// each frame sits at the top-left of its cell. The grid starts at the
    /// selection's top-left corner.
    static func tidyPositions(_ frames: [FrameModel]) -> [String: CGPoint] {
        let n = frames.count
        guard n >= 2 else { return [:] }
        let minX = frames.map(\.x).min()!, minY = frames.map(\.y).min()!
        let maxX = frames.map { $0.x + $0.w }.max()!, maxY = frames.map { $0.y + $0.h }.max()!
        let cellW = max(1, frames.map(\.w).max()!), cellH = max(1, frames.map(\.h).max()!)
        let gap = min(80, max(16, (min(cellW, cellH) * 0.08).rounded()))

        // Columns that keep the selection's aspect ratio for cells of this shape.
        let aspect = max(0.01, (maxX - minX) / max(1, maxY - minY))
        let ideal = (Double(n) * Double(aspect) * Double(cellH / cellW)).squareRoot()
        let columns = min(n, max(1, Int(ideal.rounded())))

        // Reading order: band by vertical center, then left to right.
        let byRow = frames.sorted {
            let a = $0.y + $0.h / 2, b = $1.y + $1.h / 2
            return a == b ? $0.x < $1.x : a < b
        }
        var rows: [[FrameModel]] = stride(from: 0, to: n, by: columns).map {
            Array(byRow[$0..<min($0 + columns, n)]).sorted { $0.x == $1.x ? $0.id < $1.id : $0.x < $1.x }
        }
        if rows.isEmpty { rows = [byRow] }

        var colWidths = [CGFloat](repeating: 0, count: columns)
        for row in rows { for (c, f) in row.enumerated() { colWidths[c] = max(colWidths[c], f.w) } }
        var result: [String: CGPoint] = [:]
        var y = minY
        for row in rows {
            var x = minX
            for (c, f) in row.enumerated() {
                result[f.id] = CGPoint(x: x, y: y)
                x += colWidths[c] + gap
            }
            y += (row.map(\.h).max() ?? 0) + gap
        }
        return result
    }
}

// MARK: - Toolbar and shortcuts

extension FrameArrangement {
    /// Aligning needs two frames; distributing needs three.
    var minimumSelection: Int { self == .horizontalSpacing || self == .verticalSpacing ? 3 : 2 }

    /// Index in `allCases` where a new toolbar/menu group starts.
    static let groupStarts: Set<Int> = [3, 6, 8]

    var symbolName: String {
        switch self {
        case .left: return "align.horizontal.left"
        case .horizontalCenter: return "align.horizontal.center"
        case .right: return "align.horizontal.right"
        case .top: return "align.vertical.top"
        case .verticalCenter: return "align.vertical.center"
        case .bottom: return "align.vertical.bottom"
        case .horizontalSpacing: return "distribute.horizontal.center"
        case .verticalSpacing: return "distribute.vertical.center"
        case .tidyUp: return "square.grid.2x2"
        }
    }

    /// Figma's shortcuts: ⌥A ⌥H ⌥D ⌥W ⌥V ⌥S, distribute ⌃⌥H / ⌃⌥V, tidy up ⌃⌥T.
    var keyEquivalent: String {
        switch self {
        case .left: return "a"
        case .horizontalCenter, .horizontalSpacing: return "h"
        case .right: return "d"
        case .top: return "w"
        case .verticalCenter, .verticalSpacing: return "v"
        case .bottom: return "s"
        case .tidyUp: return "t"
        }
    }

    var keyModifiers: NSEvent.ModifierFlags {
        [.horizontalSpacing, .verticalSpacing, .tidyUp].contains(self) ? [.control, .option] : [.option]
    }

    var shortcutLabel: String {
        (keyModifiers.contains(.control) ? "⌃" : "") + "⌥" + keyEquivalent.uppercased()
    }
}

// MARK: - Stacking order

/// Figma's layer order commands. The workspace frame list runs from front
/// (index 0, drawn on top) to back, like a layers panel.
enum FrameStacking: String, CaseIterable {
    case bringForward = "Bring Forward", sendBackward = "Send Backward"
    case bringToFront = "Bring to Front", sendToBack = "Send to Back"

    var keyEquivalent: String { self == .bringForward || self == .bringToFront ? "]" : "[" }
    var keyModifiers: NSEvent.ModifierFlags { self == .bringToFront || self == .sendToBack ? [.command, .option] : [.command] }

    /// New front-to-back order; selected frames keep their relative order.
    func reordered(_ ids: [String], selected: Set<String>) -> [String] {
        let chosen = ids.filter { selected.contains($0) }
        guard !chosen.isEmpty else { return ids }
        switch self {
        case .bringToFront: return chosen + ids.filter { !selected.contains($0) }
        case .sendToBack:   return ids.filter { !selected.contains($0) } + chosen
        case .bringForward:
            // Toward index 0: each selected frame jumps over the unselected
            // frame directly in front of it.
            var order = ids
            for index in order.indices.dropFirst() where selected.contains(order[index]) && !selected.contains(order[index - 1]) {
                order.swapAt(index, index - 1)
            }
            return order
        case .sendBackward:
            var order = ids
            for index in order.indices.dropLast().reversed() where selected.contains(order[index]) && !selected.contains(order[index + 1]) {
                order.swapAt(index, index + 1)
            }
            return order
        }
    }
}
