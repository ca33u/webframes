import AppKit
import QuartzCore

// MARK: - Data model

/// Which frame edge a link leaves from / arrives at. Mirrors the JS
/// `fromSide` / `toSide` strings so the envelope round-trip is a
/// rawValue lookup.
enum LinkSide: String {
    case left, right, top, bottom

    /// Unit-vector tangent pointing *outward* from the frame edge. Used
    /// by the cubic-bezier control-point math — a link leaving the right
    /// edge sweeps to the right before curving toward its destination,
    /// which reads as a natural connector instead of a straight diagonal.
    fileprivate var tangent: (dx: CGFloat, dy: CGFloat) {
        switch self {
        case .left:   return (-1,  0)
        case .right:  return ( 1,  0)
        case .top:    return ( 0, -1)
        case .bottom: return ( 0,  1)
        }
    }
}

// MARK: - LinkBezierMath
//
// Pure math for the cubic bezier connectors — no AppKit, no CAShapeLayer,
// no view state. Lives here (and not inside `LinkLayerView`) so the same
// routines drive both rendering and hit testing *and* can be unit-tested
// in isolation. Keeping render and hit math behind this single surface is
// what guarantees the visible curve and the hit zone can never drift out
// of sync — the bug the JS port suffered from before `findLinkAtClient`
// and `drawLinkLine` were unified under `_linkControlPoints`.
//
// All coordinates here are **screen-space** (post-transform) — the
// caller is responsible for mapping world-space anchors through
// `scale, px, py` before invoking any of these.
enum LinkBezierMath {

    /// Port of JS `_linkControlPoints`. The tangent at each endpoint
    /// follows the frame edge it's anchored to: a horizontal tangent
    /// scales its control-point offset with the run (|dx|), a vertical
    /// tangent scales with the rise (|dy|). Clamp at 36pt so short
    /// same-side links still bow out enough to read as a connector.
    static func controlPoints(
        p0: CGPoint, p3: CGPoint,
        fromSide: LinkSide, toSide: LinkSide
    ) -> (CGPoint, CGPoint) {
        let dxAbs = abs(p3.x - p0.x)
        let dyAbs = abs(p3.y - p0.y)
        let ts = fromSide.tangent
        let te = toSide.tangent
        // JS branches on `ts.dx ? dxAbs*0.45 : dyAbs*0.45`. With ±1/0
        // tangents, that maps to: horizontal tangent → scale by x-dist,
        // vertical → scale by y-dist.
        let magFrom = max(36, ts.dx != 0 ? dxAbs * 0.45 : dyAbs * 0.45)
        let magTo   = max(36, te.dx != 0 ? dxAbs * 0.45 : dyAbs * 0.45)
        let p1 = CGPoint(x: p0.x + ts.dx * magFrom, y: p0.y + ts.dy * magFrom)
        // Both control points sit outside their frame edge, so the curve
        // enters the target along the edge's outward normal.
        let p2 = CGPoint(x: p3.x + te.dx * magTo,   y: p3.y + te.dy * magTo)
        return (p1, p2)
    }

    /// Evaluate a cubic bezier at parameter `t ∈ [0, 1]`. Straightforward
    /// De Casteljau expansion — no optimizations, not hot enough to
    /// justify obscurity.
    static func point(_ p0: CGPoint, _ p1: CGPoint,
                      _ p2: CGPoint, _ p3: CGPoint, t: CGFloat) -> CGPoint {
        let u = 1 - t
        let uu = u * u, uuu = uu * u
        let tt = t * t, ttt = tt * t
        let x = uuu*p0.x + 3*uu*t*p1.x + 3*u*tt*p2.x + ttt*p3.x
        let y = uuu*p0.y + 3*uu*t*p1.y + 3*u*tt*p2.y + ttt*p3.y
        return CGPoint(x: x, y: y)
    }

    /// Shortest distance from `p` to segment `a..b`. Same as JS
    /// `pointSegDist` — degenerate-segment case (a == b) falls back to
    /// point-point hypot.
    static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let denom = dx*dx + dy*dy
        guard denom > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / denom
        t = max(0, min(1, t))
        return hypot(p.x - (a.x + t*dx), p.y - (a.y + t*dy))
    }

    /// Returns true if `p` is within `tolerance` of the cubic bezier
    /// defined by `p0…p3`, sampled at `samples` segments. Default 24
    /// samples / 8pt tolerance match JS `findLinkAtClient` so hit zones
    /// stay aligned with rendered curves to the pixel.
    static func isPointOnBezier(
        _ p: CGPoint,
        p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint,
        tolerance: CGFloat = 8,
        samples: Int = 24
    ) -> Bool {
        var prev = p0
        for s in 1...samples {
            let cur = point(p0, p1, p2, p3, t: CGFloat(s) / CGFloat(samples))
            if distanceToSegment(p, prev, cur) <= tolerance { return true }
            prev = cur
        }
        return false
    }
}

// MARK: - LinkOrthogonalMath

/// Manhattan-style connector routing. Links leave each frame on a short
/// straight stub, then travel horizontally/vertically around expanded frame
/// bounds. Dijkstra chooses the shortest clear route and adds a small cost
/// for every bend so the result stays simple when several paths are valid.
enum LinkOrthogonalMath {
    private static let epsilon: CGFloat = 0.01

    private enum Direction: Int, Hashable {
        case none = 0, horizontal = 1, vertical = 2
    }

    private struct Edge {
        let to: Int
        let length: CGFloat
        let direction: Direction
    }

    private struct QueueEntry {
        let state: Int
        let cost: CGFloat
    }

