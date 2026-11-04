//
//  NotchDripPolicyTests.swift
//  umbarTests
//
//  The liquid drip under the closed island (NotchDripPolicy.swift): the
//  pointer's pull and position, and the simulation's stretch, follow,
//  retract, pinch and rest. Pure; nothing is drawn.
//

import CoreGraphics
import Foundation
import Testing

/// A fixed tuning, so these do not move when UmbarMotion.drip is retuned.
let dripTuning = NotchDripTuning(
    reach: 48, near: 14, inset: 22,
    stretchResponse: 0.42, stretchDamping: 0.55,
    retractResponse: 0.3, retractDamping: 0.9,
    followResponse: 0.28, followDamping: 0.82,
    detachLength: 0.55, detachGap: 0.4,
    recoil: 6, refractory: 0.3,
    dropSpeed: 1.5, gravity: 34, fall: 2.6,
    rippleLife: 0.6, maxDrops: 3
)

@Suite("NotchDripPolicy.reading", .timeLimit(.minutes(1)))
struct NotchDripReadingTests {
    // A 200x32 island at the top of a 1332 pt tall screen, AppKit space.
    let island = CGRect(x: 924, y: 1300, width: 200, height: 32)

    func reading(_ x: CGFloat, _ y: CGFloat) -> NotchDripReading? {
        NotchDripPolicy.reading(island: island, pointer: CGPoint(x: x, y: y), tuning: dripTuning)
    }

    @Test func fullFromNearAndOnTheIsland() {
        #expect(reading(1024, island.minY - 14)?.pull == 1)
        #expect(reading(1024, island.minY - 2)?.pull == 1)
        #expect(reading(1024, 1316)?.pull == 1)
    }

    @Test func noneBeyondTheReachOrAboveTheIsland() {
        #expect(reading(1024, island.minY - 48) == nil)
        #expect(reading(1024, island.minY - 200) == nil)
        #expect(reading(1024, island.maxY + 1) == nil)
    }

    @Test func pullRisesAsThePointerComesUp() {
        var last: CGFloat = 0
        for below in stride(from: CGFloat(46), through: 14, by: -2) {
            let pull = reading(1024, island.minY - below)?.pull ?? 0
            #expect(pull > last, "pull at \(below) pt below")
            last = pull
        }
        #expect(last == 1)
    }

    @Test func xFollowsThePointerAcrossTheFlatEdge() {
        let left = reading(island.minX + 60, island.minY - 10)
        let right = reading(island.minX + 140, island.minY - 10)
        #expect(left?.x == 0.3)
        #expect(right?.x == 0.7)
    }

    @Test func xStaysOffTheRoundedCorners() {
        let inset = dripTuning.inset / island.width
        // Under the corner: clamped to the flat edge, and pulling less.
        let corner = reading(island.minX + 4, island.minY - 10)
        #expect(abs((corner?.x ?? 0) - inset) < 1e-9)
        #expect((corner?.pull ?? 1) < 1)
        // Just past the island: still pulling, a little, from the last flat point.
        let beyond = reading(island.maxX + 10, island.minY - 10)
        #expect(abs((beyond?.x ?? 0) - (1 - inset)) < 1e-9)
        #expect(beyond.map { $0.pull > 0 && $0.pull < 0.5 } == true)
        // Past the fade (twice the inset beyond the flat edge): nothing.
        #expect(reading(island.maxX + dripTuning.inset, island.minY - 10) == nil)
    }

    @Test func tooNarrowOrEmptyIslandPullsNothing() {
        let narrow = CGRect(x: 0, y: 100, width: 40, height: 20)
        #expect(NotchDripPolicy.reading(island: narrow, pointer: CGPoint(x: 20, y: 90), tuning: dripTuning) == nil)
        #expect(NotchDripPolicy.reading(island: .zero, pointer: .zero, tuning: dripTuning) == nil)
    }
}

@Suite("NotchDripSim", .timeLimit(.minutes(1)))
struct NotchDripSimTests {
    let dt = 1.0 / 60

    /// Steps `seconds` toward `target`, at 60 Hz.
    func run(_ sim: inout NotchDripSim, _ seconds: Double, _ target: NotchDripReading?) {
        for _ in 0..<Int((seconds / dt).rounded()) { sim.step(dt: dt, target: target, tuning: dripTuning) }
    }

    @Test func startsAtRestAndInvisible() {
        let sim = NotchDripSim()
        #expect(sim.isAtRest(target: nil))
        #expect(!sim.isVisible)
    }

