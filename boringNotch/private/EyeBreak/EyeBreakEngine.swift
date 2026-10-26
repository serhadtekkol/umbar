//
//  EyeBreakEngine.swift
//  boringNotch
//
//  Pure scheduling logic for the 20-20-20 eye-break reminder (F14, AC-14.x).
//
//  Deliberately Foundation-only and free of timers, Defaults and AppKit: every
//  input (the clock, idle seconds, lock state) is passed in, so the whole state
//  machine is unit-testable with a fake clock. See umbarTests/EyeBreakEngineTests.
//

import Foundation

/// User-tunable durations (BR-14.1: all adjustable). Defaults follow AC-14.x.
struct EyeBreakConfig: Equatable {
    /// Active use needed before a reminder is due. Default 20 min.
    var interval: TimeInterval = 20 * 60
    /// Length of the "look away" countdown. Default 20 s.
    var breakDuration: TimeInterval = 20
    /// Delay used by "5 min snooze" (AC-14.3).
    var snoozeDuration: TimeInterval = 5 * 60
    /// Keyboard/mouse idle time after which the user is considered to have
    /// taken a break already and the counter restarts (AC-14.4).
    var idleReset: TimeInterval = 5 * 60
}

/// What the engine is doing right now.
enum EyeBreakPhase: Equatable {
    /// Accumulating active-use time toward the next reminder.
    case counting
    /// Reminder is on screen until `endsAt` (AC-14.1 / AC-14.6).
    case prompting(endsAt: Date)
    /// User chose "snooze"; the reminder is due again at `until` (AC-14.3).
    case snoozed(until: Date)
}

/// A snapshot of the outside world, sampled by the caller on every tick.
struct EyeBreakInputs: Equatable {
    var now: Date
    /// Seconds since the last keyboard/mouse event.
    var idleSeconds: TimeInterval
    /// Screen locked, display asleep or system asleep (AC-14.4).
    var isSuspended: Bool
    /// Frontmost app is playing full-screen video / presenting (AC-14.5).
    var isDeferred: Bool
}

struct EyeBreakEngine {
    private(set) var phase: EyeBreakPhase = .counting
    /// Seconds of active use accumulated since the last reset.
    private(set) var activeSeconds: TimeInterval = 0
    var config: EyeBreakConfig

    private var lastTick: Date?

    /// Gaps between ticks longer than this are treated as "the process was not
    /// running" (App Nap, sleep we missed a notification for) and are not
    /// counted as active use. Without it a wake from sleep could count hours.
    static let maxCountableGap: TimeInterval = 30

    init(config: EyeBreakConfig = EyeBreakConfig()) {
        self.config = config
    }

    /// Advances the state machine. Returns `true` if `phase` changed, so the
    /// caller only publishes to the UI when something visible happened.
    @discardableResult
    mutating func tick(_ input: EyeBreakInputs) -> Bool {
        let before = phase
        let elapsed = lastTick.map { max(0, input.now.timeIntervalSince($0)) } ?? 0
        lastTick = input.now

        // AC-14.4: lock/sleep or >= idleReset without input counts as a break
        // already taken. This also dismisses an on-screen reminder: the user
        // has visibly looked away, nagging them on return would be noise.
        if input.isSuspended || input.idleSeconds >= config.idleReset {
            reset()
            return phase != before
        }

        switch phase {
        case .counting:
            if elapsed <= Self.maxCountableGap { activeSeconds += elapsed }
            // AC-14.5: while deferred the reminder stays pending (the counter
            // keeps its value) and fires on the first tick after it clears.
            if activeSeconds >= config.interval, !input.isDeferred {
                phase = .prompting(endsAt: input.now.addingTimeInterval(config.breakDuration))
            }
        case .prompting(let endsAt):
            // AC-14.6: countdown finished -> auto-dismiss, fresh interval.
            if input.now >= endsAt { reset() }
        case .snoozed(let until):
            if input.now >= until, !input.isDeferred {
                phase = .prompting(endsAt: input.now.addingTimeInterval(config.breakDuration))
            }
        }
        return phase != before
    }

    /// AC-14.2: "Skip" restarts the full interval.
    mutating func skip() { reset() }

    /// AC-14.3: "5 min snooze" re-raises the reminder after `snoozeDuration`.
    mutating func snooze(now: Date) {
        guard case .prompting = phase else { return }
        phase = .snoozed(until: now.addingTimeInterval(config.snoozeDuration))
    }

    /// Back to a clean interval. Also used when the feature is toggled off/on.
    mutating func reset() {
        phase = .counting
        activeSeconds = 0
    }
}
