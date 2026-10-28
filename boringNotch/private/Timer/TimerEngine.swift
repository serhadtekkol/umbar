//
//  TimerEngine.swift
//  boringNotch
//
//  F25: pure countdown timer + stopwatch state machine. No Defaults, no
//  timers, no AppKit, so it compiles into umbarTests; the caller injects
//  `now` on every call.
//
//  Time model, same as the focus timer: nothing is ever counted in ticks.
//  A running countdown stores its wall-clock deadline (`endsAt`), a running
//  stopwatch the moment it was (re)started (`runningSince`) plus what it had
//  accumulated before. Remaining and elapsed are derived from `now`, so a
//  sleep or an app restart costs nothing: the countdown is simply over (or
//  closer to over) when the Mac wakes, and the stopwatch has kept counting,
//  which is what a stopwatch on a desk would have done.
//
//  Known limit: the wall clock is what is measured. If the user moves the
//  system clock by hand while a timer runs, the timer moves with it. A
//  monotonic clock (`ContinuousClock`) would not, but it does not survive a
//  restart and the focus timer already behaves this way; one rule for both.
//

import Foundation

enum TimerMode: String, Codable, Equatable, CaseIterable {
    case countdown
    case stopwatch
}

/// Everything that must survive a restart. Codable on purpose: stored as one blob.
/// Only one mode is live at a time; starting one discards the other.
struct TimerState: Codable, Equatable {
    var mode: TimerMode = .countdown

    // Countdown
    /// Length the countdown was started with, for "again" and for display.
    var duration: TimeInterval = 0
    /// Wall-clock end of a running countdown. `nil` unless running.
    var endsAt: Date?
    /// Seconds left while a countdown is paused. `nil` unless paused.
    var pausedRemaining: TimeInterval?

    // Stopwatch
    /// When the stopwatch was last started or resumed. `nil` unless running.
    var runningSince: Date?
    /// Elapsed time banked before `runningSince` (all earlier running spans).
    var accumulated: TimeInterval = 0
    /// Elapsed time at each lap mark, oldest first. Capped at `maxLaps`.
    var laps: [TimeInterval] = []

    static let idle = TimerState()
    static let maxLaps = 99

    var isRunning: Bool {
        switch mode {
        case .countdown: return endsAt != nil
        case .stopwatch: return runningSince != nil
        }
    }

    var isPaused: Bool {
        switch mode {
        case .countdown: return pausedRemaining != nil
        case .stopwatch: return runningSince == nil && accumulated > 0
        }
    }

    var isIdle: Bool { !isRunning && !isPaused }

    /// Countdown only: time left, never negative.
    func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        return 0
    }

    /// Stopwatch only: total running time. A clock set backwards while it runs
    /// cannot make it go below what was already banked.
    func elapsed(at now: Date) -> TimeInterval {
        guard let runningSince else { return accumulated }
        return accumulated + max(0, now.timeIntervalSince(runningSince))
    }

    /// The figure the UI shows for the live mode.
    func displayTime(at now: Date) -> TimeInterval {
        mode == .countdown ? remaining(at: now) : elapsed(at: now)
    }

    /// Length of the most recent lap (time since the lap before it).
    var lastLapLength: TimeInterval? {
        guard let last = laps.last else { return nil }
        return last - (laps.dropLast().last ?? 0)
    }
}

enum TimerEvent: Equatable {
    /// A countdown reached zero. `lateness` is how long ago it did: large
    /// after a sleep or a restart, so the caller can hold back a sound
    /// nobody is waiting for any more.
    case countdownFinished(lateness: TimeInterval)
}

struct TimerEngine {
    private(set) var state: TimerState

    /// Countdown lengths accepted, in minutes. The upper bound keeps a typo
    /// (6000 instead of 60) from becoming a four-day timer.
    static let minuteRange = 1...720

    init(state: TimerState = .idle) {
        self.state = state
    }

    // MARK: - Countdown

    /// Starts a countdown of `minutes` (clamped to `minuteRange`), discarding
    /// whatever ran before in either mode.
    mutating func startCountdown(minutes: Int, minuteLength: TimeInterval = 60, now: Date) {
        let clamped = min(max(minutes, Self.minuteRange.lowerBound), Self.minuteRange.upperBound)
        let length = TimeInterval(clamped) * minuteLength
        state = TimerState(mode: .countdown, duration: length, endsAt: now.addingTimeInterval(length))
    }

    // MARK: - Stopwatch

    mutating func startStopwatch(now: Date) {
        state = TimerState(mode: .stopwatch, runningSince: now)
    }

    /// Marks a lap on a running stopwatch. Ignored when paused (a lap of a
    /// stopped watch is the same mark as the previous one) and past `maxLaps`.
    mutating func lap(now: Date) {
        guard state.mode == .stopwatch, state.runningSince != nil,
              state.laps.count < TimerState.maxLaps else { return }
        state.laps.append(state.elapsed(at: now))
    }

    // MARK: - Both modes

    mutating func pause(now: Date) {
        guard state.isRunning else { return }
        switch state.mode {
        case .countdown:
            state.pausedRemaining = state.remaining(at: now)
            state.endsAt = nil
        case .stopwatch:
            state.accumulated = state.elapsed(at: now)
            state.runningSince = nil
        }
    }

    mutating func resume(now: Date) {
        guard state.isPaused else { return }
        switch state.mode {
        case .countdown:
            guard let left = state.pausedRemaining else { return }
            state.endsAt = now.addingTimeInterval(left)
            state.pausedRemaining = nil
        case .stopwatch:
            state.runningSince = now
        }
    }

    /// Back to idle in the current mode. A countdown keeps its last length,
    /// so the tile can offer to run it again.
    mutating func reset() {
        state = TimerState(mode: state.mode, duration: state.mode == .countdown ? state.duration : 0)
    }

    // MARK: - Clock

    /// Ends a countdown whose deadline has passed. Cheap to call every second
    /// and on wake. A stopwatch never ends, so it never produces an event.
    @discardableResult
    mutating func tick(now: Date) -> TimerEvent? {
        guard state.mode == .countdown, let endsAt = state.endsAt, now >= endsAt else { return nil }
        let lateness = now.timeIntervalSince(endsAt)
        reset()
        return .countdownFinished(lateness: lateness)
    }
}

/// Which timer owns the closed island's leading ear. There is one slot on
/// that edge for time: the focus timer and this one never draw side by side.
enum LeadingTimeEar: Equatable {
    case none
    case focus
    case timer
}

enum LeadingTimeEarPolicy {
    /// Priority, highest first:
    /// 1. a countdown that just finished (its alert is the reason to look);
    /// 2. a running countdown: the user set it for something soon, and the
    ///    focus timer is still on the Araçlar card and its own banner;
    /// 3. the focus timer, running or paused;
    /// 4. a running stopwatch, then a paused countdown or stopwatch.
    static func owner(focusActive: Bool, timer: TimerState, alerting: Bool, timerEnabled: Bool) -> LeadingTimeEar {
        if timerEnabled && alerting { return .timer }
        if timerEnabled && timer.mode == .countdown && timer.isRunning { return .timer }
        if focusActive { return .focus }
        if timerEnabled && !timer.isIdle { return .timer }
        return .none
    }
}

enum TimerFormat {
    /// Elapsed time rounds down (a stopwatch must not show a second that has
    /// not passed yet); remaining time uses `FocusTimerFormat.clock`, which
    /// rounds up.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    static func display(_ state: TimerState, at now: Date) -> String {
        state.mode == .countdown
            ? FocusTimerFormat.clock(state.remaining(at: now))
            : elapsed(state.elapsed(at: now))
    }
}