    private struct MinHeap {
        var values: [QueueEntry] = []

        mutating func push(_ entry: QueueEntry) {
            values.append(entry)
            var index = values.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard values[index].cost < values[parent].cost else { break }
                values.swapAt(index, parent)
                index = parent
            }
        }

        mutating func pop() -> QueueEntry? {
            guard !values.isEmpty else { return nil }
            if values.count == 1 { return values.removeLast() }
            let first = values[0]
            values[0] = values.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                let right = left + 1
                var smallest = index
                if left < values.count, values[left].cost < values[smallest].cost { smallest = left }
                if right < values.count, values[right].cost < values[smallest].cost { smallest = right }
                guard smallest != index else { break }
                values.swapAt(index, smallest)
                index = smallest
            }
            return first
        }
    }

    static func route(
        p0: CGPoint,
        p3: CGPoint,
        fromSide: LinkSide,
        toSide: LinkSide,
        obstacles: [CGRect],
        stub: CGFloat = 18,
        clearance: CGFloat = 14,
        bendPenalty: CGFloat = 24
    ) -> [CGPoint] {
        let fromTangent = fromSide.tangent
        let toTangent = toSide.tangent
        let start = CGPoint(x: p0.x + fromTangent.dx * stub,
                            y: p0.y + fromTangent.dy * stub)
        let end = CGPoint(x: p3.x + toTangent.dx * stub,
                          y: p3.y + toTangent.dy * stub)

        // Endpoint frames keep their exact bounds so their own outward
        // stubs remain legal. Every other frame gains breathing room.
        let routedObstacles = obstacles.map { rect -> CGRect in
            if containsOrTouches(rect, p0) || containsOrTouches(rect, p3) {
                return rect
            }
            return rect.insetBy(dx: -clearance, dy: -clearance)
        }

        var xs: [CGFloat] = [start.x, end.x]
        var ys: [CGFloat] = [start.y, end.y]
        for rect in routedObstacles {
            xs.append(contentsOf: [rect.minX, rect.maxX])
            ys.append(contentsOf: [rect.minY, rect.maxY])
        }
        let allMinX = min(start.x, end.x, routedObstacles.map(\.minX).min() ?? start.x)
        let allMaxX = max(start.x, end.x, routedObstacles.map(\.maxX).max() ?? end.x)
        let allMinY = min(start.y, end.y, routedObstacles.map(\.minY).min() ?? start.y)
        let allMaxY = max(start.y, end.y, routedObstacles.map(\.maxY).max() ?? end.y)
        xs.append(contentsOf: [allMinX - clearance * 2, allMaxX + clearance * 2])
        ys.append(contentsOf: [allMinY - clearance * 2, allMaxY + clearance * 2])
        xs = Array(Set(xs)).sorted()
        ys = Array(Set(ys)).sorted()

        struct GridKey: Hashable { let x: Int; let y: Int }
        var points: [CGPoint] = []
        var keys: [GridKey] = []
        var pointByKey: [GridKey: Int] = [:]
        for (yIndex, y) in ys.enumerated() {
            for (xIndex, x) in xs.enumerated() {
                let point = CGPoint(x: x, y: y)
                guard !routedObstacles.contains(where: { containsInterior($0, point) }) else { continue }
                let key = GridKey(x: xIndex, y: yIndex)
                pointByKey[key] = points.count
                keys.append(key)
                points.append(point)
            }
        }

        guard let startX = xs.firstIndex(of: start.x),
              let startY = ys.firstIndex(of: start.y),
              let endX = xs.firstIndex(of: end.x),
              let endY = ys.firstIndex(of: end.y),
              let startNode = pointByKey[GridKey(x: startX, y: startY)],
              let endNode = pointByKey[GridKey(x: endX, y: endY)] else {
            return fallback(p0: p0, start: start, end: end, p3: p3)
        }

        var adjacency = Array(repeating: [Edge](), count: points.count)
        func connect(_ a: Int, _ b: Int, direction: Direction) {
            guard segmentIsClear(points[a], points[b], obstacles: routedObstacles) else { return }
            let length = abs(points[a].x - points[b].x) + abs(points[a].y - points[b].y)
            adjacency[a].append(Edge(to: b, length: length, direction: direction))
            adjacency[b].append(Edge(to: a, length: length, direction: direction))
        }

        for yIndex in ys.indices {
            let row = keys.enumerated()
                .filter { $0.element.y == yIndex }
                .sorted { $0.element.x < $1.element.x }
                .map(\.offset)
            for pair in zip(row, row.dropFirst()) { connect(pair.0, pair.1, direction: .horizontal) }
        }
        for xIndex in xs.indices {
            let column = keys.enumerated()
                .filter { $0.element.x == xIndex }
                .sorted { $0.element.y < $1.element.y }
                .map(\.offset)
            for pair in zip(column, column.dropFirst()) { connect(pair.0, pair.1, direction: .vertical) }
        }

        let stateCount = points.count * 3
        var distance = Array(repeating: CGFloat.greatestFiniteMagnitude, count: stateCount)
        var previous = Array<Int?>(repeating: nil, count: stateCount)
        let initialState = startNode * 3 + Direction.none.rawValue
        distance[initialState] = 0
        var queue = MinHeap()
        queue.push(QueueEntry(state: initialState, cost: 0))
        var finalState: Int?

        while let current = queue.pop() {
            guard current.cost <= distance[current.state] else { continue }
            let node = current.state / 3
            let direction = Direction(rawValue: current.state % 3) ?? .none
            if node == endNode { finalState = current.state; break }
            for edge in adjacency[node] {
                let turnCost = direction != .none && direction != edge.direction ? bendPenalty : 0
                let nextState = edge.to * 3 + edge.direction.rawValue
                let nextCost = current.cost + edge.length + turnCost
                if nextCost < distance[nextState] {
                    distance[nextState] = nextCost
                    previous[nextState] = current.state
                    queue.push(QueueEntry(state: nextState, cost: nextCost))
                }
            }
        }

        guard var state = finalState else {
            return fallback(p0: p0, start: start, end: end, p3: p3)
        }
        var gridRoute: [CGPoint] = []
        while true {
            gridRoute.append(points[state / 3])
            guard let prior = previous[state] else { break }
            state = prior
        }
        gridRoute.reverse()
        return simplified([p0] + gridRoute + [p3])
    }

    // MARK: User-placed bends
    //
    // A manual route alternates horizontal and vertical segments. The first
    // segment leaves p0 along fromSide's axis (its coordinate is p0's), the
    // last reaches p3 along toSide's axis, and `bends` holds the fixed
    // coordinate of every segment in between: y for a horizontal segment,
    // x for a vertical one. Moving a frame moves only the end segments, so
    // the bends the user placed stay where they are.

    static func isHorizontal(_ side: LinkSide) -> Bool { side == .left || side == .right }

    /// The polyline for `bends`, or nil when they no longer fit the sides.
    static func manualRoute(p0: CGPoint, p3: CGPoint, fromSide: LinkSide, toSide: LinkSide,
                            bends: [CGFloat]) -> [CGPoint]? {
        let segmentCount = bends.count + 2
        let firstHorizontal = isHorizontal(fromSide)
        // Segments alternate, so the last one's axis follows from the count.
        let lastHorizontal = (segmentCount - 1) % 2 == 0 ? firstHorizontal : !firstHorizontal
        guard lastHorizontal == isHorizontal(toSide) else { return nil }
        var coords: [CGFloat] = [firstHorizontal ? p0.y : p0.x]
        coords += bends
        coords.append(lastHorizontal ? p3.y : p3.x)
        var points = [p0]
        for i in 0..<(segmentCount - 1) {
            let horizontal = (i % 2 == 0) == firstHorizontal
            // Corner between segment i and i+1.
            points.append(horizontal ? CGPoint(x: coords[i + 1], y: coords[i]) : CGPoint(x: coords[i], y: coords[i + 1]))
        }
        points.append(p3)
        return points
    }

    /// Bends that reproduce `route` (an automatic or manual polyline).
    static func bends(from route: [CGPoint], fromSide: LinkSide) -> [CGFloat]? {
        let points = simplifiedRoute(route)
        guard points.count >= 4 else { return nil }            // needs an interior segment
        var result: [CGFloat] = []
        for i in 1..<(points.count - 2) {
            let a = points[i], b = points[i + 1]
            result.append(abs(a.y - b.y) < epsilon ? a.y : a.x)
        }
        // The first segment must leave along fromSide's axis.
        let firstHorizontal = abs(points[0].y - points[1].y) < epsilon
        return firstHorizontal == isHorizontal(fromSide) ? result : nil
    }

    /// Index of the interior segment of `route` under `point`, if any.
    /// `route` must be the unsimplified polyline whose interior segments
    /// match `bends` one to one (a manual route, or the simplified auto route).
    static func interiorSegment(at point: CGPoint, of route: [CGPoint], tolerance: CGFloat = 8) -> Int? {
        let points = route
        guard points.count >= 4 else { return nil }
        for i in 1..<(points.count - 2) where LinkBezierMath.distanceToSegment(point, points[i], points[i + 1]) <= tolerance {
            return i - 1
        }
        return nil
    }

    static func simplifiedRoute(_ route: [CGPoint]) -> [CGPoint] { simplified(route) }

    static func isPoint(_ point: CGPoint, on route: [CGPoint], tolerance: CGFloat = 8) -> Bool {
        guard route.count > 1 else { return false }
        for (a, b) in zip(route, route.dropFirst()) {
            if LinkBezierMath.distanceToSegment(point, a, b) <= tolerance { return true }
        }
        return false
    }

    static func segmentCrossesInterior(_ a: CGPoint, _ b: CGPoint, of rect: CGRect) -> Bool {
        if abs(a.y - b.y) < epsilon {
            guard a.y > rect.minY + epsilon, a.y < rect.maxY - epsilon else { return false }
            let lo = min(a.x, b.x), hi = max(a.x, b.x)
            return max(lo, rect.minX) < min(hi, rect.maxX) - epsilon
        }
        if abs(a.x - b.x) < epsilon {
            guard a.x > rect.minX + epsilon, a.x < rect.maxX - epsilon else { return false }
            let lo = min(a.y, b.y), hi = max(a.y, b.y)
            return max(lo, rect.minY) < min(hi, rect.maxY) - epsilon
        }
        return true
    }

    private static func segmentIsClear(_ a: CGPoint, _ b: CGPoint, obstacles: [CGRect]) -> Bool {
        !obstacles.contains { segmentCrossesInterior(a, b, of: $0) }
    }

    private static func containsInterior(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x > rect.minX + epsilon && point.x < rect.maxX - epsilon &&
        point.y > rect.minY + epsilon && point.y < rect.maxY - epsilon
    }

    private static func containsOrTouches(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX - 1 && point.x <= rect.maxX + 1 &&
        point.y >= rect.minY - 1 && point.y <= rect.maxY + 1
    }

    private static func fallback(p0: CGPoint, start: CGPoint, end: CGPoint, p3: CGPoint) -> [CGPoint] {
        let horizontalFirst = CGPoint(x: end.x, y: start.y)
        return simplified([p0, start, horizontalFirst, end, p3])
    }

    private static func simplified(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for point in points {
            if let last = result.last,
               abs(last.x - point.x) < epsilon,
               abs(last.y - point.y) < epsilon { continue }
            result.append(point)
            while result.count >= 3 {
                let a = result[result.count - 3]
                let b = result[result.count - 2]
                let c = result[result.count - 1]
                let sameX = abs(a.x - b.x) < epsilon && abs(b.x - c.x) < epsilon
                let sameY = abs(a.y - b.y) < epsilon && abs(b.y - c.y) < epsilon
                guard sameX || sameY else { break }
                result.remove(at: result.count - 2)
            }
        }
        return result
    }
}

