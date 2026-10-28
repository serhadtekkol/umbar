//
//  EyeBreakBannerHitPolicy.swift
//  boringNotch
//
//  Which pointer positions on the eye-break banner pass clicks through to
//  the app behind (C7-H, Can's design review: the banner covers the top
//  centre of a full-screen browser for 20 s). Pure geometry, so the
//  umbarTests bundle can compile it on its own.
//

import CoreGraphics

enum EyeBreakBannerHitPolicy {
    /// `point`, `banner` and `targets` are in the window's top-left space
    /// (SwiftUI's global space in the notch window).
    ///
    /// The strip the height of the notch is never passed through: the
    /// banner's neck there is where the closed island's hover opens the
    /// panel, and beside the neck the banner draws nothing, so the window's
    /// transparency already lets those clicks through. Below it everything
    /// passes through unless it is on a button.
    static func passesThrough(_ point: CGPoint, banner: CGRect, notchHeight: CGFloat, targets: [CGRect]) -> Bool {
        let body = CGRect(x: banner.minX, y: banner.minY + notchHeight,
                          width: banner.width, height: max(0, banner.height - notchHeight))
        guard body.contains(point) else { return false }
        return !targets.contains { $0.contains(point) }
    }

    /// AppKit screen point (bottom-left origin) to the window's top-left space.
    static func windowPoint(screen: CGPoint, windowFrame: CGRect) -> CGPoint {
        CGPoint(x: screen.x - windowFrame.minX, y: windowFrame.maxY - screen.y)
    }
}