    @Test func stretchesTowardThePullAndComesToRest() {
        var sim = NotchDripSim()
        let target = NotchDripReading(pull: 0.8, x: 0.4)
        #expect(!sim.isAtRest(target: target))
        run(&sim, 0.1, target)
        #expect(sim.length > 0.1)
        #expect(sim.x == 0.4, "a new drip starts under the pointer")
        run(&sim, 3, target)
        #expect(abs(sim.length - 0.8) < 0.01)
        #expect(sim.isAtRest(target: target), "a still pointer costs nothing")
        #expect(sim.drops.isEmpty)
    }

    @Test func overshootsALittleOnTheWayOut() {
        var sim = NotchDripSim()
        let target = NotchDripReading(pull: 0.5, x: 0.5)
        var peak: CGFloat = 0
        for _ in 0..<120 {
            sim.step(dt: dt, target: target, tuning: dripTuning)
            peak = max(peak, sim.length)
        }
        #expect(peak > 0.5)
        #expect(peak < 0.5 * 1.3)
    }

    @Test func rootFollowsThePointerWithALag() {
        var sim = NotchDripSim()
        run(&sim, 2, NotchDripReading(pull: 0.6, x: 0.3))
        let moved = NotchDripReading(pull: 0.6, x: 0.7)
        run(&sim, 0.05, moved)
        #expect(sim.x > 0.3)
        #expect(sim.x < 0.7)
        #expect(sim.xVelocity > 0)
        run(&sim, 2, moved)
        #expect(abs(sim.x - 0.7) < 0.002)
    }

    @Test func aSlowExitDrawsBackWithoutADrop() {
        var sim = NotchDripSim()
        run(&sim, 2, NotchDripReading(pull: 1, x: 0.5))
        // The pointer backs off over a second: pull falls ~1 per second.
        for i in 0..<60 {
            let pull = 1 - CGFloat(i + 1) / 60
            sim.step(dt: dt, target: pull > 0 ? NotchDripReading(pull: pull, x: 0.5) : nil, tuning: dripTuning)
        }
        run(&sim, 1, nil)
        #expect(sim.drops.isEmpty)
        #expect(sim.ripples.isEmpty)
        #expect(sim.length < 0.01)
        #expect(sim.isAtRest(target: nil))
        #expect(!sim.isVisible)
    }

    @Test func aFlickAwayPinchesOffADropAndARipple() {
        var sim = NotchDripSim()
        run(&sim, 2, NotchDripReading(pull: 1, x: 0.6))
        sim.step(dt: dt, target: nil, tuning: dripTuning)
        #expect(sim.drops.count == 1)
        #expect(sim.ripples.count == 1)
        #expect(sim.drops.first?.x == 0.6)
        #expect(sim.ripples.first?.x == 0.6)
        #expect(sim.lengthVelocity < 0, "the stub recoils")
        #expect(!sim.isAtRest(target: nil))
        // The drop falls and is gone, the ripple fades, all within a second.
        var lastY: CGFloat = 0
        for _ in 0..<20 {
            sim.step(dt: dt, target: nil, tuning: dripTuning)
            if let y = sim.drops.first?.y { #expect(y > lastY); lastY = y }
        }
        #expect(sim.length < 0.5)
        run(&sim, 1, nil)
        #expect(sim.drops.isEmpty)
        #expect(sim.ripples.isEmpty)
        #expect(sim.isAtRest(target: nil))
    }

    @Test func aShortDripNeverPinches() {
        var sim = NotchDripSim()
        run(&sim, 2, NotchDripReading(pull: 0.4, x: 0.5))
        sim.step(dt: dt, target: nil, tuning: dripTuning)
        run(&sim, 1, nil)
        #expect(sim.drops.isEmpty)
    }

    @Test func theStubWaitsBeforeRegrowing() {
        var sim = NotchDripSim()
        let full = NotchDripReading(pull: 1, x: 0.5)
        run(&sim, 2, full)
        sim.step(dt: dt, target: NotchDripReading(pull: 0.1, x: 0.5), tuning: dripTuning)
        #expect(sim.drops.count == 1)
        // The pointer is back at once; the stub holds off, then grows again
        // without pinching a second drop.
        run(&sim, 0.2, full)
        #expect(sim.length < 0.3)
        run(&sim, 2, full)
        #expect(abs(sim.length - 1) < 0.01)
        #expect(sim.drops.isEmpty)
    }

    @Test func dropsAreCapped() {
        var sim = NotchDripSim()
        for _ in 0..<6 {
            run(&sim, 0.6, NotchDripReading(pull: 1, x: 0.5))
            sim.step(dt: dt, target: nil, tuning: dripTuning)
        }
        #expect(sim.drops.count <= dripTuning.maxDrops)
        #expect(sim.ripples.count <= dripTuning.maxDrops)
    }

    @Test func aLongFrameStaysStable() {
        var sim = NotchDripSim()
        sim.step(dt: 0.5, target: NotchDripReading(pull: 1, x: 0.5), tuning: dripTuning)
        #expect(sim.length.isFinite)
        #expect(sim.length < 2)
        sim.step(dt: 0, target: nil, tuning: dripTuning)
        #expect(sim.length.isFinite)
    }

    @Test func neverRisesAboveTheEdge() {
        var sim = NotchDripSim()
        run(&sim, 2, NotchDripReading(pull: 1, x: 0.5))
        for _ in 0..<120 {
            sim.step(dt: dt, target: nil, tuning: dripTuning)
            #expect(sim.length >= 0)
        }
    }
}

/// A fixed look, so these do not move when UmbarMotion.dripLook is retuned.
let dripLook = NotchDripLook(maxLength: 32, bulbRadius: 8...12, rootHalfWidth: 20...27, neck: 0.88, lean: 6)

@Suite("NotchDripShape", .timeLimit(.minutes(1)))
struct NotchDripShapeTests {
    let width: CGFloat = 200
    let flat: CGFloat = 17
    let dt = 1.0 / 60

