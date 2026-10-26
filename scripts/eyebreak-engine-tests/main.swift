// Standalone test harness for EyeBreakEngine (no XCTest target exists yet).
// Run: scripts/eyebreak-engine-tests/run.sh
import Foundation

var failures = 0
func check(_ cond: Bool, _ name: String, line: Int = #line) {
    if cond { print("PASS \(name)") } else { failures += 1; print("FAIL \(name) (line \(line))") }
}

let t0 = Date(timeIntervalSince1970: 1_000_000)
func input(_ t: TimeInterval, idle: TimeInterval = 0, suspended: Bool = false, deferred: Bool = false) -> EyeBreakInputs {
    EyeBreakInputs(now: t0.addingTimeInterval(t), idleSeconds: idle, isSuspended: suspended, isDeferred: deferred)
}
/// Ticks every `step` seconds from `from` to `to` inclusive.
func run(_ e: inout EyeBreakEngine, from: TimeInterval, to: TimeInterval, step: TimeInterval = 5,
         idle: TimeInterval = 0, suspended: Bool = false, deferred: Bool = false) {
    var t = from
    while t <= to { e.tick(input(t, idle: idle, suspended: suspended, deferred: deferred)); t += step }
}
let cfg = EyeBreakConfig() // 20 min / 20 s / 5 min / 5 min

// AC-14.1: prompt exactly when 20 min of active use is reached.
do {
    var e = EyeBreakEngine(config: cfg)
    run(&e, from: 0, to: 1195)
    check(e.phase == .counting, "AC-14.1 not yet due at 19:55")
    run(&e, from: 1200, to: 1200)
    check(e.phase == .prompting(endsAt: t0.addingTimeInterval(1220)), "AC-14.1 prompts at 20:00 with 20 s countdown")
}
// AC-14.6: countdown ends -> auto close, new 20 min starts.
do {
    var e = EyeBreakEngine(config: cfg)
    run(&e, from: 0, to: 1200)
    run(&e, from: 1205, to: 1219)
    check({ if case .prompting = e.phase { return true } else { return false } }(), "AC-14.6 still prompting at 19 s")
    run(&e, from: 1220, to: 1220)
    check(e.phase == .counting && e.activeSeconds == 0, "AC-14.6 auto-dismiss resets counter")
    run(&e, from: 1225, to: 1220 + 1195)
    check(e.phase == .counting, "AC-14.6 next reminder not before another 20 min")
    run(&e, from: 1220 + 1200, to: 1220 + 1200)
    check({ if case .prompting = e.phase { return true } else { return false } }(), "AC-14.6 next reminder after another 20 min")
}
// AC-14.2: skip.
do {
    var e = EyeBreakEngine(config: cfg)
    run(&e, from: 0, to: 1200)
    e.skip()
    check(e.phase == .counting && e.activeSeconds == 0, "AC-14.2 skip resets")
    run(&e, from: 1205, to: 1200 + 1195)
    check(e.phase == .counting, "AC-14.2 no reminder before 20 min after skip")
}
// AC-14.3: snooze 5 min then re-prompt.
do {
    var e = EyeBreakEngine(config: cfg)
    run(&e, from: 0, to: 1200)
    e.snooze(now: t0.addingTimeInterval(1202))
    check(e.phase == .snoozed(until: t0.addingTimeInterval(1502)), "AC-14.3 snoozed 5 min")
    run(&e, from: 1205, to: 1500)
    check(e.phase == .snoozed(until: t0.addingTimeInterval(1502)), "AC-14.3 silent during snooze")
    run(&e, from: 1505, to: 1505)
    check({ if case .prompting = e.phase { return true } else { return false } }(), "AC-14.3 repeats after 5 min")
    var c = EyeBreakEngine(config: cfg)
    c.snooze(now: t0)
    check(c.phase == .counting, "snooze outside a prompt is ignored")
}
// AC-14.4: idle >= 5 min resets; just under does not.
do {
    var e = EyeBreakEngine(config: cfg)
    run(&e, from: 0, to: 600)
    run(&e, from: 605, to: 605, idle: 299)
    check(e.activeSeconds > 600, "AC-14.4 idle 299 s does not reset")
    run(&e, from: 610, to: 610, idle: 300)
    check(e.activeSeconds == 0, "AC-14.4 idle 300 s resets")
    run(&e, from: 615, to: 610 + 1195)
    check(e.phase == .counting, "AC-14.4 full interval needed after idle reset")
}
// AC-14.4: lock / sleep resets and dismisses an on-screen prompt.
do {
    var e = EyeBreakEngine(config: cfg)
    run(&e, from: 0, to: 1200)
    run(&e, from: 1205, to: 1205, suspended: true)
    check(e.phase == .counting && e.activeSeconds == 0, "AC-14.4 lock dismisses prompt and resets")
    var s = EyeBreakEngine(config: cfg)
    run(&s, from: 0, to: 900)
    run(&s, from: 905, to: 905, suspended: true)
    check(s.activeSeconds == 0, "AC-14.4 sleep/lock resets mid-interval")
}
// AC-14.5: deferred -> held, fires once the deferral clears.
do {
    var e = EyeBreakEngine(config: cfg)
    run(&e, from: 0, to: 1195)
    run(&e, from: 1200, to: 1500, deferred: true)
    check(e.phase == .counting, "AC-14.5 no prompt while deferred")
    run(&e, from: 1505, to: 1505)
    check({ if case .prompting = e.phase { return true } else { return false } }(), "AC-14.5 prompts after deferral clears")
    var n = EyeBreakEngine(config: cfg)
    run(&n, from: 0, to: 1200)
    n.snooze(now: t0.addingTimeInterval(1200))
    run(&n, from: 1505, to: 1600, deferred: true)
    check({ if case .snoozed = n.phase { return true } else { return false } }(), "AC-14.5 snooze expiry also waits while deferred")
}
// Robustness: a huge gap between ticks (missed sleep) is not counted as use.
do {
    var e = EyeBreakEngine(config: cfg)
    run(&e, from: 0, to: 10)
    e.tick(input(10 + 4 * 3600))
    check(e.phase == .counting && e.activeSeconds <= 15, "tick gap > 30 s not counted as active use")
}
// BR-14.1: durations adjustable.
do {
    var e = EyeBreakEngine(config: EyeBreakConfig(interval: 30, breakDuration: 5, snoozeDuration: 10, idleReset: 20))
    run(&e, from: 0, to: 30, step: 1)
    check(e.phase == .prompting(endsAt: t0.addingTimeInterval(35)), "BR-14.1 custom interval/break length")
}
// tick() reports change only on phase transitions.
do {
    var e = EyeBreakEngine(config: cfg)
    check(e.tick(input(0)) == false, "tick returns false when nothing visible changed")
    run(&e, from: 5, to: 1195)
    check(e.tick(input(1200)) == true, "tick returns true on counting -> prompting")
}
print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
