//
//  LinkBezierMathTests.swift
//  webframesTests
//
//  Unit tests for `LinkBezierMath` — the pure-math routines that drive
//  both link-curve rendering and hit-testing in `LinkLayerView`. Added
//  in Phase 6e Step 2, when hit-testing moved from JS
//  (`findLinkAtClient` + `_linkControlPoints` in index.html) to Swift.
//
//  The invariant these tests protect: the visible curve and the hit
//  zone cannot drift out of sync. Every test exercises the same
//  `controlPoints` + `isPointOnBezier` pair the production code uses.
//
//  No AppKit types here — `LinkBezierMath` is an `enum` of pure
//  statics, so tests run on any host (no @MainActor needed).
//

import Foundation
import CoreGraphics
import AppKit
import Testing
@testable import Web_Frames

private let eps: CGFloat = 1e-9

// MARK: - controlPoints

@Suite("LinkBezierMath · controlPoints")
struct LinkBezierMathControlPointTests {

    /// Right→left is the default side pair for links: the curve leaves
    /// the source's right edge, sweeps into empty space to the right,
    /// arcs over, and arrives at the target's left edge from the left.
    /// Control points therefore sit along the horizontal tangent from
    /// each endpoint, scaled by the run |dx|.
    @Test("right→left uses horizontal tangents scaled by |dx|")
    func rightToLeft() {
        let p0 = CGPoint(x: 100, y: 100)
        let p3 = CGPoint(x: 300, y: 140)
        let (p1, p2) = LinkBezierMath.controlPoints(
            p0: p0, p3: p3, fromSide: .right, toSide: .left
        )
        // mag = max(36, |dx| * 0.45) = max(36, 90) = 90
        #expect(abs(p1.x - (p0.x + 90)) < eps)
        #expect(abs(p1.y - p0.y)        < eps)
        #expect(abs(p2.x - (p3.x - 90)) < eps)
        #expect(abs(p2.y - p3.y)        < eps)
    }

    /// Top→bottom uses vertical tangents scaled by |dy|.
    @Test("top→bottom uses vertical tangents scaled by |dy|")
    func topToBottom() {
        let p0 = CGPoint(x: 200, y: 50)
        let p3 = CGPoint(x: 210, y: 250)
        let (p1, p2) = LinkBezierMath.controlPoints(
            p0: p0, p3: p3, fromSide: .top, toSide: .bottom
        )
        // mag = max(36, |dy| * 0.45) = max(36, 90) = 90
        // fromSide .top tangent points -y (outward, upward in screen
        // space), so p1 sits ABOVE p0.
        #expect(abs(p1.x - p0.x)        < eps)
        #expect(abs(p1.y - (p0.y - 90)) < eps)
        // toSide .bottom tangent points +y (outward), so p2 sits BELOW p3:
        // te = (0, 1); p2.y = p3.y + te.y * mag = 250 + 90 = 340.
        #expect(abs(p2.x - p3.x)        < eps)
        #expect(abs(p2.y - (p3.y + 90)) < eps)
    }

    /// Short links clamp to the 36pt minimum so a same-edge loop still
    /// bows out enough to read as a connector.
    @Test("short link clamps to 36pt minimum")
    func minClamp() {
        let p0 = CGPoint(x: 0, y: 0)
        let p3 = CGPoint(x: 10, y: 0)
        let (p1, p2) = LinkBezierMath.controlPoints(
            p0: p0, p3: p3, fromSide: .right, toSide: .left
        )
        // |dx| * 0.45 = 4.5 — floored to 36.
        #expect(abs(p1.x - 36) < eps)
        #expect(abs(p2.x - (p3.x - 36)) < eps)
    }

    /// Mixed-side curves take their magnitude from whichever axis the
    /// tangent points along: a horizontal tangent scales with |dx|,
    /// the mismatched vertical tangent scales with |dy|.
    @Test("right→top uses |dx| for the horizontal, |dy| for the vertical end")
    func rightToTop() {
        let p0 = CGPoint(x: 0, y: 0)
        let p3 = CGPoint(x: 300, y: 200)
        let (p1, p2) = LinkBezierMath.controlPoints(
            p0: p0, p3: p3, fromSide: .right, toSide: .top
        )
        // fromSide .right (horizontal) → magFrom = max(36, 300 * 0.45) = 135.
        #expect(abs(p1.x - 135) < eps)
        #expect(abs(p1.y)       < eps)
        // toSide .top (vertical) → magTo = max(36, 200 * 0.45) = 90.
        // te = (0, -1); p2 = p3 + te * mag = (300, 200 + (-1)*90) = (300, 110).
        #expect(abs(p2.x - 300) < eps)
        #expect(abs(p2.y - 110) < eps)
    }
}

