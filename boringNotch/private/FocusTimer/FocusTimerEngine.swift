//
//  FocusTimerEngine.swift
//  boringNotch
//
//  F18: pure Pomodoro state machine. No Defaults, no timers, no AppKit, so it
//  compiles into umbarTests; the caller injects `now` on every call.
//
//  Time model: a running phase stores its wall-clock end (`endsAt`), never a
//  countdown. That is what lets the state survive an app restart and a sleep:
//  the remaining time is always `endsAt - now`, however long the process was
//  not running. A paused phase stores `pausedRemaining` instead.
//

import Foundation

enum FocusPhase: String, Codable, Equatable {
    case focus
    case shortBreak
    case longBreak

    var isBreak: Bool { self != .focus }
}

/// Length of a focus session and its short break, in minutes.
struct FocusPreset: Codable, Equatable {
    var focusMinutes: Int
    var breakMinutes: Int

    static let classic = FocusPreset(focusMinutes: 25, breakMinutes: 5)
    static let extended = FocusPreset(focusMinutes: 50, breakMinutes: 10)
}

struct FocusConfig: Equatable {
    var longBreakMinutes = 15
    /// A long break replaces the short one after this many completed focus sessions.
    var sessionsBeforeLongBreak = 4
    /// Seconds in one "minute". 60 in production; verification builds shorten it
    /// so a full cycle can be watched (see `focusTimerDebugMinuteSeconds`).
    var minuteLength: TimeInterval = 60

    func length(of phase: FocusPhase, preset: FocusPreset) -> TimeInterval {
        let minutes: Int
        switch phase {
        case .focus: minutes = preset.focusMinutes
        case .shortBreak: minutes = preset.breakMinutes
        case .longBreak: minutes = longBreakMinutes
        }
        return TimeInterval(max(1, minutes)) * minuteLength
    }
}

/// Everything that must survive a restart. Codable on purpose: stored as one blob.
struct FocusTimerState: Codable, Equatable {
    /// `nil` = idle.
    var phase: FocusPhase?
    /// Wall-clock end of the running phase. `nil` when idle or paused.
    var endsAt: Date?
    /// Seconds left when paused. `nil` unless paused.
    var pausedRemaining: TimeInterval?
    /// Total length of the current phase, for progress display.
    var phaseLength: TimeInterval = 0
    /// Focus sessions finished since the last long break.
    var completedFocus = 0
    var preset: FocusPreset = .classic

    static let idle = FocusTimerState(phase: nil, endsAt: nil, pausedRemaining: nil)

    var isIdle: Bool { phase == nil }
    var isPaused: Bool { phase != nil && pausedRemaining != nil }
    var isRunning: Bool { phase != nil && endsAt != nil }

    func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining { return pausedRemaining }
        if let endsAt { return max(0, endsAt.timeIntervalSince(now)) }
        return 0
    }
}

/// What a tick or a skip caused, for the caller to surface.
enum FocusEvent: Equatable {
    /// A focus session finished; `next` is the break that started.
    case focusCompleted(next: FocusPhase)
    /// A break ran out. `lateness` is how long ago it did (large after a sleep
    /// or restart), so the caller can skip a banner nobody is waiting for.
    case breakCompleted(lateness: TimeInterval)
}

struct FocusTimerEngine {
    private(set) var state: FocusTimerState
    var config: FocusConfig

    init(state: FocusTimerState = .idle, config: FocusConfig = FocusConfig()) {
        self.state = state
        self.config = config
    }

    // MARK: - User actions

    /// Starts a fresh focus session with `preset`, discarding whatever ran before.
    mutating func start(preset: FocusPreset, now: Date) {
        state.preset = preset
        state.completedFocus = 0
        begin(.focus, now: now)
    }

    /// Starts the next focus session of the running cycle: keeps the preset and
    /// the completed-session count, so the long break still arrives on time.
    mutating func startNextFocus(now: Date) {
        begin(.focus, now: now)
    }

    mutating func pause(now: Date) {
        guard state.isRunning else { return }
        state.pausedRemaining = state.remaining(at: now)
        state.endsAt = nil
    }

    mutating func resume(now: Date) {
        guard state.isPaused, let left = state.pausedRemaining else { return }
        state.endsAt = now.addingTimeInterval(left)
        state.pausedRemaining = nil
    }

    /// Jumps to the next phase. A skipped focus session does not count toward
    /// the long break (nothing was finished); a skipped break starts the next focus.
    mutating func skip(now: Date) {
        guard let phase = state.phase else { return }
        switch phase {
        case .focus:
            begin(nextBreak(completed: state.completedFocus), now: now)
        case .shortBreak:
            begin(.focus, now: now)
        case .longBreak:
            state.completedFocus = 0
            begin(.focus, now: now)
        }
    }

    mutating func stop() {
        state = FocusTimerState(phase: nil, endsAt: nil, pausedRemaining: nil, preset: state.preset)
    }

    // MARK: - Clock

    /// Advances past a finished phase. Cheap to call every second and on wake.
    ///
    /// The next phase starts at `now`, not at the old deadline: time the Mac
    /// spent asleep must not be charged to the break that follows it.
    @discardableResult
    mutating func tick(now: Date) -> FocusEvent? {
        guard let phase = state.phase, let endsAt = state.endsAt, now >= endsAt else { return nil }
        let lateness = now.timeIntervalSince(endsAt)
        switch phase {
        case .focus:
            state.completedFocus += 1
            let next = nextBreak(completed: state.completedFocus)
            begin(next, now: now)
            return .focusCompleted(next: next)
        case .shortBreak, .longBreak:
            // Back to idle rather than chaining into a new focus: the user
            // decides when to start working again.
            if phase == .longBreak { state.completedFocus = 0 }
            state = FocusTimerState(
                phase: nil, endsAt: nil, pausedRemaining: nil,
                completedFocus: state.completedFocus, preset: state.preset)
            return .breakCompleted(lateness: lateness)
        }
    }

    // MARK: - Internals

    private func nextBreak(completed: Int) -> FocusPhase {
        completed >= config.sessionsBeforeLongBreak ? .longBreak : .shortBreak
    }

    private mutating func begin(_ phase: FocusPhase, now: Date) {
        let length = config.length(of: phase, preset: state.preset)
        state.phase = phase
        state.phaseLength = length
        state.endsAt = now.addingTimeInterval(length)
        state.pausedRemaining = nil
    }
}

enum FocusTimerFormat {
    /// "24:03", or "1:05:00" from one hour up. Rounds up so the display never
    /// shows 00:00 while time is still left.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }
}
