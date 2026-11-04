//
//  NotchDripPolicy.swift
//  boringNotch
//
//  The liquid drip under the closed island: how hard the pointer pulls on
//  it and where along the edge (NotchDripPolicy), and the drip itself as a
//  small spring simulation (NotchDripSim) that stretches toward the
//  pointer, follows it sideways, and either draws back or pinches off and
//  falls when the pointer leaves, leaving a ripple on the edge.
//
//  Everything here is plain numbers, stepped by the caller: DripLayer runs
//  `step` only while `isAtRest` is false, so a still pointer costs nothing.
//  Foundation/CoreGraphics only, so umbarTests can compile it without AppKit.
//

import CoreGraphics
import Foundation

/// The pointer's pull on the drip: `pull` 0...1 (1 = full length), `x`
/// 0...1 across the island, already clamped to where a drip may hang.
struct NotchDripReading: Equatable {
    var pull: CGFloat
    var x: CGFloat
}

/// The drip's tuning. The app's values are UmbarMotion.drip; tests build
/// their own so they do not move when the look is retuned.
struct NotchDripTuning: Equatable {
    /// The pointer starts pulling `reach` points below the island and pulls
    /// fully from `near` points (and on the island itself).
    var reach: CGFloat
    var near: CGFloat
    /// No drip closer than this to the island's sides: the flat part of the
    /// bottom edge, past the bottom corner radius (and the hint's extra).
    var inset: CGFloat
    /// Length: a spring toward the pull, a little bouncy on the way out and
    /// near-critical on the way back.
    var stretchResponse: Double
    var stretchDamping: Double
    var retractResponse: Double
    var retractDamping: Double
    /// The root sliding along the edge after the pointer.
    var followResponse: Double
    var followDamping: Double
    /// A drip at least `detachLength` long whose pull falls `detachGap`
    /// below it in one go (the pointer flicked away) pinches off.
    var detachLength: CGFloat
    var detachGap: CGFloat
    /// After a pinch the stub snaps back at `recoil` times its length per
    /// second, so the neck is seen thinning for a frame or two before the
    /// drop is free, and does not regrow for `refractory` seconds.
    var recoil: CGFloat
    var refractory: Double
    /// A falling drop: start speed and gravity in drip lengths per second
    /// (squared); gone once `fall` lengths below the edge.
    var dropSpeed: CGFloat
    var gravity: CGFloat
    var fall: CGFloat
    /// The ring on the edge where a drop let go.
    var rippleLife: Double
    var maxDrops: Int
}

enum NotchDripPolicy {
    /// The pull of a pointer at `pointer` on a drip under `island`, or nil
    /// when it pulls nothing. Only from below or on the island, and only
    /// over its flat bottom edge, fading out over `inset` past either end.
    /// `island` and `pointer` share AppKit screen space (y up).
    static func reading(island: CGRect, pointer: CGPoint, tuning: NotchDripTuning) -> NotchDripReading? {
        let inset = tuning.inset
        guard !island.isNull, !island.isEmpty, island.width > 2 * inset,
              tuning.reach > tuning.near, tuning.near >= 0 else { return nil }
        guard pointer.y <= island.maxY else { return nil }
        let below = island.minY - pointer.y
        guard below < tuning.reach else { return nil }
        let vertical = below <= tuning.near ? 1 : 1 - (below - tuning.near) / (tuning.reach - tuning.near)
        let left = island.minX + inset
        let right = island.maxX - inset
        let beyond = max(left - pointer.x, 0, pointer.x - right)
        let horizontal = 1 - beyond / (2 * inset)
        let pull = min(max(vertical * horizontal, 0), 1)
        guard pull > 0 else { return nil }
        let x = (min(max(pointer.x, left), right) - island.minX) / island.width
        return NotchDripReading(pull: pull, x: x)
    }
}

/// One drip and what it has shed. Lengths are in drip lengths (1 = the
/// full drip, UmbarMotion.drip.maxLength points); `x` is 0...1 across the
/// island like NotchDripReading's.
struct NotchDripSim: Equatable {
    struct Drop: Equatable {
        var x: CGFloat
        /// Below the edge, in drip lengths, and speed downward.
        var y: CGFloat
        var vy: CGFloat
        /// The drip's length when it let go: its size.
        var size: CGFloat
    }

    struct Ripple: Equatable {
        var x: CGFloat
        var age: Double
        var size: CGFloat
    }

    var length: CGFloat = 0
    var lengthVelocity: CGFloat = 0
    var x: CGFloat = 0.5
    var xVelocity: CGFloat = 0
    var drops: [Drop] = []
    var ripples: [Ripple] = []
    /// Seconds until the stub may regrow after a pinch.
    var refractory: Double = 0
    /// A fresh drip starts under the pointer instead of sliding in from
    /// the middle.
    var placed = false

    private static let restLength: CGFloat = 0.004
    private static let restSpeed: CGFloat = 0.02
    private static let restX: CGFloat = 0.0008
    static let rippleDelay: Double = 0.05