// MARK: - isPointOnBezier

@Suite("LinkBezierMath · isPointOnBezier")
struct LinkBezierMathHitTests {

    /// Points that sit exactly on the straight bezier defined by
    /// collinear control points hit. The intermediate `t=0.5` sample
    /// is close enough to the straight line to be well within the
    /// 8pt tolerance.
    @Test("point on a straight bezier is a hit")
    func straightBezierHits() {
        let p0 = CGPoint(x: 0, y: 0)
        let p1 = CGPoint(x: 100, y: 0)
        let p2 = CGPoint(x: 200, y: 0)
        let p3 = CGPoint(x: 300, y: 0)
        // Midpoint.
        #expect(LinkBezierMath.isPointOnBezier(
            CGPoint(x: 150, y: 0),
            p0: p0, p1: p1, p2: p2, p3: p3
        ))
        // On the curve but not at a sample node.
        #expect(LinkBezierMath.isPointOnBezier(
            CGPoint(x: 73, y: 0),
            p0: p0, p1: p1, p2: p2, p3: p3
        ))
    }

    /// Points inside the 8pt tolerance band around a straight curve
    /// still hit — mirrors the forgiving hit zone JS gave users.
    @Test("point within 8pt tolerance hits")
    func withinToleranceHits() {
        let p0 = CGPoint(x: 0, y: 0)
        let p1 = CGPoint(x: 100, y: 0)
        let p2 = CGPoint(x: 200, y: 0)
        let p3 = CGPoint(x: 300, y: 0)
        #expect(LinkBezierMath.isPointOnBezier(
            CGPoint(x: 150, y: 7),
            p0: p0, p1: p1, p2: p2, p3: p3
        ))
    }

    /// Points outside the tolerance band miss — the hit zone has a
    /// clear boundary.
    @Test("point beyond tolerance misses")
    func beyondToleranceMisses() {
        let p0 = CGPoint(x: 0, y: 0)
        let p1 = CGPoint(x: 100, y: 0)
        let p2 = CGPoint(x: 200, y: 0)
        let p3 = CGPoint(x: 300, y: 0)
        #expect(!LinkBezierMath.isPointOnBezier(
            CGPoint(x: 150, y: 50),
            p0: p0, p1: p1, p2: p2, p3: p3
        ))
    }

    /// Custom tolerance narrows the hit zone. A point 5pt from a
    /// straight curve hits at the default 8pt but misses at 3pt.
    @Test("custom tolerance tightens hit zone")
    func toleranceArgument() {
        let p0 = CGPoint(x: 0, y: 0)
        let p1 = CGPoint(x: 100, y: 0)
        let p2 = CGPoint(x: 200, y: 0)
        let p3 = CGPoint(x: 300, y: 0)
        let p = CGPoint(x: 150, y: 5)
        #expect(LinkBezierMath.isPointOnBezier(
            p, p0: p0, p1: p1, p2: p2, p3: p3, tolerance: 8
        ))
        #expect(!LinkBezierMath.isPointOnBezier(
            p, p0: p0, p1: p1, p2: p2, p3: p3, tolerance: 3
        ))
    }

    /// End-point hit: the curve starts and ends exactly on the
    /// endpoints. The sample at `t = 1/24` sits near `p0`, so p0
    /// itself should hit.
    @Test("endpoints hit")
    func endpointsHit() {
        let p0 = CGPoint(x: 50, y: 50)
        let p1 = CGPoint(x: 80, y: 50)
        let p2 = CGPoint(x: 120, y: 50)
        let p3 = CGPoint(x: 150, y: 50)
        #expect(LinkBezierMath.isPointOnBezier(
            p0, p0: p0, p1: p1, p2: p2, p3: p3
        ))
        #expect(LinkBezierMath.isPointOnBezier(
            p3, p0: p0, p1: p1, p2: p2, p3: p3
        ))
    }

    /// Full pipeline: given two frame-edge anchors in world space and
    /// screen-space transform, compute control points and hit-test a
    /// point on the transformed curve. Exercises the exact composition
    /// `LinkLayerView.linkId(at:)` does.
    @Test("render/hit pipeline hits a point on the rendered curve")
    func renderAndHitUnified() {
        // World-space anchors (as `NativeLink.from/to`).
        let fromWorld = CGPoint(x: 100, y: 100)
        let toWorld   = CGPoint(x: 400, y: 200)
        // Canvas view transform.
        let scale: CGFloat = 1.25
        let px: CGFloat = 40, py: CGFloat = 60
        let p0 = CGPoint(x: fromWorld.x * scale + px,
                         y: fromWorld.y * scale + py)
        let p3 = CGPoint(x: toWorld.x   * scale + px,
                         y: toWorld.y   * scale + py)
        let (p1, p2) = LinkBezierMath.controlPoints(
            p0: p0, p3: p3, fromSide: .right, toSide: .left
        )
        // Sample the curve at t=0.4 and verify the sampled point hits.
        let pt = LinkBezierMath.point(p0, p1, p2, p3, t: 0.4)
        #expect(LinkBezierMath.isPointOnBezier(
            pt, p0: p0, p1: p1, p2: p2, p3: p3
        ))
        // And a point far off the curve misses.
        let off = CGPoint(x: pt.x, y: pt.y + 40)
        #expect(!LinkBezierMath.isPointOnBezier(
            off, p0: p0, p1: p1, p2: p2, p3: p3
        ))
    }
}

