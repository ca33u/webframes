import AppKit
import Testing
@testable import Web_Frames

@Suite("Tidy Up")
struct TidyUpTests {

    private func frame(_ id: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat = 390, _ h: CGFloat = 845) -> FrameModel {
        FrameModel(id: id, url: "", label: id, x: x, y: y, w: w, h: h, num: 0, isImage: true, filePath: nil)
    }

    private func rects(_ frames: [FrameModel], _ positions: [String: CGPoint]) -> [CGRect] {
        frames.map { f in let p = positions[f.id]!; return CGRect(x: p.x, y: p.y, width: f.w, height: f.h) }
    }

    @Test func scatteredFramesBecomeAnEvenGridWithoutOverlaps() {
        // A messy cloud of 12 phone screenshots, wider than tall.
        let frames = (0..<12).map { i in frame("f\(i)", CGFloat((i * 733) % 4000), CGFloat((i * 491) % 1500)) }
        let positions = FrameArrangement.tidyUp.positions(for: frames)
        #expect(positions.count == 12)
        let r = rects(frames, positions)
        for i in r.indices { for j in r.indices where i < j { #expect(!r[i].intersects(r[j])) } }
        // Equal gaps: the distinct x origins step by the same amount.
        let xs = Set(r.map(\.minX)).sorted()
        let steps = Set(zip(xs, xs.dropFirst()).map { $1 - $0 })
        #expect(steps.count == 1)
        // Starts at the selection's top-left corner.
        #expect(r.map(\.minX).min() == frames.map(\.x).min())
        #expect(r.map(\.minY).min() == frames.map(\.y).min())
    }

    @Test func keepsReadingOrderOfAnExistingRow() {
        let frames = [frame("c", 2000, 10), frame("a", 0, 0), frame("b", 900, 30)]
        let p = FrameArrangement.tidyUp.positions(for: frames)
        #expect(p["a"]!.x < p["b"]!.x && p["b"]!.x < p["c"]!.x)
        #expect(p["a"]!.y == p["b"]!.y && p["b"]!.y == p["c"]!.y)
    }

    @Test func fourEqualFramesInASquareMakeTwoByTwo() {
        let frames = [frame("a", 0, 0, 400, 400), frame("b", 600, 50, 400, 400),
                      frame("c", 20, 700, 400, 400), frame("d", 650, 640, 400, 400)]
        let p = FrameArrangement.tidyUp.positions(for: frames)
        #expect(Set(frames.map { p[$0.id]!.x }).count == 2)
        #expect(Set(frames.map { p[$0.id]!.y }).count == 2)
        #expect(FrameArrangement.tidyUp.keyEquivalent == "t")
        #expect(FrameArrangement.tidyUp.keyModifiers == [.control, .option])
    }
}
