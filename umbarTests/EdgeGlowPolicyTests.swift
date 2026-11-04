//
//  EdgeGlowPolicyTests.swift
//  umbarTests
//
//  The edge glow: which signal changes fire a pulse, what glows when, and
//  the shape of the breath and the flashes over time.
//

import Foundation
import Testing

@Suite("EdgeGlowTrigger", .timeLimit(.minutes(1)))
struct EdgeGlowTriggerTests {
    @Test func risingEdgesFireAndLevelsDoNot() {
        var on = EdgeGlowSignals.idle
        on.camera = true
        #expect(EdgeGlowTrigger.event(from: .idle, to: on) == .camera)
        // Still on, a long call: no new flash.
        #expect(EdgeGlowTrigger.event(from: on, to: on) == nil)
        // Turning off is not an event.
        #expect(EdgeGlowTrigger.event(from: on, to: .idle) == nil)
    }

    @Test func eachSignalMapsToItsEvent() {
        let cases: [(WritableKeyPath<EdgeGlowSignals, Bool>, EdgeGlowEvent)] = [
            (\.timerAlerting, .timerFinished),
            (\.eyeBreakPrompting, .eyeBreak),
            (\.camera, .camera),
            (\.microphone, .microphone),
            (\.hudShowing, .hud),
        ]
        for (key, event) in cases {
            var s = EdgeGlowSignals.idle
            s[keyPath: key] = true
            #expect(EdgeGlowTrigger.event(from: .idle, to: s) == event)
        }
    }

    @Test func simultaneousEdgesPickTheMostImportant() {
        var s = EdgeGlowSignals.idle
        s.hudShowing = true
        s.timerAlerting = true
        s.microphone = true
        #expect(EdgeGlowTrigger.event(from: .idle, to: s) == .microphone)
        s.camera = true
        #expect(EdgeGlowTrigger.event(from: .idle, to: s) == .camera)
    }

    @Test func aLowerEventNeverCutsAHigherOne() {
        #expect(EdgeGlowTrigger.replaces(nil, with: .hud))
        #expect(!EdgeGlowTrigger.replaces(.camera, with: .hud))
        #expect(EdgeGlowTrigger.replaces(.hud, with: .camera))
        // The same event again restarts its flash.
        #expect(EdgeGlowTrigger.replaces(.hud, with: .hud))
    }

    @Test func privacyTintsFollowTheMacOSConvention() {
        #expect(EdgeGlowEvent.camera.tint == .camera)
        #expect(EdgeGlowEvent.microphone.tint == .microphone)
        #expect(EdgeGlowEvent.timerFinished.tint == .timer)
    }
}

@Suite("EdgeGlowPolicy", .timeLimit(.minutes(1)))
struct EdgeGlowPolicyTests {
    private func context(enabled: Bool = true, style: EdgeGlowStyle = .soft, reduceMotion: Bool = false,
                         isOpen: Bool = false, islandHeight: Double = 37, music: Bool = false,
                         pulse: EdgeGlowEvent? = nil) -> EdgeGlowContext {
        EdgeGlowContext(enabled: enabled, style: style, reduceMotion: reduceMotion, isOpen: isOpen,
                        islandHeight: islandHeight, musicPlaying: music, pulse: pulse)
    }

    @Test func idleIslandDrawsNothing() {
        #expect(EdgeGlowPolicy.state(context()) == nil)
    }

    @Test func musicBreathesInTheAlbumColour() {
        #expect(EdgeGlowPolicy.state(context(music: true)) == EdgeGlowState(tint: .album, animation: .breathing))
        #expect(EdgeGlowPolicy.state(context(style: .neon, music: true)) == EdgeGlowState(tint: .album, animation: .breathing))
    }