// MARK: - distanceToSegment

@Suite("LinkBezierMath · distanceToSegment")
struct LinkBezierMathDistanceTests {

    @Test("perpendicular distance")
    func perpendicular() {
        let a = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 10, y: 0)
        #expect(abs(LinkBezierMath.distanceToSegment(CGPoint(x: 5, y: 4), a, b) - 4) < 1e-9)
    }

    @Test("projection clamped to segment endpoints")
    func offEndpoint() {
        let a = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 10, y: 0)
        // Beyond `b` — the clamp lands on `b`, so the distance is the
        // direct hypot to `b`.
        let d = LinkBezierMath.distanceToSegment(CGPoint(x: 15, y: 3), a, b)
        #expect(abs(d - hypot(5, 3)) < 1e-9)
    }

    @Test("degenerate segment falls back to point distance")
    func degenerate() {
        let a = CGPoint(x: 5, y: 5)
        #expect(abs(LinkBezierMath.distanceToSegment(CGPoint(x: 8, y: 9), a, a) - 5) < 1e-9)
    }
}

@Suite("LinkOrthogonalMath · routing")
struct LinkOrthogonalMathRoutingTests {

    @Test("route contains only horizontal and vertical segments")
    func orthogonalSegments() {
        let route = LinkOrthogonalMath.route(
            p0: CGPoint(x: 20, y: 40),
            p3: CGPoint(x: 280, y: 220),
            fromSide: .right,
            toSide: .left,
            obstacles: []
        )
        #expect(route.count >= 2)
        for (a, b) in zip(route, route.dropFirst()) {
            #expect(abs(a.x - b.x) < eps || abs(a.y - b.y) < eps)
        }
    }

    @Test("route avoids frame interiors")
    func avoidsObstacle() {
        let obstacle = CGRect(x: 120, y: 20, width: 70, height: 140)
        let route = LinkOrthogonalMath.route(
            p0: CGPoint(x: 20, y: 90),
            p3: CGPoint(x: 300, y: 90),
            fromSide: .right,
            toSide: .left,
            obstacles: [obstacle]
        )
        #expect(route.count >= 4)
        for (a, b) in zip(route, route.dropFirst()) {
            #expect(!LinkOrthogonalMath.segmentCrossesInterior(a, b, of: obstacle))
        }
    }

    @Test("endpoint sides determine first and final segment")
    func honorsSides() {
        let p0 = CGPoint(x: 40, y: 80)
        let p3 = CGPoint(x: 260, y: 220)
        let route = LinkOrthogonalMath.route(
            p0: p0, p3: p3,
            fromSide: .top, toSide: .right,
            obstacles: []
        )
        #expect(route.count >= 3)
        #expect(route[1].x == p0.x)
        #expect(route[1].y < p0.y)
        #expect(route[route.count - 2].x > p3.x)
        #expect(route[route.count - 2].y == p3.y)
    }

