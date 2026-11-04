//
//  ScreenEdgeGlowModel.swift
//  boringNotch
//
//  The screen edge glow's one source of truth, for every screen at once.
//  It follows the same signals as the notch's EdgeGlow modifier (timer,
//  eye break, camera and microphone, HUD, music, the audio levels) through
//  the same EdgeGlowTrigger, EdgeGlowEnvelope and EdgeGlowAudioFollower, so
//  the rim flashes and breathes with the notch in the same colour.
//
//  Why its own copy and not the modifier's: the modifier lives inside a
//  notch window, one per screen, and goes away with it; the rim must know
//  whether anything glows before any window exists, to keep the windows
//  ordered out while idle.
//

import AppKit
import Combine
import Defaults
import SwiftUI

/// One frame of the rim, values only, so the renderer can draw fixtures.
struct ScreenEdgeGlowFrame: Equatable {
    var color: Color
    /// 0…1, before the user's intensity.
    var level: Double
    /// How far the light has run from the notch, 0…1 of the band.
    var reach: Double
    var glint: Glint?
    /// A bass hit widens the band: EdgeGlowAudioFollower.spread.
    var spread: Double = 1

    struct Glint: Equatable {
        var position: Double
        var strength: Double
        var color: Color
    }
}

@MainActor
final class ScreenEdgeGlowModel: ObservableObject {
    static let shared = ScreenEdgeGlowModel()

    @Published private(set) var envelope = EdgeGlowEnvelope()
    /// Published so a reacting rim is redrawn by each audio sample.
    @Published private(set) var audio = EdgeGlowAudioFollower()
    private(set) var pulseStart = Date.distantPast

    private var signals = EdgeGlowSignals.idle
    private var pulse: EdgeGlowEvent?
    private var musicPlaying = false
    private var album = EdgeGlowRGB(red: 1, green: 1, blue: 1)
    private var audioLive = false
    private var capturesAudio = false
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var pulseEnd: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var silenceWatch: Task<Void, Never>?
    private var observations: [AnyCancellable] = []

    private init() {}

    var isReduceMotion: Bool { reduceMotion }

