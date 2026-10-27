//
//  NotchHoverPolicyTests.swift
//  umbarTests
//
//  Hover-flicker P0: a hover-opened panel folded and reopened in a loop
//  while the pointer rested on the notch. These pin the geometry and the
//  500 ms dwell that replaced the 100 ms close on SwiftUI's exit event
//  (AC-1.4 (R1.2)).
//

import CoreGraphics
import Foundation
import Testing

@Suite("NotchHoverGeometry", .timeLimit(.minutes(1)))
struct NotchHoverGeometryTests {
    // The Air's notch window as logged during the bug: 640x210 at the top
    // of a 1332 pt tall screen.
    let window = CGRect(x: 704, y: 1122, width: 640, height: 210)

    @Test func pointerPinnedToTheTopOfTheScreenIsInside() {
        // The exact point the bug was logged at: y == window.maxY. AppKit's
        // half-open rects call this outside.
        #expect(NotchHoverGeometry.contains(window, CGPoint(x: 1037.9, y: 1332)))
    }

    @Test func allFourEdgesAreInside() {
        #expect(NotchHoverGeometry.contains(window, CGPoint(x: window.minX, y: window.minY)))
        #expect(NotchHoverGeometry.contains(window, CGPoint(x: window.maxX, y: window.maxY)))
    }

    @Test func justOutsideIsOutside() {
        #expect(!NotchHoverGeometry.contains(window, CGPoint(x: window.minX - 0.5, y: 1300)))
        #expect(!NotchHoverGeometry.contains(window, CGPoint(x: 1000, y: window.minY - 0.5)))
        #expect(!NotchHoverGeometry.contains(window, CGPoint(x: window.maxX + 0.5, y: 1300)))
    }

    @Test func emptyAndNullRectsContainNothing() {
        #expect(!NotchHoverGeometry.contains(.zero, .zero))
        #expect(!NotchHoverGeometry.contains(.null, .zero))
    }

    @Test func viewFrameConvertsFromTopLeftToScreenSpace() {
        // The closed island as logged: {{189, 0}, {262, 45}} in the window.
        let closed = NotchHoverGeometry.screenRect(
            ofViewFrame: CGRect(x: 189, y: 0, width: 262, height: 45),
            inWindowFrame: window
        )
        #expect(closed == CGRect(x: 893, y: 1287, width: 262, height: 45))
        #expect(closed.maxY == window.maxY)
    }

    @Test func openRectAlwaysContainsTheClosedIsland() {
        // A closed island wider than the window (a battery or live-activity
        // strip can be) must still be inside the open rect, or moving from
        // closed to open would read as an exit.
        let wideClosed = CGRect(x: 650, y: 1250, width: 760, height: 82)
        let open = NotchHoverGeometry.openRect(windowFrame: window, closedRect: wideClosed)
        #expect(open.contains(wideClosed))
        #expect(open.contains(window))
        #expect(NotchHoverGeometry.openRect(windowFrame: window, closedRect: .null) == window)
    }
}

@Suite("NotchHoverTracker", .timeLimit(.minutes(1)))
struct NotchHoverTrackerTests {
    /// Feeds (inside, time) samples in order and returns each answer.
    private func feed(_ tracker: inout NotchHoverTracker, _ samples: [(Bool, TimeInterval)]) -> [Bool] {
        samples.map { tracker.sample(isInside: $0.0, at: $0.1) }
    }

    @Test func closeDelayIsTheSpecs500ms() {
        #expect(NotchHoverTracker.closeDelay == 0.5)
    }

    @Test func foldsAfter500msOutside() {
        var tracker = NotchHoverTracker()
        let due = feed(&tracker, [(true, 0), (false, 1.0), (false, 1.45), (false, 1.5)])
        #expect(due == [false, false, false, true])
    }

    @Test func aBriefExitDoesNotFold() {
        // What the old 100 ms close turned into a fold: out for less than
        // the delay, then back. The outside run restarts from the return.
        var tracker = NotchHoverTracker()
        let due = feed(&tracker, [
            (true, 0), (false, 0.10), (false, 0.40), (true, 0.45),
            (false, 0.50), (false, 0.95), (false, 1.00),
        ])
        #expect(due == [false, false, false, false, false, false, true])
    }

    @Test func aPanelThePointerNeverReachedDoesNotFold() {
        // Keyboard, screenshot-shelf and reminder openings: the pointer is
        // elsewhere from the start; those panels have their own closes.
        var tracker = NotchHoverTracker()
        let samples = stride(from: 0.0, through: 5.0, by: 0.05).map { (false, $0) }
        #expect(!feed(&tracker, samples).contains(true))
        #expect(!tracker.isArmed)
    }

    @Test func staysDueUntilResetSoAHeldCloseHappensLater() {
        // The caller holds the fold back while a share sheet is up; the next
        // outside sample after the hold still says fold.
        var tracker = NotchHoverTracker()
        let due = feed(&tracker, [(true, 0), (false, 0.1), (false, 0.6), (false, 3.0)])
        #expect(due == [false, false, true, true])
    }

    @Test func resetDisarms() {
        var tracker = NotchHoverTracker()
        _ = feed(&tracker, [(true, 0), (false, 0.1)])
        tracker.reset()
        #expect(tracker == NotchHoverTracker())
        #expect(feed(&tracker, [(false, 10)]) == [false])
    }
}
