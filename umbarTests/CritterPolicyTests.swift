//
//  CritterPolicyTests.swift
//  umbarTests
//
//  The idle critter: when one may cross, how long the wait is, which one
//  comes, and the path it takes (lane below the island, hidden in the
//  tunnel, crumbs eaten in walking order). Pure; nothing is drawn or played.
//

import CoreGraphics
import Foundation
import Testing

@Suite("CritterPolicy.mayAppear", .timeLimit(.minutes(1)))
struct CritterAppearTests {
    @Test func theQuietClosedIslandAllowsOne() {
        #expect(CritterPolicy.mayAppear(CritterConditions()))
    }

    @Test func eachBusySignalKeepsItAway() {
        let blockers: [(String, (inout CritterConditions) -> Void)] = [
            ("off", { $0.enabled = false }),
            ("reduce motion", { $0.reduceMotion = true }),
            ("panel open", { $0.notchClosed = false }),
            ("full screen", { $0.islandHidden = true }),
            ("music", { $0.musicActive = true }),
            ("HUD / sneak peek", { $0.transientShowing = true }),
            ("live strip", { $0.liveStripShown = true }),
            ("eye break", { $0.eyeBreakBannerShown = true }),
            ("pointer", { $0.pointerNear = true }),
            ("locked or asleep", { $0.userAway = true }),
            ("hello animation", { $0.helloAnimationRunning = true }),
        ]
        for (name, apply) in blockers {
            var c = CritterConditions()
            apply(&c)
            #expect(!CritterPolicy.mayAppear(c), "\(name) should keep the critter away")
        }
    }

    @Test func musicIsAllowedOnlyWhenTheUserSaysSo() {
        var c = CritterConditions()
        c.musicActive = true
        c.allowWhileMusic = true
        #expect(CritterPolicy.mayAppear(c))
        // The switch does not override anything else.
        c.pointerNear = true
        #expect(!CritterPolicy.mayAppear(c))
    }

    @Test func reduceMotionAndTheSwitchStopTheClock() {
        #expect(CritterPolicy.schedules(enabled: true, reduceMotion: false))
        #expect(!CritterPolicy.schedules(enabled: true, reduceMotion: true))
        #expect(!CritterPolicy.schedules(enabled: false, reduceMotion: false))
    }
}

@Suite("CritterPolicy.nextDelay", .timeLimit(.minutes(1)))
struct CritterScheduleTests {
    @Test func delaysStayWithinTheJitterOfTheMean() {
        let means: [(CritterFrequency, TimeInterval)] = [(.rarely, 900), (.sometimes, 300), (.often, 60)]
        for (frequency, mean) in means {
            #expect(frequency.meanInterval == mean)
            for u in stride(from: 0.0, through: 1.0, by: 0.05) {
                let d = CritterPolicy.nextDelay(frequency, unit: u)
                #expect(d >= mean * 0.65 - 1e-9 && d <= mean * 1.35 + 1e-9)
            }
            #expect(CritterPolicy.nextDelay(frequency, unit: 0) < CritterPolicy.nextDelay(frequency, unit: 1))
        }
    }

    @Test func outOfRangeUnitsAreClamped() {
        #expect(CritterPolicy.nextDelay(.often, unit: -3) == CritterPolicy.nextDelay(.often, unit: 0))
        #expect(CritterPolicy.nextDelay(.often, unit: 9) == CritterPolicy.nextDelay(.often, unit: 1))
    }

    @Test func frequenciesDoNotOverlap() {
        // Even the longest "often" wait is shorter than the shortest "now and then".
        #expect(CritterPolicy.nextDelay(.often, unit: 1) < CritterPolicy.nextDelay(.sometimes, unit: 0))
        #expect(CritterPolicy.nextDelay(.sometimes, unit: 1) < CritterPolicy.nextDelay(.rarely, unit: 0))
    }

    @Test func mixedPicksEveryKindAndAFixedChoiceSticks() {
        let picked = Set(stride(from: 0.0, to: 1.0, by: 0.1).map { CritterChoice.mixed.kind(unit: $0) })
        #expect(picked == Set(CritterKind.allCases))
        #expect(CritterChoice.mixed.kind(unit: 1) == CritterKind.allCases.last)
        for u in [0.0, 0.5, 0.99] {
            #expect(CritterChoice.beetle.kind(unit: u) == .beetle)
            #expect(CritterChoice.caterpillar.kind(unit: u) == .caterpillar)
            #expect(CritterChoice.comet.kind(unit: u) == .comet)
        }
    }
}