    /// Follows the inputs for the life of the app. Call once at launch.
    func start() {
        guard observations.isEmpty else { return }
        let keys: [Defaults._AnyKey] = [.edgeGlowEnabled, .edgeGlowStyle, .edgeGlowAudioReactive, .screenEdgeGlowEnabled]
        observe(Defaults.publisher(keys: keys, options: [.initial])) { $0.retarget() }
        observe(NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)) { model in
            model.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            model.retarget()
        }
        observe(EdgeGlowAudioCoordinator.shared.$capturesAudio) { model in
            model.capturesAudio = EdgeGlowAudioCoordinator.shared.capturesAudio
            if !model.capturesAudio { model.setAudioLive(false) }
        }
        // Delivered on the next run-loop turn, so `bass` and `treble`, set
        // in the same tick as `level`, are read as one sample.
        observations.append(AudioLevelMonitor.shared.$level.receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.sample() } })
        observe(TimerService.shared.$isAlerting) { model in
            let on = TimerService.shared.isAlerting
            model.update { $0.timerAlerting = on }
        }
        observe(EyeBreakManager.shared.$phase) { model in
            let prompting = if case .prompting = EyeBreakManager.shared.phase { true } else { false }
            model.update { $0.eyeBreakPrompting = prompting }
        }
        observe(PrivacyIndicatorMonitor.shared.$usage) { model in
            let usage = PrivacyIndicatorMonitor.shared.usage
            model.update { $0.camera = usage.camera; $0.microphone = usage.microphone }
        }
        observe(BoringViewCoordinator.shared.$sneakPeek) { model in
            let peek = BoringViewCoordinator.shared.sneakPeek
            model.update { $0.hudShowing = peek.show && EdgeGlow.hudTypes.contains(peek.type) }
        }
        observe(MusicManager.shared.$isPlaying.removeDuplicates()) { model in
            model.musicPlaying = MusicManager.shared.isPlaying
            model.retarget()
        }
        observe(MusicManager.shared.$avgColor) { model in
            model.album = EdgeGlow.albumTint(MusicManager.shared.avgColor)
        }
    }

    /// `@Published` emits before the property is set, so each handler reads
    /// the source again on the next main-queue turn instead of the value.
    private func observe<P: Publisher>(_ publisher: P, _ handle: @escaping @MainActor (ScreenEdgeGlowModel) -> Void)
    where P.Failure == Never {
        observations.append(publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { if let self { handle(self) } } })
    }

    private var context: EdgeGlowContext {
        EdgeGlowContext(
            enabled: Defaults[.edgeGlowEnabled], style: Defaults[.edgeGlowStyle], reduceMotion: reduceMotion,
            isOpen: false, islandHeight: 1, musicPlaying: musicPlaying, pulse: pulse,
            audioReactive: Defaults[.edgeGlowAudioReactive], audioLive: audioLive)
    }

    private func retarget() {
        let target = ScreenEdgeGlowPolicy.state(context, screenEdgeEnabled: Defaults[.screenEdgeGlowEnabled])
        envelope.update(to: target, now: Date(), reduceMotion: reduceMotion, audio: audio.brightness)
        settleTask?.cancel()
        guard envelope.releasedAt != nil else { return }
        // Ends the fade-out, which orders the windows out.
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(EdgeGlowEnvelope.fade))
            guard !Task.isCancelled else { return }
            envelope.settle(now: Date())
        }
    }

    private func update(_ change: (inout EdgeGlowSignals) -> Void) {
        var next = signals
        change(&next)
        guard next != signals else { return }
        let event = EdgeGlowTrigger.event(from: signals, to: next)
        signals = next
        if let event, EdgeGlowTrigger.replaces(pulse, with: event) { start(event) }
    }

    private func start(_ event: EdgeGlowEvent) {
        pulse = event
        pulseStart = Date()
        retarget()
        pulseEnd?.cancel()
        pulseEnd = Task { @MainActor in
            try? await Task.sleep(for: .seconds(EdgeGlowPolicy.pulseDuration))
            guard !Task.isCancelled else { return }
            pulse = nil
            retarget()
        }
    }

    /// One audio sample; ignored unless the capture is meant to run and the
    /// rim is on, so the subscription costs nothing otherwise.
    private func sample() {
        guard capturesAudio, envelope.state != nil else { return }
        let monitor = AudioLevelMonitor.shared
        let now = Date()
        audio.feed(level: Double(monitor.level), bass: Double(monitor.bass), treble: Double(monitor.treble), now: now)
        setAudioLive(audio.isLive(now: now))
        if audioLive, silenceWatch == nil { watchForSilence() }
    }

    private func setAudioLive(_ live: Bool) {
        guard live != audioLive else { return }
        audioLive = live
        retarget()
    }

    /// Samples may stop rather than turn to zeros; this hands the rim back
    /// to the breath either way.
    private func watchForSilence() {
        silenceWatch = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(EdgeGlowAudioFollower.silenceHold / 3))
                if !audio.isLive(now: Date()) {
                    setAudioLive(false)
                    break
                }
            }
            silenceWatch = nil
        }
    }

    // MARK: Drawing

    /// What the rim shows at `now`, nil when nothing.
    func frame(at now: Date) -> ScreenEdgeGlowFrame? {
        Self.frame(envelope: envelope, audio: audio, pulseStart: pulseStart, album: album, at: now)
    }

    /// The same, values in: the renderer drives it with fixtures.
    static func frame(envelope: EdgeGlowEnvelope, audio: EdgeGlowAudioFollower, pulseStart: Date,
                      album: EdgeGlowRGB, at now: Date) -> ScreenEdgeGlowFrame? {
        guard let state = envelope.state else { return nil }
        let reacting = state.animation == .audio
        let pulseElapsed = now.timeIntervalSince(pulseStart)
        let level = envelope.level(at: now, pulseElapsed: pulseElapsed, audio: audio.brightness)
        let elapsed = state.animation == .pulse ? pulseElapsed : now.timeIntervalSince(envelope.since)
        let base = rgb(state.tint, at: now, album: album)
        var glint: ScreenEdgeGlowFrame.Glint?
        if let g = ScreenEdgeGlowPolicy.glint(state.animation, time: now.timeIntervalSinceReferenceDate, elapsed: elapsed) {
            // Reacting, the treble carries the glint: hats make it flare.
            let treble = reacting ? audio.sparkle / EdgeGlowAudioFollower.maxSparkle : 0.5
            glint = .init(position: g.position, strength: g.strength * (0.4 + 0.6 * treble),
                          color: EdgeGlowColor.sparkle(base, amount: 0.45).color)
        }
        return ScreenEdgeGlowFrame(
            color: EdgeGlowColor.sparkle(base, amount: reacting ? audio.sparkle : 0).color,
            level: level,
            reach: ScreenEdgeGlowPolicy.reach(state.animation, elapsed: elapsed),
            glint: glint,
            spread: reacting ? audio.spread : 1)
    }

    /// The notch glow's colour for `tint`, from the same settings.
    static func rgb(_ tint: EdgeGlowTint, at now: Date, album: EdgeGlowRGB) -> EdgeGlowRGB {
        let event: EdgeGlowEventColor
        switch tint {
        case .album:
            switch Defaults[.edgeGlowColorMode] {
            case .album: return album
            case .fixed: return EdgeGlowColor.rgb(hex: Defaults[.edgeGlowFixedColor]) ?? album
            case .cycle: return EdgeGlowColor.cycle(time: now.timeIntervalSinceReferenceDate)
            }
        case .timer: event = .timer
        case .eyeBreak: event = .eyeBreak
        case .camera: event = .camera
        case .microphone: event = .microphone
        case .hud: event = .hud
        }
        let fallback = EdgeGlowRGB(event.token) ?? EdgeGlowRGB(red: 1, green: 1, blue: 1)
        return Defaults[event.key].flatMap(EdgeGlowColor.rgb(hex:)) ?? fallback
    }
}