    func shape(_ sim: NotchDripSim) -> NotchDripShape? {
        NotchDripShape(sim, width: width, flat: flat, look: dripLook)
    }

    func hanging(length: CGFloat, x: CGFloat = 0.5) -> NotchDripSim {
        var sim = NotchDripSim()
        sim.length = length
        sim.x = x
        return sim
    }

    @Test func nothingWhileNothingHangs() {
        #expect(shape(NotchDripSim()) == nil)
    }

    @Test func aFullDripIsAWideSagNotAThread() throws {
        let full = try #require(shape(hanging(length: 1)))
        #expect(full.radius == 12)
        #expect(2 * full.rootHalf == 54)
        // The neck stays most of the bulb's width.
        #expect(2 * full.neckHalf >= 20)
        // The tip reaches the full length.
        #expect(abs(full.bulb.y + full.radius - 32) < 1e-9)
    }

    @Test func aJustStartedDripIsAlreadyABulge() throws {
        let start = try #require(shape(hanging(length: 0.05)))
        #expect(start.radius >= 8)
        #expect(2 * start.rootHalf >= 40)
    }

    @Test func theNeckHoldsItsThicknessAsItStretchesAndDrawsBack() throws {
        for length in stride(from: CGFloat(0.1), through: 1, by: 0.1) {
            let s = try #require(shape(hanging(length: length)))
            #expect(s.neckHalf / s.radius > 0.85, "length \(length)")
        }
        // A slow retract (about one length per second) barely thins it.
        var slow = hanging(length: 0.6)
        slow.lengthVelocity = -1
        let s = try #require(shape(slow))
        #expect(s.neckHalf / s.radius > 0.75)
    }

    @Test func theNeckThinsAsItPinchesOff() throws {
        var sim = NotchDripSim()
        for _ in 0..<120 { sim.step(dt: dt, target: NotchDripReading(pull: 1, x: 0.5), tuning: dripTuning) }
        let before = try #require(shape(sim))
        sim.step(dt: dt, target: nil, tuning: dripTuning)
        #expect(sim.drops.count == 1)
        let after = try #require(shape(sim))
        #expect(after.neckHalf < before.neckHalf * 0.5)
    }

    @Test func theRootStaysOnTheFlatEdge() throws {
        // Every x the policy can hand it, down to the tightest inset.
        for x in [dripTuning.inset / width, 0.3, 0.5, 1 - dripTuning.inset / width] {
            let s = try #require(shape(hanging(length: 1, x: x)))
            #expect(s.rootX - s.rootHalf >= flat - 1e-9, "x \(x)")
            #expect(s.rootX + s.rootHalf <= width - flat + 1e-9, "x \(x)")
            #expect(s.neckHalf <= s.rootHalf)
        }
    }

    @Test func theBulbTrailsASlideByAtMostTheLean() throws {
        var sim = hanging(length: 1)
        sim.xVelocity = 50
        let s = try #require(shape(sim))
        #expect(abs(s.bulb.x - s.rootX - -6) < 1e-9)
    }
}