@Suite("CritterPath", .timeLimit(.minutes(1)))
struct CritterPathTests {
    /// The notch sizes MotionFrameRenderer draws, in a 680 pt window.
    static let islands: [CGSize] = [CGSize(width: 190, height: 37), CGSize(width: 200, height: 32), CGSize(width: 254, height: 45)]
    static let maxSpan: CGFloat = 672

    private func path(_ island: CGSize, _ direction: CritterDirection = .leftToRight) throws -> CritterPath {
        try #require(CritterPath(islandWidth: island.width, islandHeight: island.height,
                                 maxSpan: Self.maxSpan, direction: direction))
    }

    @Test func aCrossingLastsThreeToFiveSeconds() throws {
        for island in Self.islands {
            let p = try path(island)
            #expect(p.duration >= 3 && p.duration <= 5)
        }
    }

    @Test func itFitsTheWindow() throws {
        for island in Self.islands {
            let p = try path(island)
            #expect(p.span <= Self.maxSpan)
            for t in stride(from: 0, through: p.duration, by: 0.05) {
                #expect(abs(p.pose(at: t).x) <= p.span / 2)
            }
        }
    }

    @Test func itWalksBelowTheIslandAndHidesInsideIt() throws {
        for island in Self.islands {
            let p = try path(island)
            var sawHidden = false
            for t in stride(from: CritterPath.leadIn, through: p.duration, by: 0.01) {
                let pose = p.pose(at: t)
                if abs(pose.x) > island.width / 2 + CritterPath.diveOutside {
                    // Outside the island: on the lane, wholly below the menu bar.
                    #expect(pose.y - CritterPath.spriteHalfHeight >= island.height)
                }
                if abs(pose.x) < island.width / 2 - CritterPath.diveInside {
                    #expect(p.isHidden(pose))
                    sawHidden = true
                }
            }
            #expect(sawHidden)
        }
    }

    @Test func itStartsAndEndsFadedAtTheFarEnds() throws {
        let p = try path(Self.islands[1])
        let first = p.pose(at: 0), last = p.pose(at: p.duration)
        #expect(first.opacity == 0 && last.opacity == 0)
        #expect(first.x < 0 && last.x > 0)
        #expect(p.pose(at: p.duration / 2).opacity == 1)
        // Moving steadily one way.
        var previous = -CGFloat.infinity
        for t in stride(from: CritterPath.leadIn, through: p.duration, by: 0.02) {
            let x = p.pose(at: t).x
            #expect(x >= previous)
            previous = x
        }
    }

    @Test func rightToLeftIsTheMirror() throws {
        let ltr = try path(Self.islands[0]), rtl = try path(Self.islands[0], .rightToLeft)
        for t in stride(from: 0, through: ltr.duration, by: 0.1) {
            #expect(abs(ltr.pose(at: t).x + rtl.pose(at: t).x) < 1e-6)
            #expect(abs(ltr.pose(at: t).y - rtl.pose(at: t).y) < 1e-6)
        }
        #expect(zip(ltr.crumbs, rtl.crumbs).allSatisfy { abs($0.x + $1.x) < 1e-6 && $0.eatenAt == $1.eatenAt })
    }

    @Test func crumbsLieOnBothSidesAndAreEatenInOrder() throws {
        for island in Self.islands {
            let p = try path(island)
            #expect(p.crumbs.contains { $0.x < -island.width / 2 })
            #expect(p.crumbs.contains { $0.x > island.width / 2 })
            #expect(p.crumbs.allSatisfy { abs($0.x) > island.width / 2 && $0.y > island.height })
            #expect(zip(p.crumbs, p.crumbs.dropFirst()).allSatisfy { $0.eatenAt < $1.eatenAt && $0.x < $1.x })
            #expect(p.eatenCount(at: CritterPath.leadIn) == 0)
            #expect(p.eatenCount(at: p.duration) == p.crumbs.count)
            // The head is on the crumb when it is eaten.
            for crumb in p.crumbs {
                #expect(abs(p.pose(at: crumb.eatenAt).x - crumb.x) < 0.5)
            }
        }
    }

    @Test func noRoomOrNoIslandMeansNoCrossing() {
        #expect(CritterPath(islandWidth: 600, islandHeight: 32, maxSpan: Self.maxSpan, direction: .leftToRight) == nil)
        #expect(CritterPath(islandWidth: 200, islandHeight: 0, maxSpan: Self.maxSpan, direction: .leftToRight) == nil)
        // A wide island (music ears out) still fits, with a shorter lane.
        let wide = CritterPath(islandWidth: 480, islandHeight: 32, maxSpan: Self.maxSpan, direction: .leftToRight)
        #expect(wide != nil && wide!.reach < CritterPath.preferredReach && wide!.span <= Self.maxSpan)
    }
}
