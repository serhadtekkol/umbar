//
//  FocusTimerEngineTests.swift
//  umbarTests
//
//  F18 focus timer: phases, long break cadence, pause, wall-clock survival of
//  a restart or sleep. The engine takes `now` as input, so no real time passes.
//

import Foundation
import Testing

private let epoch = Date(timeIntervalSince1970: 2_000_000)
private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }
private let min = 60.0

@Suite("FocusTimerEngine", .timeLimit(.minutes(1)))
struct FocusTimerEngineTests {
    private func started(_ preset: FocusPreset = .classic) -> FocusTimerEngine {
        var e = FocusTimerEngine()
        e.start(preset: preset, now: epoch)
        return e
    }

    @Test func startsAFocusSessionOfThePresetLength() {
        let e = started(.extended)
        #expect(e.state.phase == .focus)
        #expect(e.state.remaining(at: epoch) == 50 * min)
        #expect(e.state.isRunning)
    }

    @Test func focusEndsIntoAShortBreakExactlyAtTheDeadline() {
        var e = started()
        #expect(e.tick(now: at(25 * min - 0.001)) == nil)
        #expect(e.tick(now: at(25 * min)) == .focusCompleted(next: .shortBreak))
        #expect(e.state.phase == .shortBreak)
        #expect(e.state.remaining(at: at(25 * min)) == 5 * min)
        #expect(e.state.completedFocus == 1)
    }

    @Test func breakEndsIntoIdleAndKeepsTheSessionCount() {
        var e = started()
        e.tick(now: at(25 * min))
        #expect(e.tick(now: at(30 * min)) == .breakCompleted(lateness: 0))
        #expect(e.state.isIdle)
        #expect(e.state.completedFocus == 1)
    }

    @Test func fourthSessionEarnsALongBreakThenTheCountResets() {
        var e = started()
        var t = 0.0
        for n in 1...4 {
            t += 25 * min
            let expected: FocusPhase = n == 4 ? .longBreak : .shortBreak
            #expect(e.tick(now: at(t)) == .focusCompleted(next: expected))
            if n < 4 {
                t += 5 * min
                e.tick(now: at(t))
                e.startNextFocus(now: at(t))
            }
        }
        #expect(e.state.remaining(at: at(t)) == 15 * min)
        t += 15 * min
        e.tick(now: at(t))
        #expect(e.state.completedFocus == 0)
        #expect(e.state.isIdle)
    }

    @Test func startingTheNextFocusKeepsTheCycleButStartDoesNot() {
        var e = started()
        e.tick(now: at(25 * min))
        e.tick(now: at(30 * min))
        e.startNextFocus(now: at(31 * min))
        #expect(e.state.completedFocus == 1)
        e.start(preset: .classic, now: at(32 * min))
        #expect(e.state.completedFocus == 0)
    }

    @Test func longBreakLengthAndCadenceComeFromConfig() {
        var cfg = FocusConfig()
        cfg.sessionsBeforeLongBreak = 1
        cfg.longBreakMinutes = 20
        var e = FocusTimerEngine(config: cfg)
        e.start(preset: .classic, now: epoch)
        #expect(e.tick(now: at(25 * min)) == .focusCompleted(next: .longBreak))
        #expect(e.state.remaining(at: at(25 * min)) == 20 * min)
    }

    @Test func pauseFreezesTheRemainingTimeAndResumeContinuesIt() {
        var e = started()
        e.pause(now: at(10 * min))
        #expect(e.state.isPaused)
        #expect(e.state.remaining(at: at(10 * min)) == 15 * min)
        // An hour of pause changes nothing, and a tick never ends a paused phase.
        #expect(e.tick(now: at(70 * min)) == nil)
        #expect(e.state.remaining(at: at(70 * min)) == 15 * min)
        e.resume(now: at(70 * min))
        #expect(e.state.remaining(at: at(70 * min)) == 15 * min)
        #expect(e.tick(now: at(85 * min)) == .focusCompleted(next: .shortBreak))
    }

