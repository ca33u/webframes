//
//  FrameContainerMaskTests.swift
//  webframesTests
//
//  The frame's body meets the header's flat bottom: its clip rounds only
//  the bottom corners, also when chrome holes switch it to a mask path
//  (29.09 — all four were rounded there, leaving notches under the header).
//

import CoreGraphics
import Testing
@testable import Web_Frames

struct FrameContainerMaskTests {
    private let rect = CGRect(x: 0, y: 0, width: 200, height: 300)

    @Test func theTopCornersAreSquare() {
        let path = FrameContainer.bottomRoundedRect(rect, radius: 12)
        // Layer coordinates are y-up: the top edge is maxY.
        #expect(path.contains(CGPoint(x: 0.5, y: 299.5)))
        #expect(path.contains(CGPoint(x: 199.5, y: 299.5)))
    }

    @Test func theBottomCornersAreRounded() {
        let path = FrameContainer.bottomRoundedRect(rect, radius: 12)
        #expect(!path.contains(CGPoint(x: 0.5, y: 0.5)))
        #expect(!path.contains(CGPoint(x: 199.5, y: 0.5)))
        #expect(path.contains(CGPoint(x: 100, y: 0.5)))
    }

    @Test func aRadiusLargerThanTheRectIsClamped() {
        let path = FrameContainer.bottomRoundedRect(CGRect(x: 0, y: 0, width: 10, height: 10), radius: 50)
        #expect(path.contains(CGPoint(x: 5, y: 5)))
    }
}
