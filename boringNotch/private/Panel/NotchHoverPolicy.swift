//
//  NotchHoverPolicy.swift
//  boringNotch
//
//  When pointer position opens and folds the notch (AC-1.1, AC-1.4 (R1.2)).
//  Foundation/CoreGraphics only, so umbarTests can compile it without AppKit.
//
//  Why geometry and not SwiftUI's onHover: on the Air the pointer rests on
//  the top row of the screen, which is also the window's top edge. Every
//  time SwiftUI rebuilds the hover tracking area (the open animation, a
//  badge or the network meter re-laying out) it re-tests that edge point
//  and reports an exit with the pointer standing still, then an enter on
//  the next mouse event. The old 100 ms close turned each of those into a
//  fold and the pointer, still on the notch, reopened it: the open/close
//  loop of the hover-flicker bug. onHover is now only a hint; whether the
//  pointer is on the notch is answered from the pointer location and the
//  rects below, with inclusive edges.
//

import CoreGraphics
import Foundation

enum NotchHoverGeometry {
    /// Whether `point` is in `rect`, edges included. AppKit's NSPointInRect
    /// excludes the max edges, and the pointer pinned to the top of the
    /// screen sits exactly on the window's maxY.
    static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        guard !rect.isNull, !rect.isEmpty else { return false }
        return point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }

    /// Converts a SwiftUI `.global` frame of the notch window's root view
    /// (origin top-left of the content area, y down) to screen coordinates
    /// (origin bottom-left, y up), the space of `NSEvent.mouseLocation`.
    static func screenRect(ofViewFrame frame: CGRect, inWindowFrame window: CGRect) -> CGRect {
        CGRect(
            x: window.minX + frame.minX,
            y: window.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    /// The rect the pointer must leave before an open panel folds. It is the
    /// whole notch window, so it always contains the closed island: moving
    /// from the closed hit area into the open one can never read as an exit
    /// (the hysteresis the bug lacked). The window's few points of shadow
    /// padding below the panel are inside it on purpose.
    static func openRect(windowFrame: CGRect, closedRect: CGRect) -> CGRect {
        windowFrame.union(closedRect)
    }
}

/// Decides when an open panel folds because the pointer left it.
///
/// Fed one sample per pointer check: inside or outside the open rect, and a
/// monotonic time in seconds. The panel folds only once the pointer has been
/// outside for `closeDelay` without a single inside sample in between
/// (AC-1.4 (R1.2): 500 ms). A panel the pointer has never been on (a
/// keyboard, screenshot or reminder opening) is not armed and never folds
/// here; those have their own closes.
///
/// Value type, no clocks, no AppKit: the caller owns time and geometry.
struct NotchHoverTracker: Equatable {
    /// AC-1.4 (R1.2).
    static let closeDelay: TimeInterval = 0.5

    /// The pointer has been on the open panel since it opened.
    private(set) var isArmed = false
    /// When the current run of outside samples began; nil while inside.
    private(set) var outsideSince: TimeInterval?

    /// Records one sample. Returns true when the panel should fold now.
    /// Keeps returning true on later outside samples until `reset()`, so a
    /// close the caller had to hold back (share sheet, key panel) happens as
    /// soon as the hold is lifted.
    mutating func sample(isInside: Bool, at now: TimeInterval) -> Bool {
        if isInside {
            isArmed = true
            outsideSince = nil
            return false
        }
        guard isArmed else { return false }
        let since = outsideSince ?? now
        outsideSince = since
        return now - since >= Self.closeDelay
    }

    /// The panel opened or folded; start over.
    mutating func reset() {
        self = NotchHoverTracker()
    }
}