/// Native mirror of a canvas `links[i]` plus the resolved world-space
/// anchor positions (JS `frameAnchor(f, side)` output). World-space means:
/// JS x,y units, same coordinate system as frames' `.x/.y` — NOT yet
/// multiplied by `scale` or offset by `px/py`. `LinkLayerView` applies
/// that transform at draw time, matching `drawLinkLine` in index.html.
struct NativeLink {
    let id: String
    let from: CGPoint
    let fromSide: LinkSide
    let to: CGPoint
    let toSide: LinkSide
    let selected: Bool
    let hovered: Bool
    /// World coordinates of user-placed interior segments; nil = automatic.
    var bends: [CGFloat]? = nil
}

/// Transient link-drag preview. Rendered as a ghost bezier between the
/// source frame edge and the cursor (or the snapped target edge). Only
/// one preview is ever live at a time — `LinkDragState` on `CanvasHost`
/// owns the gesture. World-space anchors, same convention as
/// `NativeLink`. Mirrors the JS `linkDrag` preview at index.html:491.
struct LinkPreview {
    let from: CGPoint
    let fromSide: LinkSide
    let to:   CGPoint
    /// `nil` while the cursor floats over empty canvas; set to the
    /// snapped edge when the drag is over a valid target frame. Drives
    /// both the bezier's far-end tangent and the arrowhead visibility.
    let toSide: LinkSide?
    /// `true` iff the drag is currently targeting a drop-eligible frame.
    /// Selects the color ramp (sky-blue) and enables the arrowhead.
    let isOverTarget: Bool
}