    @Test("polyline hit testing follows routed segments")
    func hitTesting() {
        let route = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 80),
        ]
        #expect(LinkOrthogonalMath.isPoint(CGPoint(x: 55, y: 6), on: route))
        #expect(LinkOrthogonalMath.isPoint(CGPoint(x: 94, y: 50), on: route))
        #expect(!LinkOrthogonalMath.isPoint(CGPoint(x: 50, y: 30), on: route))
    }
}

@Suite("Card geometry") struct CardGeometryTests {
    @Test func bodyMatchesTheCardAtFullZoom() {
        let body = CardGeometry.bodyRect(x: 10, y: 20, width: 390, height: 844, scale: 1)
        #expect(body == CGRect(x: 11, y: 54, width: 390, height: 844))
    }

    @Test func headerKeepsItsScreenSizeWhenZoomed() {
        // At 50% the 34pt header covers 68 world units, and the body shrinks
        // by the extra header height; narrow frames are no exception.
        let body = CardGeometry.bodyRect(x: 0, y: 0, width: 390, height: 844, scale: 0.5)
        #expect(body.minY == 68)
        let expectedHeight: CGFloat = 844 + 35 - 70
        #expect(body.height == expectedHeight)
        let expectedWidth: CGFloat = 392 - 4
        #expect(body.minX == 2 && body.width == expectedWidth)
    }
}

@Suite("Link bends") struct LinkBendTests {
    // Left side of one frame to the bottom of another, as in the board:
    // left stub, up, left, down into the target.
    let p0 = CGPoint(x: 600, y: 600), p3 = CGPoint(x: 170, y: 90)

    @Test func manualRouteKeepsUserBendsWhenEndpointsMove() throws {
        let route = try #require(LinkOrthogonalMath.manualRoute(p0: p0, p3: p3, fromSide: .left, toSide: .bottom, bends: [585, 125]))
        #expect(route == [p0, CGPoint(x: 585, y: 600), CGPoint(x: 585, y: 125), CGPoint(x: 170, y: 125), p3])
        let moved = try #require(LinkOrthogonalMath.manualRoute(p0: CGPoint(x: 640, y: 650), p3: p3, fromSide: .left, toSide: .bottom, bends: [585, 125]))
        #expect(moved[1] == CGPoint(x: 585, y: 650) && moved[2] == CGPoint(x: 585, y: 125))
    }

    @Test func bendsRoundTripFromARoute() throws {
        let route = [p0, CGPoint(x: 585, y: 600), CGPoint(x: 585, y: 125), CGPoint(x: 170, y: 125), p3]
        let bends = try #require(LinkOrthogonalMath.bends(from: route, fromSide: .left))
        #expect(bends == [585, 125])
        #expect(LinkOrthogonalMath.interiorSegment(at: CGPoint(x: 587, y: 300), of: route) == 0)
        #expect(LinkOrthogonalMath.interiorSegment(at: CGPoint(x: 400, y: 127), of: route) == 1)
        #expect(LinkOrthogonalMath.interiorSegment(at: CGPoint(x: 595, y: 600), of: route) == nil)   // stub is not movable
    }

    @Test func mismatchedBendsFallBackToAutomatic() {
        // One interior segment cannot connect a left side to a bottom side.
        #expect(LinkOrthogonalMath.manualRoute(p0: p0, p3: p3, fromSide: .left, toSide: .bottom, bends: [585]) == nil)
    }

    @MainActor @Test func bendsPersistAndUndo() throws {
        let document = makeTestDocument()
        for (id, x) in [("a", 0.0), ("b", 900.0)] {
            _ = document.workspace.createFrame(FrameModel(id: id, url: "https://e.com", label: id, x: x, y: 0, w: 300, h: 200, num: 1, isImage: false, filePath: nil))
        }
        let link = try #require(document.workspace.createLink(LinkModel(id: "l", fromId: "a", fromSide: .right, toId: "b", toSide: .left)))
        document.undoManager?.removeAllActions()
        document.workspace.setLinkBends(id: link.id, bends: [450])
        #expect(document.workspace.links.first?.bends == [450])
        document.undoManager?.undo()
        #expect(document.workspace.links.first?.bends == nil)
    }
}
