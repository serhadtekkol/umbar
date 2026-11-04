//
//  ScreenEdgeGlowPolicy.swift
//  boringNotch
//
//  The screen edge glow's decisions, apart from AppKit and SwiftUI: whether
//  it draws, whether its window shows, how far from the notch the light
//  has run and where the glint is. Foundation only, so umbarTests compiles
//  it hostless (membershipExceptions), beside EdgeGlowPolicy whose state
//  and colours it shares.
//
//  The picture: light leaves the notch on both sides and runs a short
//  way along the top edge, fading out toward its ends. It never reaches
//  the corners, the sides or the bottom. While music plays a glint keeps
//  travelling outward; an event sends one sweep. Positions along a band
//  are fractions of it, 0 at the notch's edge and 1 at the band's far
//  end; the two sides mirror.
//

import Foundation

enum ScreenEdgeGlowPolicy {
    /// The light running out from the notch when the music glow starts.
    static let revealDuration: TimeInterval = 0.9
    /// One glint, notch to the band's end. Half a breath, so the two never beat.
    static let glintPeriod: TimeInterval = EdgeGlowPolicy.breathPeriod / 2
    /// The glint's length, as a fraction of the band.
    static let glintLength = 0.3
    /// The most the bands ever draw: a soft glow gains nothing from more.
    static let maxFrameRate = 30.0
    /// Settings: the band's width on screen, in points.
    static let thicknessRange: ClosedRange<Double> = 2...12
    static let intensityRange: ClosedRange<Double> = 0.3...1
    /// Settings: how far each band runs out from the notch's edge, in
    /// notch widths. 1.25 is the default (between 1 and 1.5).
    static let spreadRange: ClosedRange<Double> = 0.5...2.5
    /// The band always stops this far short of the screen's corner.
    static let cornerMargin: CGFloat = 24
    /// A display without a notch: the closed island's width stands in.
    static let fallbackNotchWidth: CGFloat = 185

    /// How tall the panel is: the band and the light it throws down, at
    /// the thickest setting and a bass hit's widest spread.
    static let panelHeight: CGFloat = 120

    /// The panel: a strip along the top of the screen (AppKit coordinates),
    /// not the whole screen, so the window server composites only that.
    static func panelFrame(screen: CGRect) -> CGRect {
        let height = min(panelHeight, screen.height)
        return CGRect(x: screen.minX, y: screen.maxY - height, width: screen.width, height: height)
    }

    /// The length of one side's band, in points: `spread` notch widths,
    /// cut short so it stops `cornerMargin` before the corner.
    static func bandLength(screenWidth: CGFloat, notchWidth: CGFloat, spread: Double) -> CGFloat {
        let notch = notchWidth > 0 ? notchWidth : fallbackNotchWidth
        let room = max(0, (screenWidth - notch) / 2 - cornerMargin)
        let wanted = notch * CGFloat(min(max(spread.isFinite ? spread : 1, spreadRange.lowerBound), spreadRange.upperBound))
        return min(wanted, room)
    }

    /// What the rim draws, nil for nothing. The same state as the notch's
    /// glow, with two differences: an open panel does not put it out (the
    /// panel covers the notch, not the edges), and the island's height is
    /// not asked (a fullscreen app is checked per screen, `isFullscreen`).
    static func state(_ c: EdgeGlowContext, screenEdgeEnabled: Bool) -> EdgeGlowState? {
        guard screenEdgeEnabled else { return nil }
        var c = c
        c.isOpen = false
        c.islandHeight = 1
        return EdgeGlowPolicy.state(c)
    }

    /// A screen's window is on screen only while something is drawn and no
    /// fullscreen app owns that screen. Idle, every window is ordered out.
    static func showsWindow(drawing: Bool, fullscreen: Bool) -> Bool {
        drawing && !fullscreen
    }

    /// The envelope's clock, capped at `maxFrameRate`; nil stays nil (a
    /// steady rim draws once, the audio rim is drawn by its samples).
    static func frameInterval(_ interval: TimeInterval?) -> TimeInterval? {
        interval.map { max($0, 1 / maxFrameRate) }
    }

    /// How far the light has run from the notch, 0…1 of the band.
    /// `elapsed` is the time since the glow (or the pulse) began.
    /// An event sweeps out during its first flash, so the echo lights the
    /// whole rim. Steady (Reduce Motion) is the whole rim at once.
    static func reach(_ animation: EdgeGlowAnimation, elapsed: TimeInterval) -> Double {
        switch animation {
        case .steady: 1
        case .pulse: easeOut(elapsed / (EdgeGlowPolicy.pulseDuration / 2))
        case .breathing, .audio: easeOut(elapsed / revealDuration)
        }
    }

    /// The travelling highlight: where its centre is
    /// and how strong it is (0…1), or nil for none. Its centre is 0…1 of the band.
    ///   pulse     the head of the sweep, fading as it arrives
    ///   ambient   a glint every `glintPeriod`, born at the notch and gone
    ///             by the band's end; it does not run ahead of the reveal
    ///   steady    none: Reduce Motion
    static func glint(_ animation: EdgeGlowAnimation, time: TimeInterval, elapsed: TimeInterval) -> (position: Double, strength: Double)? {
        switch animation {
        case .steady:
            return nil
        case .pulse:
            let head = reach(.pulse, elapsed: elapsed)
            guard head < 1 else { return nil }
            return (head, 1 - head)
        case .breathing, .audio:
            var phase = time.truncatingRemainder(dividingBy: glintPeriod) / glintPeriod
            if phase < 0 { phase += 1 }
            let position = min(phase, reach(animation, elapsed: elapsed))
            return (position, sin(Double.pi * phase))
        }
    }

    /// Cubic ease-out over 0…1, clamped.
    static func easeOut(_ t: Double) -> Double {
        let x = min(1, max(0, t.isFinite ? t : 1))
        let inv = 1 - x
        return 1 - inv * inv * inv
    }

    // MARK: Fullscreen

    /// One on-screen window, as CGWindowListCopyWindowInfo reports it.
    struct WindowInfo: Equatable, Sendable {
        /// Global display coordinates: origin at the top left of the main screen.
        var bounds: CGRect
        var layer: Int
        var ownerPID: Int32
        var alpha: Double = 1
    }

    /// Whether another app's window covers the whole screen: a fullscreen
    /// app (its own Space, menu bar gone) or a borderless fullscreen game.
    /// A zoomed window stops at the menu bar and does not count; only
    /// ordinary windows (layer 0) are looked at, so the desktop, the Dock
    /// and the menu bar never do. `screen` is in the same coordinates.
    static func isFullscreen(screen: CGRect, windows: [WindowInfo], ownPID: Int32, tolerance: CGFloat = 1) -> Bool {
        windows.contains { w in
            w.layer == 0 && w.ownerPID != ownPID && w.alpha > 0
                && abs(w.bounds.minX - screen.minX) <= tolerance
                && abs(w.bounds.minY - screen.minY) <= tolerance
                && w.bounds.width >= screen.width - tolerance
                && w.bounds.height >= screen.height - tolerance
        }
    }

    /// An AppKit screen frame (origin bottom left of the main screen, y up)
    /// in global display coordinates (origin top left, y down).
    static func displayRect(fromAppKit frame: CGRect, mainScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: mainScreenHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}