// MARK: - LinkLayerView

/// Messages emitted by `LinkLayerView` when the user interacts with a
/// link curve. `CanvasHost` adopts this protocol and owns the
/// selection / hover state — ephemeral UI state that doesn't belong in
/// `WorkspaceStore` (which persists).
@MainActor
protocol LinkLayerViewDelegate: AnyObject {
    /// User clicked directly on a link's bezier curve (within the hit
    /// tolerance). Nil `id` means "no link was hit" — not currently
    /// emitted by `LinkLayerView` because its hitTest returns nil when
    /// nothing is close, but kept optional for future right-click /
    /// context-menu use.
    func linkLayer(_ layer: LinkLayerView, didClickLink id: String)

    /// Pointer moved over (or off) a link curve. `id` is nil when the
    /// cursor is not near any curve. Called on every tick that the
    /// hovered id *changes* — no-op ticks are filtered inside the view
    /// so the delegate only sees meaningful transitions.
    func linkLayer(_ layer: LinkLayerView, didHoverLink id: String?)

    /// The user dragged a link segment (bends in world units) or
    /// double-clicked the link to restore automatic routing (nil).
    func linkLayer(_ layer: LinkLayerView, didSetBends bends: [CGFloat]?, forLink id: String)
}

/// Native renderer + hit-tester for the established-link bezier arrows.
///
/// Phase 6b seed: established links migrated out of the 2D
/// `<canvas id="dc">` into per-link `CAShapeLayer` pairs (one for the
/// bezier stroke, one for the triangle arrowhead). The transient
/// `linkDrag` preview — the dashed line that follows the cursor while
/// dragging a new link out of a frame-edge handle — stays in JS for
/// now; it migrates together with the rest of the frame chrome.
///
/// Phase 6e Step 2: hit-testing + hover + click-to-select also live
/// here. `hitTest(_:)` returns self only when the point is within `8pt`
/// of a bezier curve (matches JS `findLinkAtClient`), passing through
/// in the 99% of the view area where there's no curve nearby. When a
/// hit is consumed, `mouseDown(with:)` calls
/// `LinkLayerViewDelegate.linkLayer(_:didClickLink:)`. `NSTrackingArea`
/// drives hover — `mouseMoved` runs the same bezier math and emits
/// `didHoverLink:` on transitions.
///
/// Z-order: above `FrameLayerView`, below `DockView` /
/// `AnnotationPanel` / modals. Sitting above frames matches the old
/// CSS where the 2D canvas `.dc` was painted on top of `.cv` (frames).
/// Since the selective `hitTest` returns nil for non-link points, frame
/// drag / resize / chrome interactions still reach the frame layer
/// below.
final class LinkLayerView: NSView {

    weak var delegate: LinkLayerViewDelegate?

    // World-space transform mirrored from canvas JS. Updated via the
    // `canvas-view` envelope that JS already publishes on every
    // `applyT()`. The backdrop listens to the same envelope.
    private var canvasScale: CGFloat = 1
    private var canvasPX:    CGFloat = 80
    private var canvasPY:    CGFloat = 80

