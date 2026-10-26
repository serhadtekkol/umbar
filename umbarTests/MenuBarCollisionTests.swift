//
//  MenuBarCollisionTests.swift
//  umbarTests
//
//  Spike C4 (card #107): the ears-vs-chin decision and the NSScreen →
//  notch conversion. Fixture values are the ones Tools/MenuBarProbe
//  measured on the MacBook Air (Mac14,2, macOS 27.0.1, 2048 × 1332 pt
//  "More Space"); see docs/spikes/C4-menubar-collision.md, E1 and E5.
//

import CoreGraphics
import Testing

/// Air, measured (E1): notch 250 × 45 at x = 899, ears 45 × 45.
private let airFrame = CGRect(x: 0, y: 0, width: 2048, height: 1332)
private let airAuxLeft = CGRect(x: 0, y: 1287, width: 899, height: 45)
private let airAuxRight = CGRect(x: 1149, y: 1287, width: 899, height: 45)
private let air = NotchGeometry.make(screenFrame: airFrame, primaryScreenHeight: 1332,
                                     auxiliaryTopLeftArea: airAuxLeft, auxiliaryTopRightArea: airAuxRight,
                                     safeAreaTop: 45)!

/// A menu bar item in CG space on the Air's 46 pt bar.
private func item(x: CGFloat, width: CGFloat) -> CGRect {
    CGRect(x: x, y: 0, width: width, height: 46)
}

private func decide(_ rects: [CGRect], complete: Bool = true,
                    policy: UnmeasuredMenuBarPolicy = .assumeOccupied) -> ClosedIslandPlacement {
    MenuBarCollision.placement(geometry: air, occupancy: .init(occupied: rects, isComplete: complete), policy: policy)
}

@Suite("NotchGeometry")
struct NotchGeometryTests {
    @Test func airValuesGiveTheMeasuredNotchAndEars() {
        #expect(air.notch == CGRect(x: 899, y: 0, width: 250, height: 45))
        #expect(air.earWidth == 45)
        #expect(air.leftEar == CGRect(x: 854, y: 0, width: 45, height: 45))
        #expect(air.rightEar == CGRect(x: 1149, y: 0, width: 45, height: 45))
    }

    @Test func screensWithoutANotchHaveNoGeometry() {
        // Mac mini + LG UltraWide (E1): both areas nil, inset 0.
        let frame = CGRect(x: 0, y: 0, width: 2560, height: 1080)
        #expect(NotchGeometry.make(screenFrame: frame, primaryScreenHeight: 1080,
                                   auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil, safeAreaTop: 0) == nil)
        #expect(NotchGeometry.make(screenFrame: airFrame, primaryScreenHeight: 1332,
                                   auxiliaryTopLeftArea: airAuxLeft, auxiliaryTopRightArea: nil, safeAreaTop: 45) == nil)
        #expect(NotchGeometry.make(screenFrame: airFrame, primaryScreenHeight: 1332,
                                   auxiliaryTopLeftArea: airAuxLeft, auxiliaryTopRightArea: airAuxRight, safeAreaTop: 0) == nil)
    }

    @Test func overlappingAuxiliaryAreasMeanNoNotch() {
        // Left area running past the right area's start: no gap, no notch.
        let left = CGRect(x: 0, y: 1287, width: 1200, height: 45)
        #expect(NotchGeometry.make(screenFrame: airFrame, primaryScreenHeight: 1332,
                                   auxiliaryTopLeftArea: left, auxiliaryTopRightArea: airAuxRight, safeAreaTop: 45) == nil)
    }

    @Test func builtInScreenBelowATallerExternalPrimaryIsFlippedIntoCGSpace() {
        // Primary 1440 pt tall at the origin; Air placed below it in Cocoa
        // space, so its top edge is at Cocoa y = 0 → CG y = 1440.
        let frame = CGRect(x: 0, y: -1332, width: 2048, height: 1332)
        let left = airAuxLeft.offsetBy(dx: 0, dy: -1332)
        let right = airAuxRight.offsetBy(dx: 0, dy: -1332)
        let g = NotchGeometry.make(screenFrame: frame, primaryScreenHeight: 1440,
                                   auxiliaryTopLeftArea: left, auxiliaryTopRightArea: right, safeAreaTop: 45)
        #expect(g?.notch == CGRect(x: 899, y: 1440, width: 250, height: 45))
    }

    @Test func screenLocalAuxiliaryAreasAreShiftedOntoTheScreen() {
        // Same Air to the right of a 2560 pt primary; areas reported
        // relative to the screen instead of globally.
        let frame = CGRect(x: 2560, y: 0, width: 2048, height: 1332)
        let g = NotchGeometry.make(screenFrame: frame, primaryScreenHeight: 1332,
                                   auxiliaryTopLeftArea: airAuxLeft, auxiliaryTopRightArea: airAuxRight, safeAreaTop: 45)
        #expect(g?.notch == CGRect(x: 2560 + 899, y: 0, width: 250, height: 45))
    }

    @Test func globalAuxiliaryAreasOnAnOffsetScreenAreTakenAsIs() {
        let frame = CGRect(x: 2560, y: 0, width: 2048, height: 1332)
        let g = NotchGeometry.make(screenFrame: frame, primaryScreenHeight: 1332,
                                   auxiliaryTopLeftArea: airAuxLeft.offsetBy(dx: 2560, dy: 0),
                                   auxiliaryTopRightArea: airAuxRight.offsetBy(dx: 2560, dy: 0), safeAreaTop: 45)
        #expect(g?.notch == CGRect(x: 2560 + 899, y: 0, width: 250, height: 45))
    }
}

