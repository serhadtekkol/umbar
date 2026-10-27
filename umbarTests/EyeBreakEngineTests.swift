//
//  EyeBreakEngineTests.swift
//  umbarTests
//
//  F14 20-20-20 reminder (AC-14.1 .. AC-14.6, BR-14.1). The engine never
//  reads the clock; every tick gets a time relative to a fixed epoch.
//  Ported from scripts/eyebreak-engine-tests, which this replaces.
//

import Foundation
import Testing

private let epoch = Date(timeIntervalSince1970: 1_000_000)
private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

private func input(
    _ t: TimeInterval, idle: TimeInterval = 0, suspended: Bool = false, deferred: Bool = false
) -> EyeBreakInputs {
    EyeBreakInputs(now: at(t), idleSeconds: idle, isSuspended: suspended, isDeferred: deferred)
}

/// Ticks every `step` seconds from `from` to `to`, inclusive.
private func run(
    _ engine: inout EyeBreakEngine, from: TimeInterval, to: TimeInterval, step: TimeInterval = 5,
    idle: TimeInterval = 0, suspended: Bool = false, deferred: Bool = false
) {
    var t = from
    while t <= to {
        engine.tick(input(t, idle: idle, suspended: suspended, deferred: deferred))
        t += step
    }
}

private extension EyeBreakEngine {
    var isPrompting: Bool {
        if case .prompting = phase { return true }
        return false
    }
}

/// Defaults: 20 min interval, 20 s break, 5 min snooze, 5 min idle reset.
private func freshEngine() -> EyeBreakEngine { EyeBreakEngine(config: EyeBreakConfig()) }

/// An engine that reached its first prompt at t = 1200.
private func prompted() -> EyeBreakEngine {
    var engine = freshEngine()
    run(&engine, from: 0, to: 1200)
    return engine
}

@Suite("EyeBreakEngine", .timeLimit(.minutes(1)))
struct EyeBreakEngineTests {
    @Test func promptsWhenTwentyMinutesOfUseAreReached() {          // AC-14.1
        var engine = freshEngine()
        run(&engine, from: 0, to: 1195)
        #expect(engine.phase == .counting, "not yet due at 19:55")
        engine.tick(input(1200))
        #expect(engine.phase == .prompting(endsAt: at(1220)), "20 s countdown")
    }

    @Test func countdownEndAutoDismissesAndStartsAFreshInterval() {  // AC-14.6
        var engine = prompted()
        run(&engine, from: 1205, to: 1219)
        #expect(engine.isPrompting, "still prompting at 19 s")
        engine.tick(input(1220))
        #expect(engine.phase == .counting)
        #expect(engine.activeSeconds == 0)
        run(&engine, from: 1225, to: 1220 + 1195)
        #expect(engine.phase == .counting, "no reminder before another 20 min")
        engine.tick(input(1220 + 1200))
        #expect(engine.isPrompting)
    }

    @Test func skipRestartsTheFullInterval() {                       // AC-14.2
        var engine = prompted()
        engine.skip()
        #expect(engine.phase == .counting)
        #expect(engine.activeSeconds == 0)
        run(&engine, from: 1205, to: 1200 + 1195)
        #expect(engine.phase == .counting)
    }

    @Test func snoozeRepromptsAfterFiveMinutes() {                   // AC-14.3
        var engine = prompted()
        engine.snooze(now: at(1202))
        #expect(engine.phase == .snoozed(until: at(1502)))
        run(&engine, from: 1205, to: 1500)
        #expect(engine.phase == .snoozed(until: at(1502)), "silent during the snooze")
        engine.tick(input(1505))
        #expect(engine.isPrompting)
    }

    @Test func snoozeOutsideAPromptIsIgnored() {
        var engine = freshEngine()
        engine.snooze(now: epoch)
        #expect(engine.phase == .counting)
    }

    @Test func idleResetIsInclusiveAtFiveMinutes() {                 // AC-14.4
        var engine = freshEngine()
        run(&engine, from: 0, to: 600)
        engine.tick(input(605, idle: 299))
        #expect(engine.activeSeconds > 600, "299 s idle does not reset")
        engine.tick(input(610, idle: 300))
        #expect(engine.activeSeconds == 0, "300 s idle resets")
        run(&engine, from: 615, to: 610 + 1195)
        #expect(engine.phase == .counting, "a full interval is needed after the reset")
    }

    @Test func lockDismissesAPromptAndResets() {                     // AC-14.4
        var engine = prompted()
        engine.tick(input(1205, suspended: true))
        #expect(engine.phase == .counting)
        #expect(engine.activeSeconds == 0)
    }

    @Test func sleepMidIntervalResets() {                            // AC-14.4
        var engine = freshEngine()
        run(&engine, from: 0, to: 900)
        engine.tick(input(905, suspended: true))
        #expect(engine.activeSeconds == 0)
    }

    @Test func deferralHoldsTheReminderUntilItClears() {             // AC-14.5
        var engine = freshEngine()
        run(&engine, from: 0, to: 1195)
        run(&engine, from: 1200, to: 1500, deferred: true)
        #expect(engine.phase == .counting, "no prompt during full-screen video")
        engine.tick(input(1505))
        #expect(engine.isPrompting, "fires on the first tick after the deferral clears")
    }

    @Test func snoozeExpiryAlsoWaitsForTheDeferral() {               // AC-14.5
        var engine = prompted()
        engine.snooze(now: at(1200))
        run(&engine, from: 1505, to: 1600, deferred: true)
        guard case .snoozed = engine.phase else {
            Issue.record("expected snoozed, got \(engine.phase)")
            return
        }
    }

    /// A gap longer than `maxCountableGap` (missed sleep, App Nap) is not
    /// counted as active use; without this a wake could count hours.
    @Test func longGapBetweenTicksIsNotCountedAsUse() {
        var engine = freshEngine()
        run(&engine, from: 0, to: 10)
        engine.tick(input(10 + 4 * 3600))
        #expect(engine.phase == .counting)
        #expect(engine.activeSeconds <= 15)
    }

    @Test func gapExactlyAtTheLimitIsCounted() {
        var engine = freshEngine()
        engine.tick(input(0))
        engine.tick(input(EyeBreakEngine.maxCountableGap))
        #expect(engine.activeSeconds == EyeBreakEngine.maxCountableGap)
    }

    @Test func durationsAreAdjustable() {                            // BR-14.1
        var engine = EyeBreakEngine(config: EyeBreakConfig(interval: 30, breakDuration: 5, snoozeDuration: 10, idleReset: 20))
        run(&engine, from: 0, to: 30, step: 1)
        #expect(engine.phase == .prompting(endsAt: at(35)))
    }

    @Test func tickReportsOnlyPhaseChanges() {
        var engine = freshEngine()
        #expect(engine.tick(input(0)) == false)
        run(&engine, from: 5, to: 1195)
        #expect(engine.tick(input(1200)) == true, "counting -> prompting")
        #expect(engine.tick(input(1205)) == false, "still prompting")
    }
}
