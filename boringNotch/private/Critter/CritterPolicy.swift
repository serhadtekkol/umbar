//
//  CritterPolicy.swift
//  boringNotch
//
//  The idle critter's decisions, apart from SwiftUI: when one may cross
//  the closed island, how long to wait for the next, which one comes, and
//  the path it takes. Foundation and CoreGraphics only, so umbarTests
//  compiles it hostless (membershipExceptions).
//
//  The crossing: crumbs appear in a row under the island, the critter comes
//  in from one side eating them, dives up into the island's corner, runs
//  through it out of sight (the black island hides it, and the hardware
//  notch would anyway), drops out of the far corner and eats the rest.
//  Purely decorative; it never says anything the user has to read.
//

import CoreGraphics
import Foundation

/// How often a critter crosses (Settings > Appearance).
enum CritterFrequency: String, CaseIterable, Sendable {
    case rarely
    case sometimes
    case often

    /// The mean wait between crossings, before jitter.
    var meanInterval: TimeInterval {
        switch self {
        case .rarely: 15 * 60
        case .sometimes: 5 * 60
        case .often: 60
        }
    }
}

/// The characters. Each is drawn by CritterSprites.
enum CritterKind: String, CaseIterable, Sendable {
    /// A side-on pixel beetle with a mint shell and walking legs.
    case beetle
    /// A lime caterpillar that grows a segment for every crumb.
    case caterpillar
    /// A four-point star with a fading violet tail.
    case comet
}

/// The user's pick: one character, or a different one each time.
enum CritterChoice: String, CaseIterable, Sendable {
    case mixed
    case beetle
    case caterpillar
    case comet

    /// `unit` is a random number in 0..<1; it only matters for `.mixed`.
    func kind(unit: Double) -> CritterKind {
        switch self {
        case .beetle: return .beetle
        case .caterpillar: return .caterpillar
        case .comet: return .comet
        case .mixed:
            let all = CritterKind.allCases
            let index = min(all.count - 1, max(0, Int(unit * Double(all.count))))
            return all[index]
        }
    }
}

/// Everything that decides whether a critter may be on screen right now.
/// The default is the quiet state in which one may.
struct CritterConditions: Equatable, Sendable {
    var enabled = true
    var reduceMotion = false
    var notchClosed = true
    /// Full screen hides the island (`hideOnClosed`), or it has no height.
    var islandHidden = false
    /// Music is playing, or paused with its ears still out.
    var musicActive = false
    var allowWhileMusic = false
    /// A sneak peek, HUD or expanding view (battery, music) is up.
    var transientShowing = false
    var liveStripShown = false
    var eyeBreakBannerShown = false
    /// On the island or close enough that the island is leaning toward it.
    var pointerNear = false
    /// Locked, asleep, displays asleep, or another user's session.
    var userAway = false
    var helloAnimationRunning = false
}

enum CritterPolicy {
    /// A wait of `meanInterval` × 0.65…1.35, so crossings never fall into
    /// a beat the user can predict.
    static let jitter: ClosedRange<Double> = 0.65...1.35

    /// After the island goes quiet, a due critter waits this long, so it does
    /// not chase the music ears or a HUD out of the island.
    static let settleDelay: TimeInterval = 1.5

    static func mayAppear(_ c: CritterConditions) -> Bool {
        guard c.enabled, !c.reduceMotion else { return false }
        guard c.notchClosed, !c.islandHidden, !c.helloAnimationRunning else { return false }
        guard !c.userAway, !c.pointerNear else { return false }
        guard !c.transientShowing, !c.liveStripShown, !c.eyeBreakBannerShown else { return false }
        if c.musicActive && !c.allowWhileMusic { return false }
        return true
    }

    /// Whether to wait for crossings at all. Reduce Motion and the switch
    /// stop the clock, not just the drawing, so nothing runs while off.
    static func schedules(enabled: Bool, reduceMotion: Bool) -> Bool {
        enabled && !reduceMotion
    }

    /// The wait before the next crossing. `unit` is a random number in 0...1.
    static func nextDelay(_ frequency: CritterFrequency, unit: Double) -> TimeInterval {
        let u = min(1, max(0, unit))
        let factor = jitter.lowerBound + (jitter.upperBound - jitter.lowerBound) * u
        return frequency.meanInterval * factor
    }
}

/// Which way a critter walks.
enum CritterDirection: Sendable {
    case leftToRight
    case rightToLeft

    var sign: CGFloat { self == .leftToRight ? 1 : -1 }
}

/// Where a critter is and which way it faces, in the layer's space:
/// x from the island's centre, y down from the island's top.
struct CritterPose: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    /// Radians from the walking direction; negative points up, into the island.
    var pitch: CGFloat
    /// 0…1, the fade at the ends of the walk.
    var opacity: Double
}

/// One crumb on the lane, and the moment (seconds into the run) the
/// critter's head reaches it.
struct CritterCrumb: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var eatenAt: TimeInterval
}

/// The whole crossing for one island size.
struct CritterPath: Sendable {
    /// Crumbs pop in for this long before the critter arrives.
    static let leadIn: TimeInterval = 0.4
    /// The critter's walk, end to end.
    static let travel: TimeInterval = 4.0
    /// How far beyond the island the lane runs on each side, at most.
    static let preferredReach: CGFloat = 110
    /// Shorter than this and the walk is not worth having.
    static let minimumReach: CGFloat = 48
    /// The lane's centre below the island's bottom edge.
    static let laneDrop: CGFloat = 7
    /// The tunnel's centre above it: deep enough to hide a 10 pt sprite.
    static let tunnelRise: CGFloat = 8
    /// Sprites are at most this far from their centre (for the hide test).
    static let spriteHalfHeight: CGFloat = 5
    /// The dive starts this far outside the island's edge…
    static let diveOutside: CGFloat = 8
    /// …and is in the tunnel this far inside it, past the corner's radius.
    static let diveInside: CGFloat = 22
    /// Out of sight it hurries: through the tunnel at this times walking speed.
    static let tunnelSpeed: CGFloat = 3
    static let crumbSpacing: CGFloat = 13
    /// Fade in and out over this long at the ends of the walk.
    static let fade: TimeInterval = 0.25