    @Test func pulseStyleIgnoresMusicButNotEvents() {
        #expect(EdgeGlowPolicy.state(context(style: .pulse, music: true)) == nil)
        #expect(EdgeGlowPolicy.state(context(style: .pulse, music: true, pulse: .timerFinished))
                == EdgeGlowState(tint: .timer, animation: .pulse))
    }

    @Test func anEventWinsOverTheBreath() {
        #expect(EdgeGlowPolicy.state(context(music: true, pulse: .camera)) == EdgeGlowState(tint: .camera, animation: .pulse))
    }

    @Test(arguments: [
        (true, 37.0, false),   // open panel
        (false, 0.0, false),   // hidden island (fullscreen)
        (false, 37.0, true),   // turned off
    ])
    func nothingGlowsWhen(_ isOpen: Bool, _ height: Double, _ off: Bool) {
        let c = context(enabled: !off, isOpen: isOpen, islandHeight: height, music: true, pulse: .camera)
        #expect(EdgeGlowPolicy.state(c) == nil)
    }

    @Test func reduceMotionHoldsStill() {
        #expect(EdgeGlowPolicy.state(context(reduceMotion: true, music: true))?.animation == .steady)
        #expect(EdgeGlowPolicy.state(context(reduceMotion: true, pulse: .eyeBreak))?.animation == .steady)
        #expect(EdgeGlowPolicy.frameInterval(.steady) == nil)
    }

    @Test func clockRunsOnlyWhileSomethingMoves() {
        #expect(EdgeGlowPolicy.frameInterval(.breathing) != nil)
        #expect(EdgeGlowPolicy.frameInterval(.pulse) != nil)
        #expect(EdgeGlowEnvelope().frameInterval == nil)
    }

    @Test func pulseFlashesTwiceThenGoesDark() {
        let d = EdgeGlowPolicy.pulseDuration
        #expect(EdgeGlowPolicy.pulseLevel(elapsed: 0) == 0)
        #expect(abs(EdgeGlowPolicy.pulseLevel(elapsed: d / 4) - 1) < 1e-9)
        #expect(EdgeGlowPolicy.pulseLevel(elapsed: d / 2) < 1e-9)
        #expect(abs(EdgeGlowPolicy.pulseLevel(elapsed: 3 * d / 4) - EdgeGlowPolicy.secondFlash) < 1e-9)
        #expect(EdgeGlowPolicy.pulseLevel(elapsed: d) == 0)
        #expect(EdgeGlowPolicy.pulseLevel(elapsed: -0.1) == 0)
        #expect(d <= 2, "a pulse is 1–2 flashes, not a notification")
    }

    @Test func breathStaysInRangeAndIsContinuous() {
        var previous = EdgeGlowPolicy.breathLevel(time: 0)
        #expect(abs(previous - EdgeGlowPolicy.breathFloor) < 1e-9)
        for i in 1...700 {
            let level = EdgeGlowPolicy.breathLevel(time: Double(i) * 0.01)
            #expect(level >= EdgeGlowPolicy.breathFloor - 1e-9 && level <= 1 + 1e-9)
            #expect(abs(level - previous) < 0.01)
            previous = level
        }
        #expect(abs(EdgeGlowPolicy.breathLevel(time: EdgeGlowPolicy.breathPeriod / 2) - 1) < 1e-9)
        #expect(EdgeGlowPolicy.breathPeriod >= 5, "very slow, so it never reads as an alert")
    }

    @Test func darkCoversAreLiftedBrightOnesKept() {
        let black = EdgeGlowPolicy.albumGlow(red: 0, green: 0, blue: 0)
        let luma = 0.2126 * black.red + 0.7152 * black.green + 0.0722 * black.blue
        #expect(abs(luma - 0.45) < 1e-9)

        let navy = EdgeGlowPolicy.albumGlow(red: 0.05, green: 0.05, blue: 0.3)
        #expect(navy.blue > navy.red, "hue is kept")

        let yellow = EdgeGlowPolicy.albumGlow(red: 1, green: 0.9, blue: 0.2)
        #expect(yellow.red == 1 && yellow.green == 0.9 && yellow.blue == 0.2)

        let bad = EdgeGlowPolicy.albumGlow(red: .nan, green: 2, blue: -1)
        #expect(bad.red.isFinite && bad.green <= 1 && bad.blue >= 0)
    }
}

@Suite("EdgeGlowEnvelope", .timeLimit(.minutes(1)))
struct EdgeGlowEnvelopeTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private let breath = EdgeGlowState(tint: .album, animation: .breathing)

    @Test func breathEasesInFromDark() {
        var e = EdgeGlowEnvelope()
        e.update(to: breath, now: t0, reduceMotion: false)
        #expect(e.level(at: t0, pulseElapsed: 0) == 0)
        let later = t0.addingTimeInterval(EdgeGlowEnvelope.fade)
        #expect(abs(e.level(at: later, pulseElapsed: 0) - EdgeGlowPolicy.breathLevel(time: later.timeIntervalSinceReferenceDate)) < 1e-9)
    }

    @Test func goingOffFadesOutThenStopsTheClock() {
        var e = EdgeGlowEnvelope()
        e.update(to: breath, now: t0, reduceMotion: false)
        let off = t0.addingTimeInterval(5)
        e.update(to: nil, now: off, reduceMotion: false)
        #expect(e.state == breath, "kept through the fade")
        #expect(e.level(at: off.addingTimeInterval(EdgeGlowEnvelope.fade / 2), pulseElapsed: 0) > 0)
        #expect(e.level(at: off.addingTimeInterval(EdgeGlowEnvelope.fade), pulseElapsed: 0) == 0)
        e.settle(now: off.addingTimeInterval(EdgeGlowEnvelope.fade / 2))
        #expect(e.frameInterval != nil, "too early to stop")
        e.settle(now: off.addingTimeInterval(EdgeGlowEnvelope.fade))
        #expect(e.state == nil)
        #expect(e.frameInterval == nil)
    }

    @Test func comingBackDuringTheFadeCancelsIt() {
        var e = EdgeGlowEnvelope()
        e.update(to: breath, now: t0, reduceMotion: false)
        e.update(to: nil, now: t0.addingTimeInterval(1), reduceMotion: false)
        e.update(to: breath, now: t0.addingTimeInterval(1.1), reduceMotion: false)
        #expect(e.releasedAt == nil)
        e.settle(now: t0.addingTimeInterval(10))
        #expect(e.state == breath)
    }

    @Test func reduceMotionCutsWithoutAFade() {
        var e = EdgeGlowEnvelope()
        let still = EdgeGlowState(tint: .album, animation: .steady)
        e.update(to: still, now: t0, reduceMotion: true)
        #expect(e.level(at: t0, pulseElapsed: 0) == EdgeGlowPolicy.steadyLevel)
        #expect(e.frameInterval == nil)
        e.update(to: nil, now: t0.addingTimeInterval(1), reduceMotion: true)
        #expect(e.state == nil)
    }

    @Test func pulseIsNotEasedIn() {
        var e = EdgeGlowEnvelope()
        e.update(to: EdgeGlowState(tint: .camera, animation: .pulse), now: t0, reduceMotion: false)
        let peak = EdgeGlowPolicy.pulseDuration / 4
        #expect(abs(e.level(at: t0.addingTimeInterval(peak), pulseElapsed: peak) - 1) < 1e-9)
    }
}
