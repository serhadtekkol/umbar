//
//  NotchApproachPolicyTests.swift
//  umbarTests
//
//  The hover hint's lean toward a pointer near the closed island
//  (NotchApproachPolicy.swift).
//

import CoreGraphics
import Foundation
import Testing

@Suite("NotchApproachPolicy", .timeLimit(.minutes(1)))
struct NotchApproachPolicyTests {
    // A 200x32 island at the top of a 1332 pt tall screen, AppKit space.
    let island = CGRect(x: 924, y: 1300, width: 200, height: 32)
    let reach: CGFloat = 24
    let steps = 6

    func approach(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
        NotchApproachPolicy.approach(to: island, pointer: CGPoint(x: x, y: y), reach: reach, steps: steps)
    }

    @Test func fullOnAndInsideTheIsland() {
        #expect(approach(1024, 1316) == 1)
        #expect(approach(island.minX, 1332) == 1)
    }

    @Test func noneAtOrBeyondTheReach() {
        #expect(approach(island.minX - 24, 1320) == 0)
        #expect(approach(island.maxX + 200, 1320) == 0)
        #expect(approach(1024, island.minY - 30) == 0)
    }

    @Test func fallsWithDistanceFromTheNearestEdge() {
        let near = approach(island.maxX + 4, 1320)
        let far = approach(island.maxX + 16, 1320)
        #expect(near > far)
        #expect(far > 0)
        // Below the island counts the same as beside it.
        #expect(approach(1024, island.minY - 4) == near)
    }

    @Test func cornerDistanceIsEuclidean() {
        // 18 pt left and 18 pt below: ~25 pt from the corner, out of reach.
        #expect(approach(island.minX - 18, island.minY - 18) == 0)
    }

    @Test func roundedToSteps() {
        for dx in stride(from: CGFloat(0), through: 30, by: 0.5) {
            let value = approach(island.maxX + dx, 1320) * CGFloat(steps)
            #expect(value == value.rounded())
        }
    }

    @Test func emptyRectOrNoReachIsNone() {
        #expect(NotchApproachPolicy.approach(to: .zero, pointer: .zero, reach: reach, steps: steps) == 0)
        #expect(NotchApproachPolicy.approach(to: island, pointer: CGPoint(x: 1024, y: 1316), reach: 0, steps: steps) == 0)
    }
}