    let islandWidth: CGFloat
    let islandHeight: CGFloat
    let direction: CritterDirection
    let reach: CGFloat
    let crumbs: [CritterCrumb]

    private let segments: [Segment]

    /// The layer's width: the lane and a sprite's room at each end.
    var span: CGFloat { islandWidth + 2 * (reach + 12) }
    var duration: TimeInterval { Self.leadIn + Self.travel }
    var laneY: CGFloat { islandHeight + Self.laneDrop }
    var tunnelY: CGFloat { islandHeight - Self.tunnelRise }

    /// Nil when the window (`maxSpan` wide) leaves no room beside the island,
    /// or the island has no height to tunnel through.
    init?(islandWidth: CGFloat, islandHeight: CGFloat, maxSpan: CGFloat, direction: CritterDirection) {
        guard islandHeight > Self.tunnelRise + Self.spriteHalfHeight else { return nil }
        let reach = min(Self.preferredReach, (maxSpan - islandWidth) / 2 - 12)
        guard reach >= Self.minimumReach else { return nil }
        self.islandWidth = islandWidth
        self.islandHeight = islandHeight
        self.direction = direction
        self.reach = reach

        let half = islandWidth / 2
        let lane = islandHeight + Self.laneDrop
        let tunnel = islandHeight - Self.tunnelRise
        // Walking left to right; mirrored for the other way.
        let start = -(half + reach)
        let diveStart = -half - Self.diveOutside
        let diveEnd = -half + Self.diveInside
        let plan: [(x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat, speed: CGFloat)] = [
            (start, diveStart, lane, lane, 1),
            (diveStart, diveEnd, lane, tunnel, 1),
            (diveEnd, -diveEnd, tunnel, tunnel, Self.tunnelSpeed),
            (-diveEnd, -diveStart, tunnel, lane, 1),
            (-diveStart, -start, lane, lane, 1),
        ]
        let weights = plan.map { Double(($0.x1 - $0.x0) / $0.speed) }
        let total = weights.reduce(0, +)
        var t = Self.leadIn
        var built: [Segment] = []
        for (step, weight) in zip(plan, weights) {
            let length = Self.travel * weight / total
            built.append(Segment(t0: t, t1: t + length, x0: step.x0, x1: step.x1, y0: step.y0, y1: step.y1))
            t += length
        }
        segments = built

        var crumbs: [CritterCrumb] = []
        // The far ends stay clear: the critter fades in and out there.
        for (walk, inset) in [(built[0], (in: CGFloat(18), out: CGFloat(6))), (built[4], (in: 6, out: 18))] {
            let first = walk.x0 + inset.in
            let last = walk.x1 - inset.out
            var x = first
            while x <= last {
                crumbs.append(CritterCrumb(x: x * direction.sign, y: lane + 1.5, eatenAt: walk.time(atX: x)))
                x += Self.crumbSpacing
            }
        }
        self.crumbs = crumbs.sorted { $0.eatenAt < $1.eatenAt }
    }

    /// Where the critter is `elapsed` seconds into the run. Before the lead-in
    /// ends and after the walk it is at the lane's end, faded out.
    func pose(at elapsed: TimeInterval) -> CritterPose {
        let walkStart = Self.leadIn
        let walkEnd = Self.leadIn + Self.travel
        let t = min(max(elapsed, walkStart), walkEnd)
        let segment = segments.first { t <= $0.t1 } ?? segments[segments.count - 1]
        let raw = segment.t1 > segment.t0 ? (t - segment.t0) / (segment.t1 - segment.t0) : 1
        let p = CGFloat(raw)
        let x = segment.x0 + (segment.x1 - segment.x0) * p
        // Smoothstep for the dives, so the critter curves in and out.
        let s = p * p * (3 - 2 * p)
        let y = segment.y0 + (segment.y1 - segment.y0) * s
        let slope = (segment.y1 - segment.y0) * 6 * p * (1 - p) / max(1, segment.x1 - segment.x0)
        let pitch = atan(slope)

        let fadeIn = (elapsed - walkStart) / Self.fade
        let fadeOut = (walkEnd - elapsed) / Self.fade
        let opacity = min(1, max(0, min(fadeIn, fadeOut)))
        return CritterPose(x: x * direction.sign, y: y, pitch: pitch, opacity: opacity)
    }

    /// Whether the sprite is wholly inside the island (and so hidden by it).
    func isHidden(_ pose: CritterPose) -> Bool {
        let inside = abs(pose.x) <= islandWidth / 2 - Self.diveInside + 0.5
        return inside && pose.y + Self.spriteHalfHeight <= islandHeight
    }

    /// Crumbs eaten by `elapsed`.
    func eatenCount(at elapsed: TimeInterval) -> Int {
        crumbs.reduce(0) { $0 + ($1.eatenAt <= elapsed ? 1 : 0) }
    }

    private struct Segment: Sendable {
        let t0: TimeInterval, t1: TimeInterval
        let x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat

        func time(atX x: CGFloat) -> TimeInterval {
            t0 + (t1 - t0) * Double((x - x0) / (x1 - x0))
        }
    }
}
