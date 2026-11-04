//
//  EdgeGlowPolicyTests.swift
//  umbarTests
//
//  The edge glow: which signal changes fire a pulse, what glows when, the
//  shape of the breath and the flashes over time, the audio-reactive glow
//  (fed fake levels; nothing is captured or played) and the colours.
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
                         pulse: EdgeGlowEvent? = nil, audio: Bool = false, audioLive: Bool = false) -> EdgeGlowContext {
        EdgeGlowContext(enabled: enabled, style: style, reduceMotion: reduceMotion, isOpen: isOpen,
                        islandHeight: islandHeight, musicPlaying: music, pulse: pulse,
                        audioReactive: audio, audioLive: audioLive)
    }

    @Test func soundDrivesTheMusicGlowOnlyWhileLevelsArrive() {
        #expect(EdgeGlowPolicy.state(context(music: true, audio: true, audioLive: true))
                == EdgeGlowState(tint: .album, animation: .audio))
        // No permission, the stub, silence: the breath, as before.
        #expect(EdgeGlowPolicy.state(context(music: true, audio: true))?.animation == .breathing)
        // Levels from a capture the setting no longer wants are ignored.
        #expect(EdgeGlowPolicy.state(context(music: true, audioLive: true))?.animation == .breathing)
        // An event still wins.
        #expect(EdgeGlowPolicy.state(context(music: true, pulse: .camera, audio: true, audioLive: true))?.animation == .pulse)
    }

    @Test func reduceMotionNeverReactsToSound() {
        #expect(EdgeGlowPolicy.state(context(reduceMotion: true, music: true, audio: true, audioLive: true))?.animation == .steady)
        #expect(!EdgeGlowPolicy.capturesAudio(context(reduceMotion: true, music: true, audio: true)))
    }

    @Test func captureRunsOnlyWhenTheGlowCouldUseIt() {
        #expect(EdgeGlowPolicy.capturesAudio(context(music: true, audio: true)))
        #expect(!EdgeGlowPolicy.capturesAudio(context(music: true)), "off by default")
        #expect(!EdgeGlowPolicy.capturesAudio(context(audio: true)), "no music")
        #expect(!EdgeGlowPolicy.capturesAudio(context(enabled: false, music: true, audio: true)))
        #expect(!EdgeGlowPolicy.capturesAudio(context(style: .pulse, music: true, audio: true)))
        // Every screen's island must give the same answer.
        #expect(EdgeGlowPolicy.capturesAudio(context(isOpen: true, music: true, audio: true)))
        #expect(EdgeGlowPolicy.capturesAudio(context(islandHeight: 0, music: true, audio: true)))
    }

    /// The coordinator decides from the app-wide inputs alone; a screen's
    /// glow, given the same inputs, must agree with it whatever its panel,
    /// island or pulse.
    @Test func theOwnersAnswerMatchesEveryScreensAnswer() {
        for enabled in [false, true] {
            for style in EdgeGlowStyle.allCases {
                for audio in [false, true] {
                    for music in [false, true] {
                        for reduceMotion in [false, true] {
                            let owner = EdgeGlowPolicy.capturesAudio(
                                enabled: enabled, style: style, audioReactive: audio,
                                musicPlaying: music, reduceMotion: reduceMotion)
                            for (isOpen, height, pulse) in [(false, 37.0, nil), (true, 0.0, EdgeGlowEvent.camera)] {
                                let screen = EdgeGlowPolicy.capturesAudio(context(
                                    enabled: enabled, style: style, reduceMotion: reduceMotion, isOpen: isOpen,
                                    islandHeight: height, music: music, pulse: pulse, audio: audio))
                                #expect(screen == owner)
                            }
                        }
                    }
                }
            }
        }
        #expect(EdgeGlowPolicy.capturesAudio(enabled: true, style: .soft, audioReactive: true,
                                             musicPlaying: true, reduceMotion: false))
    }

    @Test func theAudioGlowHasNoClockOfItsOwn() {
        #expect(EdgeGlowPolicy.frameInterval(.audio) == nil)
        #expect(EdgeGlowPolicy.level(.audio, time: 0, pulseElapsed: 0, audio: 0.8) == 0.8)
        #expect(EdgeGlowPolicy.level(.audio, time: 0, pulseElapsed: 0, audio: 3) == 1)
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

@Suite("EdgeGlowAudio", .timeLimit(.minutes(1)))
struct EdgeGlowAudioTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 2_000)
    private let frame = 1.0 / 30

    /// Feeds `count` frames of the same sample from `start`; returns the time after.
    private func feed(_ f: inout EdgeGlowAudioFollower, level: Double, bass: Double, treble: Double = 0,
                      frames count: Int, from start: Date) -> Date {
        var now = start
        for _ in 0..<count {
            f.feed(level: level, bass: bass, treble: treble, now: now)
            now = now.addingTimeInterval(frame)
        }
        return now
    }

    @Test func silenceIsNotLiveAndSitsOnTheFloor() {
        var f = EdgeGlowAudioFollower()
        #expect(!f.isLive(now: t0))
        _ = feed(&f, level: 0, bass: 0, frames: 60, from: t0)
        #expect(!f.isLive(now: t0.addingTimeInterval(2)))
        #expect(f.brightness == EdgeGlowAudioFollower.floor)
        #expect(f.spread == 1)
    }

    @Test func louderIsBrighterAndStaysInRange() {
        var previous = -1.0
        for level in stride(from: 0.0, through: 1.0, by: 0.1) {
            var f = EdgeGlowAudioFollower()
            f.feed(level: level, bass: 0, treble: 0, now: t0)
            #expect(f.brightness > previous)
            #expect(f.brightness >= EdgeGlowAudioFollower.floor && f.brightness <= 1)
            previous = f.brightness
        }
        var wild = EdgeGlowAudioFollower()
        wild.feed(level: .nan, bass: 7, treble: -2, now: t0)
        #expect(wild.brightness.isFinite && wild.brightness <= 1 && wild.sparkle >= 0)
    }

    @Test func aBassHitPunchesThenDecays() {
        var f = EdgeGlowAudioFollower()
        var now = feed(&f, level: 0.5, bass: 0.1, frames: 60, from: t0)
        #expect(f.punch < 0.01, "a steady bass is not a hit")
        f.feed(level: 0.6, bass: 0.7, treble: 0, now: now)
        #expect(f.punch > 0.5)
        #expect(f.spread > 1 && f.spread <= 1 + EdgeGlowAudioFollower.maxSpread)
        let peak = f.punch
        now = feed(&f, level: 0.5, bass: 0.1, frames: 15, from: now.addingTimeInterval(frame))
        #expect(f.punch < peak * 0.2, "gone within half a second")
    }

    @Test func aHeldBassStopsPunching() {
        var f = EdgeGlowAudioFollower()
        _ = feed(&f, level: 0.6, bass: 0.8, frames: 90, from: t0)
        #expect(f.punch < 0.05)
    }

    @Test func soundGoesLiveAndSilenceHandsBack() {
        var f = EdgeGlowAudioFollower()
        let end = feed(&f, level: 0.4, bass: 0.2, frames: 3, from: t0)
        #expect(f.isLive(now: end))
        #expect(f.isLive(now: end.addingTimeInterval(EdgeGlowAudioFollower.silenceHold / 2)))
        // Samples that stop arriving count as silence too.
        #expect(!f.isLive(now: end.addingTimeInterval(EdgeGlowAudioFollower.silenceHold)))
    }

    @Test func trebleLiftsTowardWhiteAFewTenths() {
        var f = EdgeGlowAudioFollower()
        f.feed(level: 0.5, bass: 0, treble: 1, now: t0)
        #expect(f.sparkle == EdgeGlowAudioFollower.maxSparkle)
        let red = EdgeGlowRGB(red: 1, green: 0, blue: 0)
        let lifted = EdgeGlowColor.sparkle(red, amount: f.sparkle)
        #expect(lifted.red == 1 && abs(lifted.green - 0.3) < 1e-9 && lifted.green == lifted.blue)
        #expect(EdgeGlowColor.sparkle(red, amount: 0) == red)
    }

    @Test func breathAndAudioCrossfadeWithoutADip() {
        let breath = EdgeGlowState(tint: .album, animation: .breathing)
        let reacting = EdgeGlowState(tint: .album, animation: .audio)
        var e = EdgeGlowEnvelope()
        e.update(to: breath, now: t0, reduceMotion: false)
        let switchAt = t0.addingTimeInterval(3)
        let before = e.level(at: switchAt, pulseElapsed: 0)
        e.update(to: reacting, now: switchAt, reduceMotion: false, audio: 0.9)
        #expect(abs(e.level(at: switchAt, pulseElapsed: 0, audio: 0.9) - before) < 1e-9, "starts where the breath was")
        #expect(abs(e.level(at: switchAt.addingTimeInterval(EdgeGlowEnvelope.fade), pulseElapsed: 0, audio: 0.9) - 0.9) < 1e-9)
        #expect(e.frameInterval == nil, "samples draw it")

        let back = switchAt.addingTimeInterval(5)
        e.update(to: breath, now: back, reduceMotion: false, audio: 0.4)
        #expect(abs(e.level(at: back, pulseElapsed: 0) - 0.4) < 1e-9)
        #expect(e.frameInterval != nil)
    }

    @Test func theAudioGlowFadesOutOnAClock() {
        var e = EdgeGlowEnvelope()
        e.update(to: EdgeGlowState(tint: .album, animation: .audio), now: t0, reduceMotion: false, audio: 0.8)
        #expect(e.frameInterval == nil)
        let off = t0.addingTimeInterval(2)
        e.update(to: nil, now: off, reduceMotion: false, audio: 0.8)
        #expect(e.frameInterval == EdgeGlowPolicy.audioFadeInterval, "the music stopped, so no samples will draw the fade")
        e.settle(now: off.addingTimeInterval(EdgeGlowEnvelope.fade))
        #expect(e.frameInterval == nil)
    }
}

