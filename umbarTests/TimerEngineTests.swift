//
//  TimerEngineTests.swift
//  umbarTests
//
//  F25 timer + stopwatch: deadline math, pause/resume, a sleep gap, restart
//  survival, and which clock owns the closed island's leading ear. The
//  engine takes `now` as input, so no real time passes.
//

import Foundation
import Testing

private let epoch = Date(timeIntervalSince1970: 2_000_000)
private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

@Suite("TimerEngine countdown", .timeLimit(.minutes(1)))
struct TimerCountdownTests {
    private func started(_ minutes: Int = 5) -> TimerEngine {
        var e = TimerEngine()
        e.startCountdown(minutes: minutes, now: epoch)
        return e
    }

    @Test func startSetsAWallClockDeadline() {
        let e = started(5)
        #expect(e.state.mode == .countdown)
        #expect(e.state.endsAt == at(300))
        #expect(e.state.remaining(at: at(10)) == 290)
        #expect(e.state.isRunning)
    }

    @Test func lengthIsClampedToTheAcceptedRange() {
        var e = TimerEngine()
        e.startCountdown(minutes: 0, now: epoch)
        #expect(e.state.duration == 60)
        e.startCountdown(minutes: 100_000, now: epoch)
        #expect(e.state.duration == TimeInterval(TimerEngine.minuteRange.upperBound) * 60)
    }

    @Test func tickBeforeTheDeadlineDoesNothing() {
        var e = started(1)
        #expect(e.tick(now: at(59.9)) == nil)
        #expect(e.state.isRunning)
    }

    @Test func tickAtTheDeadlineFinishesExactlyOnce() {
        var e = started(1)
        #expect(e.tick(now: at(60)) == .countdownFinished(lateness: 0))
        #expect(e.state.isIdle)
        #expect(e.tick(now: at(61)) == nil)
    }

    @Test func finishedCountdownKeepsItsLengthForAgain() {
        var e = started(10)
        e.tick(now: at(600))
        #expect(e.state.duration == 600)
        #expect(e.state.mode == .countdown)
    }

    @Test func pauseFreezesTheRemainingTime() {
        var e = started(5)
        e.pause(now: at(100))
        #expect(e.state.isPaused)
        #expect(e.state.remaining(at: at(10_000)) == 200)
        // A paused countdown never finishes, however late it is ticked.
        #expect(e.tick(now: at(10_000)) == nil)
    }

    @Test func resumeSetsANewDeadlineFromNow() {
        var e = started(5)
        e.pause(now: at(100))
        e.resume(now: at(1_000))
        #expect(e.state.endsAt == at(1_200))
        #expect(e.tick(now: at(1_199)) == nil)
        #expect(e.tick(now: at(1_200)) != nil)
    }

    @Test func pauseAndResumeAreIgnoredInTheWrongState() {
        var e = started(5)
        e.resume(now: at(10))
        #expect(e.state.endsAt == at(300))
        e.pause(now: at(10))
        e.pause(now: at(50))
        #expect(e.state.pausedRemaining == 290)
    }

    /// The Mac slept through the deadline: the first tick after wake ends it
    /// and reports how late, instead of counting the sleep as running ticks.
    @Test func sleepThroughTheDeadlineReportsLateness() {
        var e = started(5)
        #expect(e.tick(now: at(299)) == nil)
        // 2 h asleep, no ticks in between.
        #expect(e.tick(now: at(299 + 7_200)) == .countdownFinished(lateness: 7_199))
    }

    @Test func sleepShorterThanTheRemainingTimeIsChargedToTheTimer() {
        var e = started(25)
        e.tick(now: at(60))
        // Woke 10 min later: 14 min left, not 24.
        #expect(e.tick(now: at(660)) == nil)
        #expect(e.state.remaining(at: at(660)) == 840)
    }

    @Test func stateSurvivesARestartThroughCodable() throws {
        let e = started(5)
        let data = try JSONEncoder().encode(e.state)
        var restored = TimerEngine(state: try JSONDecoder().decode(TimerState.self, from: data))
        #expect(restored.state == e.state)
        #expect(restored.tick(now: at(301)) == .countdownFinished(lateness: 1))
    }

    @Test func resetReturnsToIdleAndKeepsTheLength() {
        var e = started(5)
        e.reset()
        #expect(e.state.isIdle)
        #expect(e.state.duration == 300)
    }

    @Test func debugMinuteLengthShortensTheTimer() {
        var e = TimerEngine()
        e.startCountdown(minutes: 5, minuteLength: 2, now: epoch)
        #expect(e.state.endsAt == at(10))
    }
}

@Suite("TimerEngine stopwatch", .timeLimit(.minutes(1)))
struct TimerStopwatchTests {
    private func started() -> TimerEngine {
        var e = TimerEngine()
        e.startStopwatch(now: epoch)
        return e
    }

