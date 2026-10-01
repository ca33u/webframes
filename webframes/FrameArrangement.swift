import AppKit

/// Pure world-coordinate geometry; the caller groups these moves into one undo step.
enum FrameArrangement: String, CaseIterable {
    case left = "Align Left", horizontalCenter = "Align Horizontal Centers", right = "Align Right"
    case top = "Align Top", verticalCenter = "Align Vertical Centers", bottom = "Align Bottom"
    case horizontalSpacing = "Distribute Horizontally", verticalSpacing = "Distribute Vertically"

    func positions(for frames: [FrameModel]) -> [String: CGPoint] {
        guard frames.count >= 2 else { return [:] }
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

// MARK: - Toolbar and shortcuts

extension FrameArrangement {
    /// Aligning needs two frames; distributing needs three.
    var minimumSelection: Int { self == .horizontalSpacing || self == .verticalSpacing ? 3 : 2 }

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
        }
    }

    /// Figma's shortcuts: ⌥A ⌥H ⌥D ⌥W ⌥V ⌥S, distribute ⌃⌥H / ⌃⌥V.
    var keyEquivalent: String {
        switch self {
        case .left: return "a"
        case .horizontalCenter, .horizontalSpacing: return "h"
        case .right: return "d"
        case .top: return "w"
        case .verticalCenter, .verticalSpacing: return "v"
        case .bottom: return "s"
        }
    }

    var keyModifiers: NSEvent.ModifierFlags {
        self == .horizontalSpacing || self == .verticalSpacing ? [.control, .option] : [.option]
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
