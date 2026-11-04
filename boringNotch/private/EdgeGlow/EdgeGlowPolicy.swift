//
//  EdgeGlowPolicy.swift
//  boringNotch
//
//  The edge glow's decisions, apart from SwiftUI: which signal change is an
//  event, which event wins, whether anything glows, and how bright at a
//  given moment. Foundation only, so umbarTests compiles it hostless
//  (membershipExceptions).
//
//  The glow never stands alone: every event it marks already has an ear,
//  a banner or a HUD that says what happened in words or a glyph. It only
//  draws the eye there.
//

import Foundation

/// The user's choice in Settings > Appearance.
enum EdgeGlowStyle: String, CaseIterable, Sendable {
    /// A wide blurred halo.
    case soft
    /// A thin bright outline.
    case neon
    /// Events only: no glow while music plays.
    case pulse

    /// Whether playing music keeps a slow breathing glow.
    var showsAmbient: Bool { self != .pulse }
}

/// What a glow is coloured by. Mapped to a colour by the EdgeGlow modifier.
enum EdgeGlowTint: Equatable, Sendable {
    case album
    case timer
    case eyeBreak
    case camera
    case microphone
    case hud
}

/// A short flash. The raw value is the priority: a higher one is never
/// cut off by a lower one (a volume key must not repaint the camera flash).
enum EdgeGlowEvent: Int, Comparable, CaseIterable, Sendable {
    case hud = 0
    case eyeBreak
    case timerFinished
    case microphone
    case camera

