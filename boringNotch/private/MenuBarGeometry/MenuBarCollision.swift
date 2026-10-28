//
//  MenuBarCollision.swift
//  boringNotch
//
//  Spike C4 (card #107): decide whether the closed island may grow "ears"
//  beside the notch (W + 2H, design-language.md "Aşağı büyü") or must fall
//  back to a "chin" below it because something already occupies the menu
//  bar there (AC-1.8). Evidence and the reasoning behind every rule here
//  live in docs/spikes/C4-menubar-collision.md; keep the two in sync.
//
//  CoreGraphics only and free of side effects: the caller measures the
//  screen and the menu bar, this file only does geometry and the decision.
//  See umbarTests/MenuBarCollisionTests.
//
//  Coordinate space: every rect passed in or returned is in the global
//  CoreGraphics space (origin at the top-left of the primary display, y
//  grows downward). That is the space Accessibility (AXPosition/AXSize) and
//  CGWindowListCopyWindowInfo report in, so measured rects need no
//  conversion; only NSScreen values do, via `NotchGeometry.make`.
//

import CoreGraphics

/// Where the closed island may draw its activity indicators.
enum ClosedIslandPlacement: Equatable, Sendable {
    /// Square ears of width H on both sides of the notch.
    case ears
    /// A strip below the notch; nothing grows sideways into the menu bar.
    case chin
}

/// The hardware notch of one screen, in global CG coordinates.
struct NotchGeometry: Equatable, Sendable {
    /// The notch cut-out itself: between the two auxiliary top areas, as tall
    /// as the safe-area inset.
    var notch: CGRect

    /// Ear width equals notch height (design-language.md: ear = H × H).
    var earWidth: CGFloat { notch.height }

    /// The ear squares directly left and right of the notch.
    var leftEar: CGRect {
        CGRect(x: notch.minX - earWidth, y: notch.minY, width: earWidth, height: notch.height)
    }

    var rightEar: CGRect {
        CGRect(x: notch.maxX, y: notch.minY, width: earWidth, height: notch.height)
    }

    /// Builds the notch rect from the values `NSScreen` exposes.
    ///
    /// - Parameters:
    ///   - screenFrame: `NSScreen.frame` (Cocoa space, bottom-left origin).
    ///   - primaryScreenHeight: `NSScreen.screens[0].frame.height`, used to
    ///     flip Cocoa y into CG y. Must be the *primary* screen, not `main`.
    ///   - auxiliaryTopLeftArea / auxiliaryTopRightArea: the screen's
    ///     auxiliary areas (Cocoa space). `nil` on displays without a notch.
    ///   - safeAreaTop: `NSScreen.safeAreaInsets.top`; 0 without a notch.
    /// - Returns: `nil` when the screen has no notch (either area missing,
    ///   zero inset, or areas that leave no gap between them). Callers then
    ///   have no physical notch to hug and must not use ears geometry at all.
    static func make(
        screenFrame: CGRect,
        primaryScreenHeight: CGFloat,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?,
        safeAreaTop: CGFloat
    ) -> NotchGeometry? {
        guard var left = auxiliaryTopLeftArea, var right = auxiliaryTopRightArea,
              safeAreaTop > 0 else { return nil }
        // NSScreen.h does not say which space the auxiliary areas are in. On
        // the Air (built-in screen at the origin) both readings coincide, so
        // spike C4 could not tell. Accept either: an area that does not lie
        // inside the screen frame is taken as screen-local and shifted.
        // TODO(emrullah): verify on a notched Mac with an external primary
        // display and drop the branch that turns out dead — see #107.
        if !screenFrame.contains(left) { left = left.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY) }
        if !screenFrame.contains(right) { right = right.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY) }
        guard right.minX > left.maxX else { return nil }
        // Cocoa: the notch's top edge is the screen's top edge (maxY).
        // CG: y = primaryHeight - cocoaMaxY.
        let top = primaryScreenHeight - screenFrame.maxY
        return NotchGeometry(notch: CGRect(x: left.maxX, y: top,
                                           width: right.minX - left.maxX,
                                           height: safeAreaTop))
    }
}

/// What is known about the menu bar items next to the notch.
///
/// Two independent sources feed this: the frontmost app's menu titles and
/// the menu bar extras (status items). On macOS 27.0.1 both are readable
/// only through Accessibility, which umbar may not have (spike C4, E3/E4).
/// `isComplete` is false whenever a source could not be read, so "nothing
/// measured" is never mistaken for "nothing there".
struct MenuBarOccupancy: Equatable, Sendable {
    /// Frames of menu titles and status items that were measured.
    var occupied: [CGRect]
    /// True only when every source was read successfully.
    var isComplete: Bool

    static let unknown = MenuBarOccupancy(occupied: [], isComplete: false)
}

/// What to do when occupancy could not be fully measured and the part that
/// was measured shows no collision.
enum UnmeasuredMenuBarPolicy: Equatable, Sendable {
    /// Draw ears anyway (AC-1.8 is then a best effort, not a guarantee).
    case assumeFree
    /// Draw the chin; AC-1.8 holds by construction.
    case assumeOccupied
}

enum MenuBarCollision {
    /// Horizontal breathing room, in points, required between an ear and the
    /// nearest menu bar item. The island is drawn 2 pt wider than the notch
    /// on each side (`getClosedNotchSize` adds 4), and a further 2 pt keeps a
    /// glyph from visually touching a status item's highlight capsule.
    static let defaultClearance: CGFloat = 4

    /// Decides between ears and chin.
    ///
    /// The rule is three-valued on purpose: a measured collision always
    /// forces the chin, even if other sources were unreadable; only when the
    /// measured part is clear does `policy` settle the unmeasured rest.
    ///
    /// - Parameters:
    ///   - geometry: the notch of the screen the island is on.
    ///   - occupancy: measured menu bar item frames (global CG space).
    ///   - policy: applied only when `occupancy.isComplete` is false and no
    ///     measured rect collides.
    ///   - clearance: see `defaultClearance`; must be ≥ 0.
    static func placement(
        geometry: NotchGeometry,
        occupancy: MenuBarOccupancy,
        policy: UnmeasuredMenuBarPolicy,
        clearance: CGFloat = defaultClearance
    ) -> ClosedIslandPlacement {
        if !collisions(geometry: geometry, occupied: occupancy.occupied, clearance: clearance).isEmpty {
            return .chin
        }
        if occupancy.isComplete { return .ears }
        return policy == .assumeFree ? .ears : .chin
    }

    /// The measured rects that would touch either ear (for logging and
    /// tests). Rects that do not share the ear row vertically are ignored:
    /// a popover or a menu hanging below the bar is not a menu bar item.
    static func collisions(
        geometry: NotchGeometry,
        occupied: [CGRect],
        clearance: CGFloat = defaultClearance
    ) -> [CGRect] {
        let pad = max(0, clearance)
        let zones = [geometry.leftEar, geometry.rightEar].map { $0.insetBy(dx: -pad, dy: 0) }
        return occupied.filter { item in
            let item = item.standardized
            guard !item.isNull, !item.isInfinite else { return false }
            return zones.contains { overlaps($0, item) }
        }
    }

    /// Strict positive-area overlap. `CGRect.intersects` is avoided because
    /// edge-adjacent rects and zero-width rects must not count: a status item
    /// that ends exactly where the clearance zone starts is not a collision.
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let w = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let h = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return w > 0 && h > 0
    }
}