    /// Link definitions keyed by id. Held separately from the sublayer
    /// dict so `setView` can rebuild paths without walking the array.
    private var links: [NativeLink] = []
    /// Frame bounds in world space. The router expands non-endpoint frames
    /// before searching, keeping connectors out of cards as they move.
    private var obstacles: [CGRect] = []

    /// One entry per live link. Diffed against incoming `setLinks` —
    /// unchanged ids keep their existing CAShapeLayer instances, so
    /// path updates on pan/zoom don't churn the layer tree.
    private var groups: [String: LinkShapeGroup] = [:]

    /// Transient link-drag preview (Phase 6e Step 5). When non-nil, the
    /// `previewGroup` layer pair is painted on top of the established
    /// links with the ghost palette. Lives next to `links` rather than
    /// inside `groups` so its lifecycle (tied to a gesture) stays
    /// decoupled from persisted link diffing.
    private var preview: LinkPreview?
    private var previewGroup: LinkShapeGroup?

    // JS client coords grow y downward. Matching that lets us skip
    // a y-flip in draw code and aligns with CanvasBackdropView /
    // PinOverlayView.
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // Host layer is a plain container — each link owns its own
        // CAShapeLayer(s) inside. Clear background so the backdrop +
        // frames behind show through unchanged.
        layer?.backgroundColor = NSColor.clear.cgColor
        // Paths are driven by explicit setView/setLinks calls, not the
        // AppKit redraw loop, so display-list caching is pointless.
        layerContentsRedrawPolicy = .never
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Input (Phase 6e Step 2)

    /// Tracks the currently-hovered link id so `mouseMoved` can emit
    /// only on meaningful transitions. The delegate never sees a burst
    /// of identical hover callbacks while the cursor sits on a curve.
    private var hoverId: String?

    /// Tracking area covering the full visible rect. Replaced inside
    /// `updateTrackingAreas` whenever AppKit signals that the area may
    /// be stale (typically after a resize or reparent). `.inVisibleRect`
    /// lets AppKit track whatever's currently exposed, so the supplied
    /// rect is a placeholder. `.mouseEnteredAndExited` drives the
    /// hover-clear when the cursor leaves the canvas; `.mouseMoved`
    /// drives hover updates while inside.
    private var trackingArea: NSTrackingArea?

    /// Returns the topmost link whose bezier curve is within the
    /// `LinkBezierMath.isPointOnBezier` tolerance of `point`. `point` is
    /// expected in self-coordinate space. Walks `links` in reverse so
    /// the z-order (last-drawn = topmost) matches what the user sees.
    func linkId(at point: CGPoint) -> String? {
        // Links are stored with world-space anchors; apply the same
        // screen-space transform the painter uses so render and hit
        // can never drift.
        for link in links.reversed() where LinkOrthogonalMath.isPoint(point, on: screenRoute(for: link).points) {
            return link.id
        }
        return nil
    }

    // MARK: Routes and bends (screen space)