    var tint: EdgeGlowTint {
        switch self {
        case .hud: .hud
        case .eyeBreak: .eyeBreak
        case .timerFinished: .timer
        case .microphone: .microphone
        case .camera: .camera
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// The level signals the glow watches. An event is a false → true edge.
struct EdgeGlowSignals: Equatable, Sendable {
    var timerAlerting = false
    var eyeBreakPrompting = false
    var camera = false
    var microphone = false
    var hudShowing = false

    static let idle = EdgeGlowSignals()
}

enum EdgeGlowTrigger {
    /// The highest-priority signal that turned on between `old` and `new`,
    /// or nil. Signals that stay on (a long call with the camera) or turn
    /// off fire nothing.
    static func event(from old: EdgeGlowSignals, to new: EdgeGlowSignals) -> EdgeGlowEvent? {
        var fired: [EdgeGlowEvent] = []
        if new.camera && !old.camera { fired.append(.camera) }
        if new.microphone && !old.microphone { fired.append(.microphone) }
        if new.timerAlerting && !old.timerAlerting { fired.append(.timerFinished) }
        if new.eyeBreakPrompting && !old.eyeBreakPrompting { fired.append(.eyeBreak) }
        if new.hudShowing && !old.hudShowing { fired.append(.hud) }
        return fired.max()
    }

    /// Whether `new` takes over from the pulse already running (`current`,
    /// nil when none is). Equal priority restarts it.
    static func replaces(_ current: EdgeGlowEvent?, with new: EdgeGlowEvent) -> Bool {
        guard let current else { return true }
        return new >= current
    }
}

/// How the glow moves.
enum EdgeGlowAnimation: Equatable, Sendable {
    /// One frame, no clock (Reduce Motion).
    case steady
    /// Music: a slow continuous rise and fall.
    case breathing
    /// An event: two flashes, then dark.
    case pulse
}

struct EdgeGlowState: Equatable, Sendable {
    var tint: EdgeGlowTint
    var animation: EdgeGlowAnimation
}

struct EdgeGlowContext: Equatable, Sendable {
    var enabled: Bool
    var style: EdgeGlowStyle
    var reduceMotion: Bool
    var isOpen: Bool
    /// The closed island's height; 0 when the island is hidden (fullscreen).
    var islandHeight: Double
    var musicPlaying: Bool
    /// The event whose pulse is running, if any.
    var pulse: EdgeGlowEvent?
}

enum EdgeGlowPolicy {
    /// Two flashes. Long enough to be seen at the edge of vision, short
    /// enough to be over before the user looks up.
    static let pulseDuration: TimeInterval = 1.6
    /// One breath. Slow on purpose: anything faster reads as a notification.
    static let breathPeriod: TimeInterval = 7
    static let breathFloor = 0.45
    /// The second flash is the echo of the first.
    static let secondFlash = 0.6
    /// Reduce Motion: a still, dim glow in place of breathing and flashes.
    static let steadyLevel = 0.35

    /// nil draws nothing.
    ///
    /// Open panel: no glow. The panel is a large black surface the user is
    /// already looking at, and its content says what the glow would; a halo
    /// around it only sits over the work behind it.
    static func state(_ c: EdgeGlowContext) -> EdgeGlowState? {
        guard c.enabled, !c.isOpen, c.islandHeight > 0 else { return nil }
        if let event = c.pulse {
            return EdgeGlowState(tint: event.tint, animation: c.reduceMotion ? .steady : .pulse)
        }
        if c.musicPlaying && c.style.showsAmbient {
            return EdgeGlowState(tint: .album, animation: c.reduceMotion ? .steady : .breathing)
        }
        return nil
    }

    /// 0…1, `elapsed` seconds into a pulse: sin² bumps, the second softer.
    static func pulseLevel(elapsed: TimeInterval) -> Double {
        guard elapsed >= 0, elapsed < pulseDuration else { return 0 }
        let flash = pulseDuration / 2
        let second = elapsed >= flash
        let p = (second ? elapsed - flash : elapsed) / flash
        let bump = sin(Double.pi * p)
        return bump * bump * (second ? secondFlash : 1)
    }

    /// breathFloor…1, continuous over any time value so the breath does
    /// not jump when a pulse hands back to it.
    static func breathLevel(time: TimeInterval) -> Double {
        let phase = time.truncatingRemainder(dividingBy: breathPeriod) / breathPeriod
        let wave = 0.5 - 0.5 * cos(2 * Double.pi * phase)
        return breathFloor + (1 - breathFloor) * wave
    }

    static func level(_ animation: EdgeGlowAnimation, time: TimeInterval, pulseElapsed: TimeInterval) -> Double {
        switch animation {
        case .steady: steadyLevel
        case .breathing: breathLevel(time: time)
        case .pulse: pulseLevel(elapsed: pulseElapsed)
        }
    }

    /// The clock the view needs: nil is none (steady draws once).
    static func frameInterval(_ animation: EdgeGlowAnimation) -> TimeInterval? {
        switch animation {
        case .steady: nil
        // A 7 s breath changes too little per frame to need more than 24 fps.
        case .breathing: 1.0 / 24
        case .pulse: 1.0 / 60
        }
    }

    /// The album's average colour, lifted so a dark cover still glows:
    /// mixed toward white until its luma (Rec. 709 weights on the sRGB values,
    /// as `ensureMinimumBrightness` uses) reaches `minLuminance`.
    /// Hue is kept; a cover that is already bright is returned unchanged.
    static func albumGlow(red: Double, green: Double, blue: Double, minLuminance: Double = 0.45) -> (red: Double, green: Double, blue: Double) {
        let clamp = { (v: Double) in min(1, max(0, v.isFinite ? v : 0)) }
        let r = clamp(red), g = clamp(green), b = clamp(blue)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        guard luminance < minLuminance else { return (r, g, b) }
        let t = (minLuminance - luminance) / (1 - luminance)
        return (r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t)
    }
}

/// What is on screen over time. The policy's state switches; this eases
/// the breath in when it starts and the glow out when it goes, so neither
/// pops. A pulse starts and ends dark on its own and is not eased in.
/// Reduce Motion: no easing at all, the steady glow comes and goes.
struct EdgeGlowEnvelope: Equatable, Sendable {
    static let fade: TimeInterval = 0.4

    /// What is drawn; kept through the fade-out after the policy said nil.
    private(set) var state: EdgeGlowState?
    private(set) var since: Date = .distantPast
    private(set) var releasedAt: Date?

    init() {}

    mutating func update(to new: EdgeGlowState?, now: Date, reduceMotion: Bool) {
        if let new {
            if new != state || releasedAt != nil { since = now }
            state = new
            releasedAt = nil
        } else if state != nil, releasedAt == nil {
            if reduceMotion || state?.animation == .steady {
                state = nil
            } else {
                releasedAt = now
            }
        }
    }

    /// Ends a fade-out that has run its course. The view calls it once the
    /// fade is over, so its clock stops. A millisecond of slack: a sleep of
    /// exactly `fade` must not miss by a rounding error and leave the clock on.
    mutating func settle(now: Date) {
        guard let releasedAt, now.timeIntervalSince(releasedAt) >= Self.fade - 0.001 else { return }
        state = nil
        self.releasedAt = nil
    }

    /// 0…1 at `now`; `pulseElapsed` is the time since the running pulse began.
    func level(at now: Date, pulseElapsed: TimeInterval) -> Double {
        guard let state else { return 0 }
        var level = EdgeGlowPolicy.level(state.animation, time: now.timeIntervalSinceReferenceDate, pulseElapsed: pulseElapsed)
        if state.animation == .breathing { level *= Self.ease(now.timeIntervalSince(since)) }
        if let releasedAt { level *= 1 - Self.ease(now.timeIntervalSince(releasedAt)) }
        return level
    }

    /// Seconds between frames while something moves; nil when nothing
    /// does and one frame is enough.
    /// A steady glow is never faded, so it never needs one.
    var frameInterval: TimeInterval? {
        state.flatMap { EdgeGlowPolicy.frameInterval($0.animation) }
    }

    /// Smoothstep over `fade`: 0 at the start, 1 once it is over.
    static func ease(_ t: TimeInterval) -> Double {
        let x = min(1, max(0, t / fade))
        return x * x * (3 - 2 * x)
    }
}