    @Test func elapsedIsDerivedFromTheWallClock() {
        let e = started()
        #expect(e.state.mode == .stopwatch)
        #expect(e.state.elapsed(at: at(42.5)) == 42.5)
    }

    @Test func sleepCountsAsElapsedTime() {
        var e = started()
        // A stopwatch is a clock on the desk: an hour of sleep is an hour.
        #expect(e.tick(now: at(3_600)) == nil)
        #expect(e.state.elapsed(at: at(3_600)) == 3_600)
    }

    @Test func pauseBanksTheTimeAndResumeContinuesFromIt() {
        var e = started()
        e.pause(now: at(30))
        #expect(e.state.isPaused)
        #expect(e.state.elapsed(at: at(500)) == 30)
        e.resume(now: at(500))
        #expect(e.state.elapsed(at: at(510)) == 40)
    }

    @Test func clockSetBackwardsNeverLowersTheElapsedTime() {
        var e = started()
        e.pause(now: at(30))
        e.resume(now: at(100))
        #expect(e.state.elapsed(at: at(50)) == 30)
    }

    @Test func lapsRecordElapsedMarksAndLastLapLength() {
        var e = started()
        e.lap(now: at(10))
        e.lap(now: at(25))
        #expect(e.state.laps == [10, 25])
        #expect(e.state.lastLapLength == 15)
    }

    @Test func lapIsIgnoredWhilePausedAndPastTheCap() {
        var e = started()
        e.pause(now: at(5))
        e.lap(now: at(6))
        #expect(e.state.laps.isEmpty)
        e.resume(now: at(6))
        for i in 0..<(TimerState.maxLaps + 5) { e.lap(now: at(7 + Double(i))) }
        #expect(e.state.laps.count == TimerState.maxLaps)
    }

    @Test func startingACountdownReplacesTheStopwatch() {
        var e = started()
        e.lap(now: at(10))
        e.startCountdown(minutes: 1, now: at(20))
        #expect(e.state.mode == .countdown)
        #expect(e.state.laps.isEmpty)
        #expect(e.state.runningSince == nil)
    }

    @Test func resetClearsElapsedAndLaps() {
        var e = started()
        e.lap(now: at(10))
        e.reset()
        #expect(e.state.isIdle)
        #expect(e.state.mode == .stopwatch)
        #expect(e.state.laps.isEmpty)
    }
}

@Suite("Leading time ear", .timeLimit(.minutes(1)))
struct LeadingTimeEarPolicyTests {
    private var runningCountdown: TimerState {
        var e = TimerEngine(); e.startCountdown(minutes: 5, now: epoch); return e.state
    }
    private var runningStopwatch: TimerState {
        var e = TimerEngine(); e.startStopwatch(now: epoch); return e.state
    }

    @Test func nothingRunningShowsNoEar() {
        #expect(LeadingTimeEarPolicy.owner(focusActive: false, timer: .idle, alerting: false, timerEnabled: true) == .none)
    }

    @Test func runningCountdownBeatsFocus() {
        #expect(LeadingTimeEarPolicy.owner(focusActive: true, timer: runningCountdown, alerting: false, timerEnabled: true) == .timer)
    }

    @Test func focusBeatsAStopwatchAndAPausedCountdown() {
        var paused = TimerEngine(state: runningCountdown); paused.pause(now: at(1))
        #expect(LeadingTimeEarPolicy.owner(focusActive: true, timer: runningStopwatch, alerting: false, timerEnabled: true) == .focus)
        #expect(LeadingTimeEarPolicy.owner(focusActive: true, timer: paused.state, alerting: false, timerEnabled: true) == .focus)
    }

    @Test func anAlertBeatsEverything() {
        #expect(LeadingTimeEarPolicy.owner(focusActive: true, timer: .idle, alerting: true, timerEnabled: true) == .timer)
    }

    @Test func stopwatchAloneTakesTheEar() {
        #expect(LeadingTimeEarPolicy.owner(focusActive: false, timer: runningStopwatch, alerting: false, timerEnabled: true) == .timer)
    }

    @Test func disabledTimerNeverTakesTheEar() {
        #expect(LeadingTimeEarPolicy.owner(focusActive: false, timer: runningCountdown, alerting: true, timerEnabled: false) == .none)
        #expect(LeadingTimeEarPolicy.owner(focusActive: true, timer: runningCountdown, alerting: true, timerEnabled: false) == .focus)
    }
}

@Suite("TimerFormat", .timeLimit(.minutes(1)))
struct TimerFormatTests {
    @Test func elapsedRoundsDownAndRemainingRoundsUp() {
        #expect(TimerFormat.elapsed(59.9) == "00:59")
        #expect(FocusTimerFormat.clock(59.1) == "01:00")
        #expect(TimerFormat.elapsed(3_725) == "1:02:05")
    }
}
