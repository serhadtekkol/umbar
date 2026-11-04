//
//  NotchApproachPolicy.swift
//  boringNotch
//
//  How close the pointer is to the closed island, as 0...1, for the hover
//  hint to lean toward it before the pointer arrives (design-language §3.7
//  `motion.hoverHint`). Purely visual: opening still waits for the pointer
//  to rest on the island (NotchHoverPolicy.swift).
//  Foundation/CoreGraphics only, so umbarTests can compile it without AppKit.
//

import CoreGraphics
import Foundation

enum NotchApproachPolicy {
    /// 1 on or inside `rect`, falling linearly to 0 at `reach` points from
    /// its nearest edge, rounded to `steps` levels so a pointer drifting a
    /// point at a time does not restart the spring on every mouse event.
    /// `rect` and `pointer` share one coordinate space.
    static func approach(to rect: CGRect, pointer: CGPoint, reach: CGFloat, steps: Int) -> CGFloat {
        guard !rect.isNull, !rect.isEmpty, reach > 0, steps > 0 else { return 0 }
        let dx = max(rect.minX - pointer.x, 0, pointer.x - rect.maxX)
        let dy = max(rect.minY - pointer.y, 0, pointer.y - rect.maxY)
        let distance = (dx * dx + dy * dy).squareRoot()
        let linear = min(max(1 - distance / reach, 0), 1)
        return (linear * CGFloat(steps)).rounded() / CGFloat(steps)
    }
}