    private func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * canvasScale + canvasPX, y: p.y * canvasScale + canvasPY)
    }

    /// Whether interior bend `index` is a horizontal segment (its value is a y).
    private func bendIsHorizontal(_ index: Int, fromSide: LinkSide) -> Bool {
        ((index + 1) % 2 == 0) == LinkOrthogonalMath.isHorizontal(fromSide)
    }

    /// The drawn polyline and its interior-segment coordinates, in screen
    /// space. User bends win; otherwise the automatic, obstacle-avoiding route.
    private func screenRoute(for link: NativeLink, overriding override: [CGFloat]? = nil) -> (points: [CGPoint], bends: [CGFloat]?) {
        let p0 = toScreen(link.from), p3 = toScreen(link.to)
        if let world = override ?? link.bends {
            let screen = world.enumerated().map { index, value in
                bendIsHorizontal(index, fromSide: link.fromSide) ? value * canvasScale + canvasPY : value * canvasScale + canvasPX
            }
            if let points = LinkOrthogonalMath.manualRoute(p0: p0, p3: p3, fromSide: link.fromSide, toSide: link.toSide, bends: screen) {
                return (points, screen)
            }
        }
        let auto = cachedAutoRoute(for: link)
        return (auto, LinkOrthogonalMath.bends(from: auto, fromSide: link.fromSide))
    }

    // Routing searches a grid around every frame; running it for every link
    // on every pan tick made panning and dragging stutter. The route is
    // computed in scaled space without the pan offset, so panning only
    // translates it; it is recomputed when endpoints, zoom or frames change.
    private struct RouteKey: Equatable {
        let from: CGPoint, to: CGPoint, fromSide: LinkSide, toSide: LinkSide, scale: CGFloat, obstacles: [CGRect]
    }
    private var routeCache: [String: (key: RouteKey, points: [CGPoint])] = [:]
    private var rerouteWork: DispatchWorkItem?

    private func scheduleRerouteAfterZoom() {
        rerouteWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Drop stretched routes whose scale no longer matches, then redraw.
                self.routeCache = self.routeCache.filter { $0.value.key.scale == self.canvasScale }
                self.withoutImplicitAnimation {
                    for link in self.links { if let group = self.groups[link.id] { self.apply(link: link, to: group) } }
                }
            }
        }
        rerouteWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// While a frame is dragged, only these links are re-routed; the others
    /// keep their route even though the obstacles moved. Nil = route all.
    var liveRouteIDs: Set<String>? = nil

    private func cachedAutoRoute(for link: NativeLink) -> [CGPoint] {
        let key = RouteKey(from: link.from, to: link.to, fromSide: link.fromSide, toSide: link.toSide,
                           scale: canvasScale, obstacles: obstacles)
        let scaled: [CGPoint]
        if let hit = routeCache[link.id], hit.key == key {
            scaled = hit.points
        } else if let hit = routeCache[link.id], hit.key.scale != key.scale, hit.key.from == key.from, hit.key.to == key.to,
                  hit.key.fromSide == key.fromSide, hit.key.toSide == key.toSide, hit.key.obstacles == key.obstacles {
            // Mid-zoom: stretch the known route instead of searching again on
            // every step; the exact route is computed once zooming pauses.
            let ratio = key.scale / hit.key.scale
            scaled = hit.points.map { CGPoint(x: $0.x * ratio, y: $0.y * ratio) }
            scheduleRerouteAfterZoom()
        } else if let live = liveRouteIDs, !live.contains(link.id), let hit = routeCache[link.id],
                  hit.key.from == key.from, hit.key.to == key.to, hit.key.scale == key.scale,
                  hit.key.fromSide == key.fromSide, hit.key.toSide == key.toSide {
            scaled = hit.points
        } else {
            let s = canvasScale
            let scaledObstacles = obstacles.map { CGRect(x: $0.minX * s, y: $0.minY * s, width: $0.width * s, height: $0.height * s) }
            scaled = LinkOrthogonalMath.simplifiedRoute(LinkOrthogonalMath.route(
                p0: CGPoint(x: link.from.x * s, y: link.from.y * s), p3: CGPoint(x: link.to.x * s, y: link.to.y * s),
                fromSide: link.fromSide, toSide: link.toSide, obstacles: scaledObstacles))
            routeCache[link.id] = (key, scaled)
        }
        return scaled.map { CGPoint(x: $0.x + canvasPX, y: $0.y + canvasPY) }
    }

    private func toWorld(_ screen: [CGFloat], fromSide: LinkSide) -> [CGFloat] {
        screen.enumerated().map { index, value in
            bendIsHorizontal(index, fromSide: fromSide) ? (value - canvasPY) / canvasScale : (value - canvasPX) / canvasScale
        }
    }

    /// Live bends while a segment is being dragged.
    private var draggingBends: (id: String, bends: [CGFloat])?

    /// Selective hit-test: return self only when the point is actually
    /// on a curve. Everywhere else, return nil so the event falls
    /// through to whatever sits below in `CanvasHost` — frames still
    /// drag, the backdrop still receives clicks, the canvas WKWebView
    /// still gets pan-start while the parallel-run JS path is alive.
    ///
    /// `point` arrives in our superview's coord space (AppKit
    /// convention), so convert before running the bezier test.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let pSelf = convert(point, from: superview)
        return linkId(at: pSelf) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        // `hitTest` already filtered — if we got here, the cursor was on
        // a curve at the moment `mouseDown` was dispatched. Re-run the
        // search because the cursor may have moved by a sub-pixel
        // between hit-test and dispatch.
        let pSelf = convert(event.locationInWindow, from: nil)
        guard let id = linkId(at: pSelf), let link = links.first(where: { $0.id == id }) else { return }
        delegate?.linkLayer(self, didClickLink: id)
        if event.clickCount == 2 {
            if link.bends != nil { delegate?.linkLayer(self, didSetBends: nil, forLink: id) }
            return
        }
        // Drag an interior segment across its own axis. The first drag
        // turns the automatic route into a manual one.
        let route = screenRoute(for: link)
        guard var bends = route.bends,
              let index = LinkOrthogonalMath.interiorSegment(at: pSelf, of: route.points) else { return }
        let horizontal = bendIsHorizontal(index, fromSide: link.fromSide)
        let p0 = toScreen(link.from), p3 = toScreen(link.to)
        let stub: CGFloat = 18
        var moved = false
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let p = convert(next.locationInWindow, from: nil)
            var value = horizontal ? p.y : p.x
            // Keep the end segments pointing out of their frames.
            if index == 0 {
                let t = link.fromSide.tangent
                let anchor = horizontal ? p0.y : p0.x, sign = horizontal ? t.dy : t.dx
                if sign != 0 { value = sign > 0 ? max(value, anchor + stub) : min(value, anchor - stub) }
            }
            if index == bends.count - 1 {
                let t = link.toSide.tangent
                let anchor = horizontal ? p3.y : p3.x, sign = horizontal ? t.dy : t.dx
                if sign != 0 { value = sign > 0 ? max(value, anchor + stub) : min(value, anchor - stub) }
            }
            bends[index] = value.rounded()
            moved = true
            draggingBends = (id, toWorld(bends, fromSide: link.fromSide))
            if let group = groups[id] { apply(link: link, to: group) }
        }
        draggingBends = nil
        if moved { delegate?.linkLayer(self, didSetBends: toWorld(bends, fromSide: link.fromSide), forLink: id) }
        // Don't forward to super: the default implementation would
        // trigger a no-op NSResponder pipeline; we've already routed.
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [
            .mouseMoved, .mouseEnteredAndExited,
            .activeInKeyWindow, .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: .zero,
                                  options: options,
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let pSelf = convert(event.locationInWindow, from: nil)
        let newId = linkId(at: pSelf)
        // Over a movable segment, show which way it moves.
        if let id = newId, let link = links.first(where: { $0.id == id }),
           let index = LinkOrthogonalMath.interiorSegment(at: pSelf, of: screenRoute(for: link).points) {
            (bendIsHorizontal(index, fromSide: link.fromSide) ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set()
        } else if newId != nil {
            NSCursor.pointingHand.set()
        }
        guard newId != hoverId else { return }
        hoverId = newId
        delegate?.linkLayer(self, didHoverLink: newId)
    }

    override func mouseExited(with event: NSEvent) {
        guard hoverId != nil else { return }
        hoverId = nil
        delegate?.linkLayer(self, didHoverLink: nil)
    }

    /// Cursor shape over a link curve. AppKit calls this during its
    /// cursor-update pass when the mouse is inside a tracking area
    /// whose owner also implements `cursorUpdate`. The pointer-hand
    /// matches the CSS `body.link-hover { cursor: pointer }` that JS
    /// toggled.
    override func cursorUpdate(with event: NSEvent) {
        if hoverId != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    // MARK: State in

    /// Mirrors canvas JS's world-space transform. Triggers path
    /// rebuild for every live link — cheap, since we only
    /// recompute two `CGPoint`s + a bezier per link and CAShapeLayer
    /// path updates are GPU-friendly.
    func setView(scale: CGFloat, px: CGFloat, py: CGFloat) {
        guard scale != canvasScale || px != canvasPX || py != canvasPY else { return }
        canvasScale = scale
        canvasPX = px
        canvasPY = py
        withoutImplicitAnimation {
            for link in links {
                if let group = groups[link.id] {
                    apply(link: link, to: group)
                }
            }
            if let p = preview, let g = previewGroup {
                applyPreview(p, to: g)
            }
        }
    }

    /// Push (or clear) the transient link-drag preview. `nil` tears
    /// the layer down; any non-nil value (re)paints. Intentionally a
    /// single-call API — `CanvasHost` rebuilds the full `LinkPreview`
    /// on every drag tick, so we don't bother with granular patching.
    func setPreviewLink(_ newPreview: LinkPreview?) {
        preview = newPreview
        guard let host = layer else { return }
        withoutImplicitAnimation {
            if let p = newPreview {
                let group: LinkShapeGroup
                if let existing = previewGroup {
                    group = existing
                } else {
                    group = LinkShapeGroup()
                    group.attach(to: host)
                    previewGroup = group
                }
                applyPreview(p, to: group)
            } else {
                previewGroup?.removeFromSuperlayer()
                previewGroup = nil
            }
        }
    }

    /// Replaces the current link set. Sublayers are diffed in place so
    /// flipping a single link's `selected` flag doesn't thrash the
    /// entire layer tree.
    func setLinks(_ newLinks: [NativeLink], obstacles newObstacles: [CGRect] = []) {
        let newIds = Set(newLinks.map(\.id))
        // Drop layers for links that disappeared.
        for id in groups.keys where !newIds.contains(id) {
            groups[id]?.removeFromSuperlayer()
            groups.removeValue(forKey: id)
        }
        links = newLinks
        obstacles = newObstacles
        routeCache = routeCache.filter { newIds.contains($0.key) }
        guard let host = layer else { return }
        withoutImplicitAnimation {
            for link in newLinks {
                let group: LinkShapeGroup
                if let existing = groups[link.id] {
                    group = existing
                } else {
                    group = LinkShapeGroup()
                    group.attach(to: host)
                    groups[link.id] = group
                }
                apply(link: link, to: group)
            }
        }
    }

    // MARK: Drawing

    private func screenObstacles() -> [CGRect] {
        obstacles.map { rect in
            CGRect(
                x: rect.minX * canvasScale + canvasPX,
                y: rect.minY * canvasScale + canvasPY,
                width: rect.width * canvasScale,
                height: rect.height * canvasScale
            )
        }
    }

    /// Applies link geometry + style to its layer group. Mirrors the
    /// JS `drawLinkLine` in index.html — same control-point math, same
    /// arrowhead triangle, same color ramps for selected/hover/idle.
    private func apply(link: NativeLink, to group: LinkShapeGroup) {
        // World → screen. Matches JS: `a.x*scale + px, a.y*scale + py`.
        let p0 = toScreen(link.from), p3 = toScreen(link.to)
        let live = draggingBends?.id == link.id ? draggingBends?.bends : nil
        let route = LinkOrthogonalMath.simplifiedRoute(screenRoute(for: link, overriding: live).points)

        let connector = CGMutablePath()
        connector.move(to: route.first ?? p0)
        for point in route.dropFirst() { connector.addLine(to: point) }
        group.line.path = connector
        group.line.lineDashPattern = link.id.hasPrefix("map-edge-") ? [6, 5] : nil

        // Colors. Matches the JS palette exactly:
        //   selected:  rgba(56, 189, 248, 0.95), width 3
        //   hovered:   rgba(254, 99, 55, 0.9),   width 2.5
        //   idle:      rgba(254, 99, 55, 0.75),  width 2
        let stroke: CGColor
        let width: CGFloat
        if link.selected {
            stroke = CGColor(red: 56/255,  green: 189/255, blue: 248/255, alpha: 0.95)
            width  = 3
        } else if link.hovered {
            stroke = CGColor(red: 254/255, green: 99/255,  blue: 55/255,  alpha: 0.9)
            width  = 2.5
        } else {
            stroke = CGColor(red: 254/255, green: 99/255,  blue: 55/255,  alpha: 0.75)
            width  = 2
        }
        group.line.strokeColor = stroke
        group.line.fillColor   = NSColor.clear.cgColor
        group.line.lineWidth   = width
        group.line.lineCap     = .round
        group.line.lineJoin    = .round

        // Arrowhead. Drawn as a separate CAShapeLayer because the bezier
        // stroke needs line joins (open curve, fill=none) and the
        // triangle needs fill (closed shape, stroke=none) — one
        // CAShapeLayer can't do both simultaneously.
        //
        // Triangle vertices in the JS source:
        //   moveTo(0,0); lineTo(-sz,-sz*0.55); lineTo(-sz*0.7,0); lineTo(-sz,sz*0.55); close
        // where sz = 7 + lineWidth. Rotated so (-sz..0) points "back"
        // along the final orthogonal segment.
        let sz  = 7 + width
        let previous = route.dropLast().last ?? p0
        let angle = atan2(p3.y - previous.y, p3.x - previous.x)
        let tri = CGMutablePath()
        tri.move(to: .zero)
        tri.addLine(to: CGPoint(x: -sz,       y: -sz * 0.55))
        tri.addLine(to: CGPoint(x: -sz * 0.7, y:  0))
        tri.addLine(to: CGPoint(x: -sz,       y:  sz * 0.55))
        tri.closeSubpath()
        var xf = CGAffineTransform(translationX: p3.x, y: p3.y)
            .rotated(by: angle)
        let placed = tri.copy(using: &xf) ?? tri
        group.arrow.path        = placed
        group.arrow.fillColor   = stroke
        group.arrow.strokeColor = NSColor.clear.cgColor
    }

    /// Paints the transient link-drag preview. Same bezier math as
    /// established links, but the ghost palette swaps in: 0.45 alpha
    /// instead of 0.75, orange (254, 99, 55) while floating over empty
    /// canvas, sky-blue (56, 189, 248) while snapped to a target edge.
    /// Arrowhead is painted only when a target is locked in — matches
    /// the JS `arrow:!!linkDrag.targetId` at index.html:502, which uses
    /// the arrow's presence to signal "release here to create the link."
    ///
    /// When `toSide` is nil (floating over empty canvas), the far
    /// tangent defaults to horizontal — mirrors the JS
    /// `_linkControlPoints` default fallback so the preview reads as a
    /// straight-ish stub instead of coiling toward an arbitrary edge.
    private func applyPreview(_ preview: LinkPreview, to group: LinkShapeGroup) {
        let p0 = CGPoint(x: preview.from.x * canvasScale + canvasPX,
                         y: preview.from.y * canvasScale + canvasPY)
        let p3 = CGPoint(x: preview.to.x   * canvasScale + canvasPX,
                         y: preview.to.y   * canvasScale + canvasPY)
        let effectiveToSide: LinkSide = preview.toSide ?? {
            let dx = p3.x - p0.x, dy = p3.y - p0.y
            if abs(dx) >= abs(dy) { return dx >= 0 ? .left : .right }
            return dy >= 0 ? .top : .bottom
        }()
        let route = LinkOrthogonalMath.route(
            p0: p0, p3: p3,
            fromSide: preview.fromSide, toSide: effectiveToSide,
            obstacles: screenObstacles()
        )

        let connector = CGMutablePath()
        connector.move(to: route.first ?? p0)
        for point in route.dropFirst() { connector.addLine(to: point) }
        group.line.path = connector

        let alpha: CGFloat = 0.45
        let width: CGFloat = 2
        let stroke: CGColor = preview.isOverTarget
            ? CGColor(red: 56/255,  green: 189/255, blue: 248/255, alpha: alpha)
            : CGColor(red: 254/255, green: 99/255,  blue: 55/255,  alpha: alpha)
        group.line.strokeColor = stroke
        group.line.fillColor   = NSColor.clear.cgColor
        group.line.lineWidth   = width
        group.line.lineCap     = .round
        group.line.lineJoin    = .round

        if preview.isOverTarget {
            let sz = 7 + width
            let previous = route.dropLast().last ?? p0
            let angle = atan2(p3.y - previous.y, p3.x - previous.x)
            let tri = CGMutablePath()
            tri.move(to: .zero)
            tri.addLine(to: CGPoint(x: -sz,       y: -sz * 0.55))
            tri.addLine(to: CGPoint(x: -sz * 0.7, y:  0))
            tri.addLine(to: CGPoint(x: -sz,       y:  sz * 0.55))
            tri.closeSubpath()
            var xf = CGAffineTransform(translationX: p3.x, y: p3.y)
                .rotated(by: angle)
            let placed = tri.copy(using: &xf) ?? tri
            group.arrow.path        = placed
            group.arrow.fillColor   = stroke
            group.arrow.strokeColor = NSColor.clear.cgColor
        } else {
            // No target → no arrowhead. Clear the path so the previous
            // tick's triangle doesn't linger when the cursor flies off
            // a frame and back to empty canvas.
            group.arrow.path      = nil
            group.arrow.fillColor = NSColor.clear.cgColor
        }
    }

    // Core Animation fires implicit position/path animations on every
    // sublayer property assignment. During a pan/zoom gesture we update
    // paths 60×/sec, so implicit animations produce trailing smears.
    // Wrap updates in a transaction that disables actions for the
    // duration. Nicer than setting `layer.actions` dict manually — the
    // one-liner affects every sublayer we touch inside `body`.
    private func withoutImplicitAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

// MARK: - Per-link sublayer pair

/// Holds the two `CAShapeLayer`s that together render one link:
/// `line` strokes the cubic bezier curve, `arrow` fills the
/// triangular arrowhead at its tip. They're lifecycle-linked
/// (attached / removed together) so `LinkLayerView.groups` can
/// treat a link as one unit.
private final class LinkShapeGroup {
    let line  = CAShapeLayer()
    let arrow = CAShapeLayer()

    func attach(to host: CALayer) {
        host.addSublayer(line)
        host.addSublayer(arrow)
    }

    func removeFromSuperlayer() {
        line.removeFromSuperlayer()
        arrow.removeFromSuperlayer()
    }
}
