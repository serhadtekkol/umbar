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

/// What the music glow is coloured by (Settings). Events keep their own colours.
enum EdgeGlowColorMode: String, CaseIterable, Sendable {
    /// The cover's average colour, lifted (`albumGlow`).
    case album
    /// One colour the user picked.
    case fixed
    /// A slow walk round the hue circle at even perceived brightness.
    case cycle
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
    /// Music, audio-reactive: brightness follows the loudness. No clock of
    /// its own; each audio sample draws a frame.
    case audio
    /// An event: two flashes, then dark.
    case pulse
}

struct EdgeGlowState: Equatable, Sendable {
    var tint: EdgeGlowTint
    var animation: EdgeGlowAnimation
}

extension EdgeGlowAnimation {
    /// The music glow, either way it moves.
    var isAmbient: Bool { self == .breathing || self == .audio }
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
    /// The "React to sound" setting.
    var audioReactive = false
    /// Audio levels are arriving and not silent (EdgeGlowAudioFollower.isLive).
    /// False with no permission or no capture yet: the glow breathes instead.
    var audioLive = false
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
            let moving: EdgeGlowAnimation = c.audioReactive && c.audioLive ? .audio : .breathing
            return EdgeGlowState(tint: .album, animation: c.reduceMotion ? .steady : moving)
        }
        return nil
    }

    /// Whether the audio level capture should run. Only for a glow that
    /// could use it: on, reacting to sound, a style that glows for music,
    /// music playing, motion allowed. Not tied to the panel or the island's
    /// height: every screen's island asks with the same answer, and an
    /// open panel would start and stop the capture on every hover.
    static func capturesAudio(_ c: EdgeGlowContext) -> Bool {
        c.enabled && c.audioReactive && c.style.showsAmbient && c.musicPlaying && !c.reduceMotion
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

    /// `audio` is EdgeGlowAudioFollower.brightness, used by `.audio` only.
    static func level(_ animation: EdgeGlowAnimation, time: TimeInterval, pulseElapsed: TimeInterval, audio: Double = 0) -> Double {
        switch animation {
        case .steady: steadyLevel
        case .breathing: breathLevel(time: time)
        case .audio: min(1, max(0, audio))
        case .pulse: pulseLevel(elapsed: pulseElapsed)
        }
    }

    /// The clock the view needs: nil is none (steady draws once).
    static func frameInterval(_ animation: EdgeGlowAnimation) -> TimeInterval? {
        switch animation {
        case .steady: nil
        // A 7 s breath changes too little per frame to need more than 24 fps.
        case .breathing: 1.0 / 24
        // The audio samples draw it (~30 Hz); a clock too would double the work.
        case .audio: nil
        case .pulse: 1.0 / 60
        }
    }

    /// Fading the audio glow out: the capture stops with the music, so
    /// there are no samples left to draw it and it needs a clock after all.
    static let audioFadeInterval: TimeInterval = 1.0 / 30

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
/// the music glow in when it starts and the glow out when it goes, so
/// neither pops. A pulse starts and ends dark on its own and is not eased in.
/// Breath and audio hand over to each other with a crossfade from the level
/// on screen, not a dip to dark: the capture starting (or the sound going
/// quiet) is not the music starting.
/// Reduce Motion: no easing at all, the steady glow comes and goes.
struct EdgeGlowEnvelope: Equatable, Sendable {
    static let fade: TimeInterval = 0.4

    /// What is drawn; kept through the fade-out after the policy said nil.
    private(set) var state: EdgeGlowState?
    private(set) var since: Date = .distantPast
    private(set) var releasedAt: Date?
    /// A breath ⇄ audio handover in progress: when, and the level it left.
    private(set) var handoffAt: Date?
    private(set) var handoffFrom = 0.0

    init() {}

    /// `audio` is the current audio brightness, so a handover away from the
    /// audio glow starts from what is on screen.
    mutating func update(to new: EdgeGlowState?, now: Date, reduceMotion: Bool, audio: Double = 0) {
        if let new {
            if let old = state, releasedAt == nil, old.tint == new.tint,
               old.animation.isAmbient, new.animation.isAmbient {
                if old.animation != new.animation {
                    handoffFrom = level(at: now, pulseElapsed: 0, audio: audio)
                    handoffAt = now
                }
            } else if new != state || releasedAt != nil {
                since = now
                handoffAt = nil
            }
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

    /// 0…1 at `now`; `pulseElapsed` is the time since the running pulse
    /// began, `audio` the audio brightness.
    func level(at now: Date, pulseElapsed: TimeInterval, audio: Double = 0) -> Double {
        guard let state else { return 0 }
        var level = EdgeGlowPolicy.level(state.animation, time: now.timeIntervalSinceReferenceDate,
                                         pulseElapsed: pulseElapsed, audio: audio)
        if state.animation.isAmbient { level *= Self.ease(now.timeIntervalSince(since)) }
        if let handoffAt {
            let k = Self.ease(now.timeIntervalSince(handoffAt))
            level = handoffFrom + (level - handoffFrom) * k
        }
        if let releasedAt { level *= 1 - Self.ease(now.timeIntervalSince(releasedAt)) }
        return level
    }

    /// Seconds between frames while something moves; nil when nothing
    /// does and one frame is enough (or, for the audio glow, when its
    /// samples draw the frames).
    /// A steady glow is never faded, so it never needs one.
    var frameInterval: TimeInterval? {
        guard let state else { return nil }
        if state.animation == .audio, releasedAt != nil { return EdgeGlowPolicy.audioFadeInterval }
        return EdgeGlowPolicy.frameInterval(state.animation)
    }

    /// Smoothstep over `fade`: 0 at the start, 1 once it is over.
    static func ease(_ t: TimeInterval) -> Double {
        let x = min(1, max(0, t / fade))
        return x * x * (3 - 2 * x)
    }
}

// MARK: - Audio

/// Turns the audio monitor's smoothed levels into what the glow does with
/// them. The monitor already smooths; this only shapes.
///
///   brightness  the loudness, gently compressed (quiet passages still
///               move) over a floor, so a quiet bar dims but never goes dark
///   punch       a bass onset: bass rising above its own slow average. Jumps
///               up on the hit and decays in ~0.2 s, widening the glow a
///               little; a steady bass line settles back to no punch
///   sparkle     the treble, lifting the colour toward white
struct EdgeGlowAudioFollower: Equatable, Sendable {
    static let floor = 0.25
    /// Under 1 lifts quiet passages so they still move; a square root
    /// (0.5) flattened the range too far to see the music in it.
    static let loudnessCurve = 0.7
    /// Below this the sound counts as silent.
    static let silence = 0.02
    /// Silence this long hands the glow back to the breath (a track gap,
    /// a quiet intro, or a capture that delivers only zeros).
    static let silenceHold: TimeInterval = 1.5
    /// Bass above its average by this much is a hit.
    static let onsetThreshold = 0.06
    static let punchGain = 3.0
    static let punchDecay: TimeInterval = 0.18
    static let averageTime: TimeInterval = 0.6
    /// The widest a hit spreads the glow: radii × (1 + this).
    static let maxSpread = 0.6
    /// The most a hit adds to the brightness.
    static let punchBrightness = 0.2
    static let maxSparkle = 0.3
    /// A gap longer than this is not a frame interval (first sample, the
    /// capture restarting); it is treated as one frame.
    static let maxStep: TimeInterval = 0.1

    private(set) var level = 0.0
    private(set) var bassAverage = 0.0
    private(set) var punch = 0.0
    private(set) var treble = 0.0
    private(set) var lastSample: Date?
    private(set) var lastAudible: Date?

    init() {}

    mutating func feed(level: Double, bass: Double, treble: Double, now: Date) {
        let clamp = { (v: Double) in min(1, max(0, v.isFinite ? v : 0)) }
        let level = clamp(level), bass = clamp(bass)
        var dt = lastSample.map { now.timeIntervalSince($0) } ?? Self.maxStep
        if dt <= 0 || dt > Self.maxStep { dt = Self.maxStep }
        lastSample = now

        punch *= exp(-dt / Self.punchDecay)
        let onset = bass - bassAverage
        if onset > Self.onsetThreshold { punch = max(punch, min(1, onset * Self.punchGain)) }
        bassAverage += (bass - bassAverage) * (1 - exp(-dt / Self.averageTime))

        self.level = level
        self.treble = clamp(treble)
        if level > Self.silence { lastAudible = now }
    }

    /// 0…1, for EdgeGlowEnvelope.level.
    var brightness: Double {
        min(1, Self.floor + (1 - Self.floor) * pow(level, Self.loudnessCurve) + Self.punchBrightness * punch)
    }

    /// Multiplies the glow's radii: 1…1 + maxSpread.
    var spread: Double { 1 + Self.maxSpread * punch }

    /// 0…maxSparkle, for EdgeGlowColor.sparkle.
    var sparkle: Double { Self.maxSparkle * treble }

    /// Sound has been heard within `silenceHold`.
    func isLive(now: Date) -> Bool {
        guard let lastAudible else { return false }
        return now.timeIntervalSince(lastAudible) < Self.silenceHold
    }
}

// MARK: - Colour

/// sRGB, 0…1 each.
struct EdgeGlowRGB: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
}

enum EdgeGlowColor {
    /// One trip round the hue circle. Slow so it reads as a mood, not a
    /// signal; it never passes through an event colour fast enough to be
    /// mistaken for one.
    static let cyclePeriod: TimeInterval = 30
    /// OKLCH lightness and chroma of the cycle: every hue at the same
    /// perceived brightness (an HSL wheel would flash at yellow and sink
    /// at blue), bright enough to glow on a dark menu bar like a lifted cover.
    static let cycleLightness = 0.78
    static let cycleChroma = 0.14

    /// "#RRGGBB" or "RRGGBB", any case; nil otherwise.
    static func rgb(hex: String) -> EdgeGlowRGB? {
        var digits = Substring(hex.trimmingCharacters(in: .whitespaces))
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        // UInt32(radix:) alone would take a sign ("+12345").
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        return EdgeGlowRGB(red: Double((value >> 16) & 0xFF) / 255,
                           green: Double((value >> 8) & 0xFF) / 255,
                           blue: Double(value & 0xFF) / 255)
    }

    /// "#RRGGBB", clamped.
    static func hex(_ c: EdgeGlowRGB) -> String {
        let byte = { (v: Double) in Int((min(1, max(0, v.isFinite ? v : 0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.red), byte(c.green), byte(c.blue))
    }

    /// The cycle's colour `time` seconds in; continuous, period `cyclePeriod`.
    static func cycle(time: TimeInterval) -> EdgeGlowRGB {
        var phase = time.truncatingRemainder(dividingBy: cyclePeriod) / cyclePeriod
        if phase < 0 { phase += 1 }
        return oklch(lightness: cycleLightness, chroma: cycleChroma, hue: 360 * phase)
    }

    /// OKLCH → sRGB. A colour outside sRGB keeps its lightness and hue and
    /// loses chroma until it fits, rather than being clipped per channel
    /// (which shifts the hue).
    static func oklch(lightness: Double, chroma: Double, hue: Double) -> EdgeGlowRGB {
        if let rgb = srgb(lightness, chroma, hue) { return rgb }
        var lo = 0.0, hi = chroma
        for _ in 0..<20 {
            let mid = (lo + hi) / 2
            if srgb(lightness, mid, hue) != nil { lo = mid } else { hi = mid }
        }
        return srgb(lightness, lo, hue) ?? EdgeGlowRGB(red: lightness, green: lightness, blue: lightness)
    }

    /// The treble's lift: mixed toward white by `amount` (0…1).
    static func sparkle(_ c: EdgeGlowRGB, amount: Double) -> EdgeGlowRGB {
        let t = min(1, max(0, amount.isFinite ? amount : 0))
        return EdgeGlowRGB(red: c.red + (1 - c.red) * t,
                           green: c.green + (1 - c.green) * t,
                           blue: c.blue + (1 - c.blue) * t)
    }

    /// nil when out of gamut. Björn Ottosson's OKLab matrices.
    private static func srgb(_ L: Double, _ C: Double, _ h: Double) -> EdgeGlowRGB? {
        let rad = h * Double.pi / 180
        let a = C * cos(rad), b = C * sin(rad)
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        let linear = [
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
        ]
        let eps = 1e-6
        guard linear.allSatisfy({ $0 >= -eps && $0 <= 1 + eps }) else { return nil }
        let gamma = { (v: Double) -> Double in
            let v = min(1, max(0, v))
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }
        return EdgeGlowRGB(red: gamma(linear[0]), green: gamma(linear[1]), blue: gamma(linear[2]))
    }
}