@Suite("MenuBarCollision")
struct MenuBarCollisionTests {
    @Test func emptyMenuBarFullyMeasuredGivesEars() {
        #expect(decide([]) == .ears)
    }

    @Test func statusItemsWhereTheAirPutThemWithFewItemsGiveEars() {
        // E5: with the Air's own items, the leftmost sat at x = 1352…1472.
        #expect(decide([item(x: 1352, width: 40), item(x: 1392, width: 40), item(x: 1432, width: 40)]) == .ears)
    }

    @Test func statusItemAtTheObservedVisibleLimitGivesChin() {
        // E5: the leftmost *visible* status item on a full bar started at
        // x = 1193, 1 pt inside the right ear (1149…1194).
        #expect(decide([item(x: 1193, width: 31)]) == .chin)
    }

    @Test func clearanceTurnsANearMissIntoAChin() {
        // 1196 is 2 pt right of the ear: clear geometrically, but inside
        // the default 4 pt clearance.
        #expect(MenuBarCollision.placement(geometry: air, occupancy: .init(occupied: [item(x: 1196, width: 23)], isComplete: true),
                                           policy: .assumeOccupied, clearance: 0) == .ears)
        #expect(decide([item(x: 1196, width: 23)]) == .chin)
    }

    @Test func itemEndingExactlyAtTheClearanceEdgeIsNotACollision() {
        // Right zone ends at 1194 + 4 = 1198; left zone starts at 854 − 4 = 850.
        #expect(decide([item(x: 1198, width: 30)]) == .ears)
        #expect(decide([item(x: 800, width: 50)]) == .ears)
    }

    @Test func longAppMenuReachingTheLeftEarGivesChin() {
        // An app menu title ending at x = 860 runs 6 pt into the left ear.
        #expect(decide([item(x: 790, width: 70)]) == .chin)
    }

    @Test func itemsUnderTheNotchItselfAreNotEarCollisions() {
        // Nothing can draw under the camera housing; a rect there (e.g. a
        // parked hidden item reported with a bogus frame) only matters if it
        // reaches an ear zone.
        #expect(decide([CGRect(x: 950, y: 0, width: 100, height: 46)]) == .ears)
    }

    @Test func rectsBelowTheMenuBarAreIgnored() {
        // A popover or open menu hanging under the ear column.
        #expect(decide([CGRect(x: 1150, y: 50, width: 360, height: 400)]) == .ears)
        // ...but one that starts inside the bar still counts.
        #expect(decide([CGRect(x: 1150, y: 40, width: 40, height: 400)]) == .chin)
    }

    @Test func degenerateRectsAreIgnoredAndFlippedRectsAreStandardized() {
        #expect(decide([.null, CGRect(x: 1160, y: 0, width: 0, height: 46), .infinite]) == .ears)
        #expect(decide([CGRect(x: 1190, y: 46, width: -30, height: -46)]) == .chin, "same as x 1160…1190, y 0…46")
    }

    @Test func incompleteMeasurementFallsBackToPolicy() {
        #expect(decide([], complete: false, policy: .assumeFree) == .ears)
        #expect(decide([], complete: false, policy: .assumeOccupied) == .chin)
        #expect(decide([item(x: 1300, width: 40)], complete: false, policy: .assumeFree) == .ears)
    }

    @Test func measuredCollisionWinsOverAnyPolicy() {
        #expect(decide([item(x: 1160, width: 40)], complete: false, policy: .assumeFree) == .chin)
    }

    @Test func unknownOccupancyIsIncomplete() {
        #expect(MenuBarOccupancy.unknown.isComplete == false)
        #expect(MenuBarCollision.placement(geometry: air, occupancy: .unknown, policy: .assumeOccupied) == .chin)
    }

    @Test func negativeClearanceIsTreatedAsZero() {
        #expect(MenuBarCollision.collisions(geometry: air, occupied: [item(x: 1194, width: 20)], clearance: -10).isEmpty)
        #expect(MenuBarCollision.collisions(geometry: air, occupied: [item(x: 1193, width: 20)], clearance: -10).count == 1)
    }

    @Test func collisionsReportOnlyTheOffendingRects() {
        let hit = item(x: 1160, width: 40)
        let miss = item(x: 1300, width: 40)
        #expect(MenuBarCollision.collisions(geometry: air, occupied: [miss, hit]) == [hit])
    }

    @Test func virtualNotchOnAScreenWithoutOneUsesTheSameRule() {
        // Non-notch displays (Mac mini, E1): the caller passes the island's
        // drawn rect as the "notch". 185 pt default width, 30 pt bar.
        let g = NotchGeometry(notch: CGRect(x: 1187.5, y: 0, width: 185, height: 30))
        #expect(MenuBarCollision.placement(geometry: g, occupancy: .init(occupied: [CGRect(x: 1889, y: 0, width: 40, height: 30)], isComplete: true),
                                           policy: .assumeOccupied) == .ears)
    }
}
