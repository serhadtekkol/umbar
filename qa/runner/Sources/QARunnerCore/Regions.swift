import CoreGraphics
import Foundation

/// The display the regions are defined on, in Quartz global coordinates
/// (origin top-left of the main display, y down), the space shared by
/// `CGDisplayBounds`, AX frames and `CGEvent` locations.
public struct DisplayGeometry: Equatable, Sendable {
    public var bounds: CGRect
    /// Width of the camera housing, from `NSScreen.auxiliaryTopLeftArea` /
    /// `auxiliaryTopRightArea`. `nil` on a display without a notch.
    public var notchWidth: CGFloat?

    public init(bounds: CGRect, notchWidth: CGFloat?) {
        self.bounds = bounds
        self.notchWidth = notchWidth
    }
}

/// Fixed capture rectangles (§3.5 `capture.region`). There is no free
/// rectangle and no full-screen variant; `finder-drop` is not a rectangle at
/// all but a single-window capture (see `CapturePlan.window`).
public enum Regions {
    /// Horizontal padding on each side of the notch (§3.5: "notch genişliği
    /// + 2×200 pt").
    public static let sidePadding: CGFloat = 200
    /// Height of the notch region (§3.5: 360 pt), tall enough for umbar's
    /// expanded panel.
    public static let notchHeight: CGFloat = 360
    /// Height of the HUD strip. The design names the region but not its
    /// size; umbar's HUD is drawn in the closed-notch band, so this is the
    /// top 120 pt of the notch region. To be confirmed by Habibe on the Air.
    public static let hudHeight: CGFloat = 120

    public static func rect(_ name: RegionName, on display: DisplayGeometry) -> Result<CGRect, Refusal> {
        guard let notchWidth = display.notchWidth, notchWidth > 0 else {
            return .failure(Refusal(.noNotchDisplay))
        }
        let width = min(notchWidth + 2 * sidePadding, display.bounds.width)
        let x = display.bounds.midX - width / 2
        let top = display.bounds.minY
        switch name {
        case .notch, .shelf:
            // umbar's shelf lives inside the expanded notch panel, so the
            // shelf region is the notch region. Kept as a separate name so
            // evidence files say what was being checked, and so the two can
            // diverge without changing the wire protocol.
            return .success(CGRect(x: x, y: top, width: width, height: min(notchHeight, display.bounds.height)))
        case .hud:
            return .success(CGRect(x: x, y: top, width: width, height: min(hudHeight, display.bounds.height)))
        case .finderDrop:
            return .failure(Refusal(.regionRejected, "finder-drop-is-a-window"))
        }
    }

    /// A point inside the physical notch, where the cursor opens umbar.
    public static func notchHoverPoint(on display: DisplayGeometry) -> Result<CGPoint, Refusal> {
        guard let notchWidth = display.notchWidth, notchWidth > 0 else {
            return .failure(Refusal(.noNotchDisplay))
        }
        return .success(CGPoint(x: display.bounds.midX, y: display.bounds.minY + 10))
    }

    /// Largest rectangle any display-rect capture may have. A plan bigger
    /// than this is refused even if a future edit computed it on purpose.
    public static func maximumRect(on display: DisplayGeometry) -> CGSize {
        let notchWidth = display.notchWidth ?? 0
        return CGSize(width: min(notchWidth + 2 * sidePadding, display.bounds.width),
                      height: min(notchHeight, display.bounds.height))
    }
}

/// What a capture is allowed to contain.
public enum CapturePlan: Equatable, Sendable {
    /// Only the windows of one application (umbar). Other apps' pixels are
    /// not in the image at all, not merely cropped.
    case appWindows(pid: Int32)
    /// A fixed rectangle of the display.
    case displayRect(CGRect)
    /// Exactly one window (the runner-opened test Finder window).
    case window(id: UInt32)
}

public enum CapturePlanner {
    public static func plan(region: RegionName, display: DisplayGeometry, finderDropWindowID: UInt32?) -> Result<CapturePlan, Refusal> {
        if region == .finderDrop {
            guard let id = finderDropWindowID else { return .failure(Refusal(.noFinderDropWindow)) }
            return .success(.window(id: id))
        }
        return Regions.rect(region, on: display).flatMap { rect in
            let plan = CapturePlan.displayRect(rect)
            if let refusal = validate(plan, display: display) { return .failure(refusal) }
            return .success(plan)
        }
    }

    /// The "never full screen" rule as a check, independent of how the plan
    /// was computed.
    public static func validate(_ plan: CapturePlan, display: DisplayGeometry) -> Refusal? {
        guard case .displayRect(let rect) = plan else { return nil }
        let max = Regions.maximumRect(on: display)
        guard !rect.isEmpty, !rect.isNull, !rect.isInfinite else { return Refusal(.regionRejected, "empty") }
        guard display.bounds.contains(rect) else { return Refusal(.regionRejected, "outside-display") }
        guard rect.width <= max.width + 0.5, rect.height <= max.height + 0.5 else {
            return Refusal(.regionRejected, "too-large")
        }
        guard rect.size != display.bounds.size else { return Refusal(.regionRejected, "full-screen") }
        return nil
    }
}

/// System-alert owners whose windows `capture.alert` may include (§3.5).
///
/// Empty in v1 on purpose: the design says the list is filled from the T6
/// measurement on the Air (which processes draw the TCC, Gatekeeper and
/// pasteboard alerts on 27.0.1). Until then `capture.alert` is refused, not
/// approximated with a guess. Adding entries is a reviewed code change.
public enum AlertAllowlist {
    public static let owners: [AlertName: [String]] = [:]

    public static func owners(for name: AlertName) -> Result<[String], Refusal> {
        guard let list = owners[name], !list.isEmpty else { return .failure(Refusal(.alertAllowlistEmpty, name.rawValue)) }
        return .success(list)
    }
}