    /// Advances the drip by `dt` seconds toward `target` (nil: the pointer
    /// pulls nothing).
    mutating func step(dt: Double, target: NotchDripReading?, tuning: NotchDripTuning) {
        guard dt > 0 else { return }
        refractory = max(0, refractory - dt)
        let pull = refractory > 0 ? 0 : (target?.pull ?? 0)

        if let target, !placed || length < Self.restLength {
            x = target.x
            xVelocity = 0
            placed = true
        }

        // Pinch: the pull dropped well below a long drip in one move.
        if length >= tuning.detachLength, length - pull >= tuning.detachGap, refractory == 0 {
            pinch(tuning: tuning)
        }

        let growing = pull >= length
        Self.spring(&length, &lengthVelocity, to: pull, dt: dt,
                    response: growing ? tuning.stretchResponse : tuning.retractResponse,
                    damping: growing ? tuning.stretchDamping : tuning.retractDamping)
        // Never above the edge: the recoil bounces off it rather than through.
        if length < 0 { length = 0; lengthVelocity = max(lengthVelocity, 0) }

        if let target {
            Self.spring(&x, &xVelocity, to: target.x, dt: dt,
                        response: tuning.followResponse, damping: tuning.followDamping)
        }

        for i in drops.indices {
            drops[i].vy += tuning.gravity * CGFloat(dt)
            drops[i].y += drops[i].vy * CGFloat(dt)
        }
        drops.removeAll { $0.y >= tuning.fall }
        for i in ripples.indices { ripples[i].age += dt }
        ripples.removeAll { $0.age >= tuning.rippleLife }

        if length < Self.restLength, abs(lengthVelocity) < Self.restSpeed, target == nil {
            placed = false
        }
    }

    private mutating func pinch(tuning: NotchDripTuning) {
        drops.append(Drop(x: x, y: length, vy: tuning.dropSpeed, size: length))
        if drops.count > tuning.maxDrops { drops.removeFirst(drops.count - tuning.maxDrops) }
        // The ring starts as the neck lets go, a beat after the pinch.
        ripples.append(Ripple(x: x, age: -Self.rippleDelay, size: length))
        if ripples.count > tuning.maxDrops { ripples.removeFirst(ripples.count - tuning.maxDrops) }
        // Snaps up toward the edge; the spring catches it there.
        lengthVelocity = -length * tuning.recoil
        refractory = tuning.refractory
    }

    /// Nothing left to move: the caller may stop stepping until the pull changes.
    func isAtRest(target: NotchDripReading?) -> Bool {
        guard drops.isEmpty, ripples.isEmpty, refractory == 0 else { return false }
        let pull = target?.pull ?? 0
        guard abs(length - pull) < Self.restLength, abs(lengthVelocity) < Self.restSpeed else { return false }
        if let target, length >= Self.restLength {
            return abs(x - target.x) < Self.restX && abs(xVelocity) < Self.restSpeed
        }
        return true
    }

    /// Anything to draw.
    var isVisible: Bool { length >= Self.restLength || !drops.isEmpty || !ripples.isEmpty }

    /// A damped spring, semi-implicit Euler at 240 Hz substeps so a long
    /// frame cannot blow it up. `response` is the undamped period
    /// in seconds, as SwiftUI's .spring(response:dampingFraction:).
    private static func spring(_ value: inout CGFloat, _ velocity: inout CGFloat, to target: CGFloat,
                               dt: Double, response: Double, damping: Double) {
        let omega = 2 * Double.pi / max(response, 0.01)
        let k = omega * omega
        let c = 2 * damping * omega
        let steps = max(1, Int((dt / (1.0 / 240)).rounded(.up)))
        let h = dt / Double(steps)
        var v = Double(velocity)
        var p = Double(value)
        for _ in 0..<steps {
            v += (-k * (p - Double(target)) - c * v) * h
            p += v * h
        }
        value = CGFloat(p)
        velocity = CGFloat(v)
    }
}

/// The drip's size in points, for drawing. The app's values are
/// UmbarMotion.dripLook; tests build their own.
struct NotchDripLook: Equatable {
    /// Points below the edge at full pull (the tip).
    var maxLength: CGFloat
    /// The bulb's radius at no and full length.
    var bulbRadius: ClosedRange<CGFloat>
    /// Half the width where the drip leaves the edge, at no and full length.
    var rootHalfWidth: ClosedRange<CGFloat>
    /// The neck's half width as a share of the bulb's radius.
    var neck: CGFloat
    /// How far the bulb trails the root while it slides, at most.
    var lean: CGFloat

    func bulbRadius(at length: CGFloat) -> CGFloat { Self.lerp(bulbRadius, length) }

    static func lerp(_ range: ClosedRange<CGFloat>, _ t: CGFloat) -> CGFloat {
        range.lowerBound + (range.upperBound - range.lowerBound) * min(max(t, 0), 1)
    }
}

/// The hanging drip's outline in points, below an edge at y = 0 running
/// 0...width, whose flat part starts `flat` in from either end.
struct NotchDripShape: Equatable {
    var rootX: CGFloat
    var rootHalf: CGFloat
    var neckHalf: CGFloat
    /// The bulb's center below the edge, and its radius.
    var bulb: CGPoint
    var radius: CGFloat

    /// Nil while there is nothing hanging.
    init?(_ sim: NotchDripSim, width: CGFloat, flat: CGFloat, look: NotchDripLook) {
        guard sim.length > 0.002 else { return nil }
        rootX = sim.x * width
        let lean = min(max(-sim.xVelocity * width * 0.05, -look.lean), look.lean)
        radius = look.bulbRadius(at: sim.length)
        let tip = sim.length * look.maxLength
        bulb = CGPoint(x: rootX + lean * sim.length, y: max(-radius * 0.6, tip - radius))
        // Never wider than the flat edge either side of it.
        rootHalf = min(NotchDripLook.lerp(look.rootHalfWidth, sim.length),
                       max(rootX - flat, 0), max(width - flat - rootX, 0))
        // Thick while it stretches or draws back slowly; only the pinch's
        // recoil (lengths per second well below zero) thins it.
        let pinch = min(max(1 + min(sim.lengthVelocity, 0) * 0.12, 0.35), 1)
        neckHalf = min(radius * look.neck * pinch, rootHalf)
    }
}