@Suite("EdgeGlowColor", .timeLimit(.minutes(1)))
struct EdgeGlowColorTests {
    @Test func hexRoundTrips() {
        let c = EdgeGlowColor.rgb(hex: "#30D158")
        #expect(c == EdgeGlowRGB(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255))
        #expect(c.map(EdgeGlowColor.hex) == "#30D158")
        #expect(EdgeGlowColor.rgb(hex: "ff9f0a") == EdgeGlowColor.rgb(hex: "#FF9F0A"))
        #expect(EdgeGlowColor.hex(EdgeGlowRGB(red: 2, green: -1, blue: .nan)) == "#FF0000")
    }

    @Test(arguments: ["", "#", "#12345", "#1234567", "#GGGGGG", "rgb(1,2,3)", "#+12345"])
    func badHexIsRejected(_ hex: String) {
        #expect(EdgeGlowColor.rgb(hex: hex) == nil)
    }

    @Test func cycleIsInGamutContinuousAndPeriodic() {
        let period = EdgeGlowColor.cyclePeriod
        var previous = EdgeGlowColor.cycle(time: 0)
        for i in 1...300 {
            let c = EdgeGlowColor.cycle(time: Double(i) * period / 300)
            for v in [c.red, c.green, c.blue] { #expect(v >= 0 && v <= 1) }
            let step = max(abs(c.red - previous.red), abs(c.green - previous.green), abs(c.blue - previous.blue))
            #expect(step < 0.05, "no jump between frames")
            previous = c
        }
        let a = EdgeGlowColor.cycle(time: 7), b = EdgeGlowColor.cycle(time: 7 + period)
        #expect(abs(a.red - b.red) < 1e-9 && abs(a.green - b.green) < 1e-9 && abs(a.blue - b.blue) < 1e-9)
        #expect(EdgeGlowColor.cycle(time: -3).red.isFinite)
        #expect(period >= 20, "a mood, not a signal")
    }

    @Test func cycleKeepsAnEvenBrightness() {
        // Rec. 709 luma on the sRGB values, as albumGlow uses: an HSL wheel
        // swings ~0.07 (blue) to ~0.93 (yellow); the cycle stays near one value.
        let lumas = (0..<36).map { i -> Double in
            let c = EdgeGlowColor.cycle(time: Double(i) * EdgeGlowColor.cyclePeriod / 36)
            return 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
        }
        #expect(lumas.max()! - lumas.min()! < 0.25)
        #expect(lumas.min()! >= 0.45, "as bright as a lifted album colour")
    }

    @Test func outOfGamutKeepsLightnessByDroppingChroma() {
        // Far outside sRGB: it must still land inside, grey at worst.
        let c = EdgeGlowColor.oklch(lightness: 0.9, chroma: 0.5, hue: 264)
        for v in [c.red, c.green, c.blue] { #expect(v >= 0 && v <= 1) }
        #expect(c.blue > c.red, "hue kept")
        let grey = EdgeGlowColor.oklch(lightness: 0.5, chroma: 0, hue: 0)
        #expect(abs(grey.red - grey.green) < 1e-6 && abs(grey.green - grey.blue) < 1e-6)
    }
}