    @Test func pauseAndResumeAreNoOpsInTheWrongState() {
        var e = FocusTimerEngine()
        e.pause(now: epoch)
        e.resume(now: epoch)
        #expect(e.state.isIdle)
        var r = started()
        r.resume(now: at(5))  // not paused
        #expect(r.state.remaining(at: at(5)) == 25 * min - 5)
    }

    @Test func skippingFocusStartsTheBreakWithoutCountingTheSession() {
        var e = started()
        e.skip(now: at(3 * min))
        #expect(e.state.phase == .shortBreak)
        #expect(e.state.completedFocus == 0)
        #expect(e.state.remaining(at: at(3 * min)) == 5 * min)
    }

    @Test func skippingABreakStartsTheNextFocus() {
        var e = started()
        e.tick(now: at(25 * min))
        e.skip(now: at(26 * min))
        #expect(e.state.phase == .focus)
        #expect(e.state.completedFocus == 1)
        #expect(e.state.remaining(at: at(26 * min)) == 25 * min)
    }

    @Test func stopReturnsToIdleAndForgetsTheCount() {
        var e = started()
        e.tick(now: at(25 * min))
        e.stop()
        #expect(e.state.isIdle)
        #expect(e.state.remaining(at: at(26 * min)) == 0)
        // Preset is remembered so "next focus" can reuse it.
        #expect(e.state.preset == .classic)
    }

    // MARK: wall clock: restart and sleep

    @Test func stateSurvivesARestartThroughCodable() throws {
        var e = started(.extended)
        e.tick(now: at(1))
        let data = try JSONEncoder().encode(e.state)
        let restored = FocusTimerEngine(state: try JSONDecoder().decode(FocusTimerState.self, from: data))
        #expect(restored.state == e.state)
        // Twenty minutes of "app not running" are counted against the session.
        #expect(restored.state.remaining(at: at(20 * min)) == 30 * min)
    }

    @Test func pausedStateSurvivesARestartUnchanged() throws {
        var e = started()
        e.pause(now: at(5 * min))
        let data = try JSONEncoder().encode(e.state)
        let restored = FocusTimerEngine(state: try JSONDecoder().decode(FocusTimerState.self, from: data))
        #expect(restored.state.isPaused)
        #expect(restored.state.remaining(at: at(500 * min)) == 20 * min)
    }

    @Test func focusThatEndedDuringSleepStartsAFullBreakAtWake() {
        var e = started()
        let wake = at(3 * 3600)
        #expect(e.tick(now: wake) == .focusCompleted(next: .shortBreak))
        // The break is not eaten by the time the Mac slept.
        #expect(e.state.remaining(at: wake) == 5 * min)
    }

    @Test func breakThatEndedDuringSleepGoesIdleAndReportsHowLate() {
        var e = started()
        e.tick(now: at(25 * min))
        let wake = at(25 * min + 5 * min + 2 * 3600)
        #expect(e.tick(now: wake) == .breakCompleted(lateness: 2 * 3600))
        #expect(e.state.isIdle)
    }

    @Test func tickWhileIdleDoesNothing() {
        var e = FocusTimerEngine()
        #expect(e.tick(now: at(1_000_000)) == nil)
    }

    @Test func debugMinuteLengthShortensEveryPhase() {
        var cfg = FocusConfig()
        cfg.minuteLength = 2
        var e = FocusTimerEngine(config: cfg)
        e.start(preset: .classic, now: epoch)
        #expect(e.state.remaining(at: epoch) == 50)
        #expect(e.tick(now: at(50)) == .focusCompleted(next: .shortBreak))
        #expect(e.state.remaining(at: at(50)) == 10)
    }

    @Test func clockFormatting() {
        #expect(FocusTimerFormat.clock(0) == "00:00")
        #expect(FocusTimerFormat.clock(0.2) == "00:01")  // never 00:00 with time left
        #expect(FocusTimerFormat.clock(25 * min) == "25:00")
        #expect(FocusTimerFormat.clock(59 * min + 59) == "59:59")
        #expect(FocusTimerFormat.clock(3600) == "1:00:00")
        #expect(FocusTimerFormat.clock(-5) == "00:00")
    }
}
