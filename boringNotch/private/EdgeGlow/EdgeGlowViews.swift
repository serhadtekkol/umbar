//
//  EdgeGlowViews.swift
//  boringNotch
//
//  A light behind the closed island that spills out past its sides and
//  bottom edge (the top is under the hardware notch, so nothing is drawn
//  for it to be seen there). It breathes in the album's colour while music
//  plays and flashes twice for an event; EdgeGlowPolicy decides which.
//
//  Why a shadow of the island and not a shape of its own: the island is
//  not one shape. The time, network, privacy and Caffeinate ears are
//  separate views beside it, and an event's ear is where the eye should
//  go. A drawn halo followed only the island, left those ears dark and lit
//  the slivers between them. The coloured shadow of the composited island
//  is its exact silhouette, ears, live strip and HUD included.
//
//  Cost: the clock (TimelineView) runs only while the glow breathes,
//  flashes or fades, at 24 fps for the breath; idle, the shadow is clear
//  and nothing is scheduled. Reacting to sound, the clock is paused and
//  each audio sample (~30 Hz) draws the frame instead; with that setting
//  off the capture never starts and no sample arrives. Only the shadow's
//  colour and radii change per frame; the island's own views are not
//  rebuilt by it. A shadow takes no hits, and adds nothing for VoiceOver
//  (each event has its own ear or banner that says it in words).
//

import Combine
import Defaults
import SwiftUI

enum EdgeGlowTokens {
    /// "Time's up" is amber elsewhere (PageTokens.live).
    static let timer = PageTokens.live
    /// systemCyan, dark appearance: calm, and not a colour any other event uses.
    static let eyeBreak = Color(red: 0x64 / 255, green: 0xD2 / 255, blue: 0xFF / 255)
    /// systemGreen / systemOrange dark values, as PrivacyClosedEar's glyphs.
    static let camera = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let microphone = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
    /// Volume and brightness: neutral, they are the least important event.
    static let hud = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
}

/// The events whose colour the user can change, with their defaults.
/// Camera and microphone default to the macOS indicator colours.
enum EdgeGlowEventColor: CaseIterable, Identifiable {
    case timer, eyeBreak, camera, microphone, hud

    var id: Self { self }

    var key: Defaults.Key<String?> {
        switch self {
        case .timer: .edgeGlowTimerColor
        case .eyeBreak: .edgeGlowEyeBreakColor
        case .camera: .edgeGlowCameraColor
        case .microphone: .edgeGlowMicrophoneColor
        case .hud: .edgeGlowHUDColor
        }
    }

    var token: Color {
        switch self {
        case .timer: EdgeGlowTokens.timer
        case .eyeBreak: EdgeGlowTokens.eyeBreak
        case .camera: EdgeGlowTokens.camera
        case .microphone: EdgeGlowTokens.microphone
        case .hud: EdgeGlowTokens.hud
        }
    }

    var name: String {
        switch self {
        case .timer: String(localized: "edgeGlow.color.timer", defaultValue: "Timer finished")
        case .eyeBreak: String(localized: "edgeGlow.color.eyeBreak", defaultValue: "Eye break")
        case .camera: String(localized: "edgeGlow.color.camera", defaultValue: "Camera on")
        case .microphone: String(localized: "edgeGlow.color.microphone", defaultValue: "Microphone on")
        case .hud: String(localized: "edgeGlow.color.hud", defaultValue: "Volume and brightness")
        }
    }

    /// The stored colour, or the default when there is none (or it is unreadable).
    func color(_ hex: String?) -> Color {
        hex.flatMap(EdgeGlowColor.rgb(hex:)).map(\.color) ?? token
    }
}

extension EdgeGlowRGB {
    init?(_ color: Color) {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

/// Apply to the island after its ears, so the glow is their silhouette too.
struct EdgeGlow: ViewModifier {
    let isOpen: Bool
    let islandHeight: CGFloat

    @Default(.edgeGlowEnabled) private var enabled
    @Default(.edgeGlowStyle) private var style
    @Default(.edgeGlowIntensity) private var intensity
    @Default(.edgeGlowAudioReactive) private var audioReactive
    @Default(.edgeGlowColorMode) private var colorMode
    @Default(.edgeGlowFixedColor) private var fixedColor
    @Default(.edgeGlowTimerColor) private var timerColor
    @Default(.edgeGlowEyeBreakColor) private var eyeBreakColor
    @Default(.edgeGlowCameraColor) private var cameraColor
    @Default(.edgeGlowMicrophoneColor) private var microphoneColor
    @Default(.edgeGlowHUDColor) private var hudColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var signals = EdgeGlowSignals.idle
    @State private var pulse: EdgeGlowEvent?
    @State private var pulseStart = Date.distantPast
    @State private var pulseEnd: Task<Void, Never>?
    @State private var settleTask: Task<Void, Never>?
    @State private var musicPlaying = false
    @State private var album = EdgeGlowRGB(red: 1, green: 1, blue: 1)
    @State private var envelope = EdgeGlowEnvelope()
    @State private var audio = EdgeGlowAudioFollower()
    @State private var audioLive = false
    @State private var silenceWatch: Task<Void, Never>?
    /// Read, never set: EdgeGlowAudioCoordinator alone starts and stops the
    /// capture, so one screen's glow going away cannot stop another's.
    @State private var capturesAudio = false

    /// Delivered on the next run-loop turn, so `bass` and `treble`, set in
    /// the same tick as `level`, are read as one sample.
    @MainActor private static let audioSamples = AudioLevelMonitor.shared.$level.receive(on: RunLoop.main)

    private var context: EdgeGlowContext {
        EdgeGlowContext(
            enabled: enabled, style: style, reduceMotion: reduceMotion, isOpen: isOpen,
            islandHeight: Double(islandHeight), musicPlaying: musicPlaying, pulse: pulse,
            audioReactive: audioReactive, audioLive: audioLive)
    }

    private var target: EdgeGlowState? { EdgeGlowPolicy.state(context) }

    func body(content: Content) -> some View {
        let envelope = envelope
        let audio = audio
        let interval = envelope.frameInterval
        TimelineView(.animation(minimumInterval: interval ?? 1, paused: interval == nil)) { context in
            // Paused, the timeline's date is when it stopped; an audio frame
            // is drawn now.
            let now = interval == nil ? Date() : context.date
            let reacting = envelope.state?.animation == .audio
            let level = envelope.level(at: now, pulseElapsed: now.timeIntervalSince(pulseStart), audio: audio.brightness)
            content
                // One silhouette: without it each ear casts its own glow
                // over its neighbour.
                .compositingGroup()
                .modifier(EdgeGlowShadow(style: style,
                                         color: envelope.state.map { color($0.tint, at: now, sparkle: reacting ? audio.sparkle : 0) } ?? .clear,
                                         level: level * intensity,
                                         spread: reacting ? audio.spread : 1))
        }
        .onChange(of: target, initial: true) { _, new in retarget(new) }
        .onReceive(EdgeGlowAudioCoordinator.shared.$capturesAudio) { capturesAudio = $0 }
        .onChange(of: capturesAudio) { _, on in
            if !on { audioLive = false }
        }
        .onReceive(Self.audioSamples) { _ in sample() }
        .onReceive(TimerService.shared.$isAlerting) { on in update { $0.timerAlerting = on } }
        .onReceive(EyeBreakManager.shared.$phase) { phase in
            let prompting = if case .prompting = phase { true } else { false }
            update { $0.eyeBreakPrompting = prompting }
        }
        .onReceive(PrivacyIndicatorMonitor.shared.$usage) { usage in
            update { $0.camera = usage.camera; $0.microphone = usage.microphone }
        }
        .onReceive(BoringViewCoordinator.shared.$sneakPeek) { peek in
            update { $0.hudShowing = peek.show && Self.hudTypes.contains(peek.type) }
        }
        .onReceive(MusicManager.shared.$isPlaying) { musicPlaying = $0 }
        .onReceive(MusicManager.shared.$avgColor) { album = Self.albumTint($0) }
        .onDisappear {
            pulseEnd?.cancel()
            settleTask?.cancel()
            silenceWatch?.cancel()
        }
    }

    /// The system HUDs umbar replaces; music and battery peeks have their own island.
    static let hudTypes: Set<SneakContentType> = [.volume, .brightness, .backlight, .mic]

    private func retarget(_ new: EdgeGlowState?) {
        envelope.update(to: new, now: Date(), reduceMotion: reduceMotion, audio: audio.brightness)
        settleTask?.cancel()
        guard envelope.releasedAt != nil else { return }
        // Stops the clock once the fade-out is over.
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(EdgeGlowEnvelope.fade))
            guard !Task.isCancelled else { return }
            envelope.settle(now: Date())
        }
    }

    /// One audio sample. Ignored unless the capture is meant to be running,
    /// so the subscription costs nothing while the setting is off.
    private func sample() {
        guard capturesAudio else { return }
        let monitor = AudioLevelMonitor.shared
        let now = Date()
        audio.feed(level: Double(monitor.level), bass: Double(monitor.bass), treble: Double(monitor.treble), now: now)
        let live = audio.isLive(now: now)
        if live != audioLive { audioLive = live }
        if live, silenceWatch == nil { watchForSilence() }
    }

    /// Samples may stop coming rather than turn to zeros; this notices the
    /// silence either way and hands the glow back to the breath.
    private func watchForSilence() {
        silenceWatch = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(EdgeGlowAudioFollower.silenceHold / 3))
                if !audio.isLive(now: Date()) {
                    audioLive = false
                    break
                }
            }
            silenceWatch = nil
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
        pulseEnd?.cancel()
        pulseEnd = Task { @MainActor in
            try? await Task.sleep(for: .seconds(EdgeGlowPolicy.pulseDuration))
            guard !Task.isCancelled else { return }
            pulse = nil
        }
    }

    private func color(_ tint: EdgeGlowTint, at now: Date, sparkle: Double) -> Color {
        switch tint {
        case .album: EdgeGlowColor.sparkle(ambient(at: now), amount: sparkle).color
        case .timer: EdgeGlowEventColor.timer.color(timerColor)
        case .eyeBreak: EdgeGlowEventColor.eyeBreak.color(eyeBreakColor)
        case .camera: EdgeGlowEventColor.camera.color(cameraColor)
        case .microphone: EdgeGlowEventColor.microphone.color(microphoneColor)
        case .hud: EdgeGlowEventColor.hud.color(hudColor)
        }
    }

    /// The music glow's colour before the treble's lift.
    private func ambient(at now: Date) -> EdgeGlowRGB {
        switch colorMode {
        case .album: album
        case .fixed: EdgeGlowColor.rgb(hex: fixedColor) ?? album
        case .cycle: EdgeGlowColor.cycle(time: now.timeIntervalSinceReferenceDate)
        }
    }

    static func albumTint(_ color: NSColor) -> EdgeGlowRGB {
        guard let rgb = color.usingColorSpace(.sRGB) else { return EdgeGlowRGB(red: 0.96, green: 0.96, blue: 0.97) }
        let lifted = EdgeGlowPolicy.albumGlow(
            red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
        return EdgeGlowRGB(red: lifted.red, green: lifted.green, blue: lifted.blue)
    }
}

/// The glow itself, values in, so the renderer can draw each style beside
/// a fixture island. Layers of coloured shadow, innermost first; each one
/// shadows the ones before it, which is what builds a tight edge up into a
/// solid line.
struct EdgeGlowShadow: ViewModifier {
    let style: EdgeGlowStyle
    let color: Color
    /// 0…1.
    let level: Double
    /// Multiplies the radii: a bass hit widens the glow (EdgeGlowAudioFollower.spread).
    var spread: Double = 1

    func body(content: Content) -> some View {
        let layers = Self.layers(style)
        let k = CGFloat(spread)
        content
            .shadow(color: color.opacity(level * layers[0].opacity), radius: layers[0].radius * k)
            .shadow(color: color.opacity(level * layers[1].opacity), radius: layers[1].radius * k)
            .shadow(color: color.opacity(level * layers[2].opacity), radius: layers[2].radius * k)
    }

    /// Always three, so switching style never changes the view's structure.
    private static func layers(_ style: EdgeGlowStyle) -> [(opacity: Double, radius: CGFloat)] {
        switch style {
        // A wide halo: a soft edge and the light it throws.
        case .soft, .pulse: [(0.9, 5), (0.9, 18), (0, 0)]
        // A thin bright line (two tight passes) with a little bloom.
        case .neon: [(1, 1), (1, 1), (0.7, 7)]
        }
    }
}

// MARK: - Settings

/// Settings > Appearance > Edge glow.
struct EdgeGlowSettingsSection: View {
    @Default(.edgeGlowEnabled) private var enabled
    @Default(.edgeGlowStyle) private var style
    @Default(.edgeGlowIntensity) private var intensity
    @Default(.edgeGlowAudioReactive) private var audioReactive
    @Default(.edgeGlowColorMode) private var colorMode
    @Default(.edgeGlowFixedColor) private var fixedColor
    @Default(.screenEdgeGlowEnabled) private var screenEdgeEnabled
    @Default(.screenEdgeGlowThickness) private var screenEdgeThickness
    @Default(.screenEdgeGlowIntensity) private var screenEdgeIntensity
    @Default(.screenEdgeGlowSpread) private var screenEdgeSpread
    /// Mirrored, not observed: observing the monitor would redraw Settings
    /// with every audio sample.
    @State private var authorization = AudioLevelMonitor.Authorization.unknown
    @State private var showsEventColors: Bool

    /// `showsEventColors` opens the event colours (the renderer's frame).
    init(showsEventColors: Bool = false) {
        _showsEventColors = State(initialValue: showsEventColors)
    }

    /// Privacy & Security > Screen & System Audio Recording.
    private static let audioPrivacyURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    var body: some View {
        Section {
            Defaults.Toggle(key: .edgeGlowEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "edgeGlow.settings.enabled", defaultValue: "Glow around the closed notch"))
                    Text(String(localized: "edgeGlow.settings.enabled.detail",
                                defaultValue: "A soft light behind the notch. It breathes slowly while music plays, and flashes briefly when a timer ends, an eye break starts, the camera or microphone turns on, or the volume or brightness changes. It goes out while the panel is open."))
                        .font(.subheadline)
                        .foregroundStyle(permissionMutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker(String(localized: "edgeGlow.settings.style", defaultValue: "Style"), selection: $style) {
                ForEach(EdgeGlowStyle.allCases, id: \.self) { option in
                    Text(Self.name(option)).tag(option)
                }
            }
            .disabled(!enabled)
            LabeledContent(String(localized: "edgeGlow.settings.intensity", defaultValue: "Intensity")) {
                Slider(value: $intensity, in: 0.3...1)
                    .frame(maxWidth: 200)
                    .accessibilityValue(Text(intensity, format: .percent.precision(.fractionLength(0))))
            }
            .disabled(!enabled)

            Picker(String(localized: "edgeGlow.settings.color", defaultValue: "Music colour"), selection: $colorMode) {
                ForEach(EdgeGlowColorMode.allCases, id: \.self) { option in
                    Text(Self.name(option)).tag(option)
                }
            }
            .disabled(!enabled || !style.showsAmbient)
            if colorMode == .fixed {
                LabeledContent(String(localized: "edgeGlow.settings.fixedColor", defaultValue: "Glow colour")) {
                    ColorPicker(String(localized: "edgeGlow.settings.fixedColor", defaultValue: "Glow colour"),
                                selection: fixedBinding, supportsOpacity: false)
                        .labelsHidden()
                }
                .disabled(!enabled || !style.showsAmbient)
            }

            audioToggle
            audioStatus

            screenEdge

            DisclosureGroup(String(localized: "edgeGlow.settings.eventColors", defaultValue: "Event colours"),
                            isExpanded: $showsEventColors) {
                ForEach(EdgeGlowEventColor.allCases) { EdgeGlowEventColorRow(event: $0) }
                Text(String(localized: "edgeGlow.settings.eventColors.detail",
                            defaultValue: "Camera and microphone start green and orange, as macOS's own indicators do."))
                    .font(.caption)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!enabled)
        } header: {
            Text(String(localized: "edgeGlow.settings.header", defaultValue: "Edge glow"))
        } footer: {
            Text([Self.detail(style), Self.detail(colorMode),
                  String(localized: "edgeGlow.settings.reduceMotion",
                         defaultValue: "With Reduce Motion on, the glow stays still and dim, and does not react to sound.")]
                .compactMap { $0 }.joined(separator: " "))
                .font(.caption)
                .foregroundStyle(permissionMutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(AudioLevelMonitor.shared.$authorization) { authorization = $0 }
    }

    /// The bands beside the notch along the screen's top edge
    /// (ScreenEdgeGlow): the same glow, its own width, strength and reach.
    @ViewBuilder private var screenEdge: some View {
        Defaults.Toggle(key: .screenEdgeGlowEnabled) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "edgeGlow.settings.screenEdge", defaultValue: "Screen edge light"))
                Text(String(localized: "edgeGlow.settings.screenEdge.detail",
                            defaultValue: "The same light also runs a short way out from both sides of the notch, along the top edge of the screen, in the same colour and at the same moments. It is hidden while an app is full screen and never gets in the way of clicks."))
                    .font(.subheadline)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!enabled)
        LabeledContent(String(localized: "edgeGlow.settings.screenEdge.thickness", defaultValue: "Edge thickness")) {
            Slider(value: $screenEdgeThickness, in: ScreenEdgeGlowPolicy.thicknessRange)
                .frame(maxWidth: 200)
                .accessibilityValue(Text(String(format: String(localized: "edgeGlow.settings.screenEdge.thickness.value",
                                                               defaultValue: "%d points"), Int(screenEdgeThickness.rounded()))))
        }
        .disabled(!enabled || !screenEdgeEnabled)
        LabeledContent(String(localized: "edgeGlow.settings.screenEdge.spread", defaultValue: "Edge spread")) {
            Slider(value: $screenEdgeSpread, in: ScreenEdgeGlowPolicy.spreadRange)
                .frame(maxWidth: 200)
                .accessibilityValue(Text(String(format: String(localized: "edgeGlow.settings.screenEdge.spread.value",
                                                               defaultValue: "%@ notch widths"),
                                                screenEdgeSpread.formatted(.number.precision(.fractionLength(0...2))))))
        }
        .disabled(!enabled || !screenEdgeEnabled)
        LabeledContent(String(localized: "edgeGlow.settings.screenEdge.intensity", defaultValue: "Edge intensity")) {
            Slider(value: $screenEdgeIntensity, in: ScreenEdgeGlowPolicy.intensityRange)
                .frame(maxWidth: 200)
                .accessibilityValue(Text(screenEdgeIntensity, format: .percent.precision(.fractionLength(0))))
        }
        .disabled(!enabled || !screenEdgeEnabled)
    }

    private var audioToggle: some View {
        Defaults.Toggle(key: .edgeGlowAudioReactive) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "edgeGlow.settings.audio", defaultValue: "React to sound"))
                Text(String(localized: "edgeGlow.settings.audio.detail",
                            defaultValue: "While music plays, the glow follows how loud it is and widens on the bass. umbar measures only the loudness: of the app playing the music, or of all system sound if it cannot find that app. Nothing is recorded or sent anywhere. While the microphone is in use, as in a call, system sound is not measured. macOS asks you to allow audio recording for umbar. Off by default."))
                    .font(.subheadline)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!enabled || !style.showsAmbient || authorization == .unsupported)
    }

    @ViewBuilder private var audioStatus: some View {
        switch authorization {
        case .denied where audioReactive:
            HStack {
                Label(String(localized: "edgeGlow.settings.audio.denied",
                             defaultValue: "Audio recording is off for umbar, so the glow breathes instead."),
                      systemImage: "lock")
                Spacer()
                Button(String(localized: "edgeGlow.settings.audio.open", defaultValue: "Open System Settings")) {
                    NSWorkspace.shared.open(Self.audioPrivacyURL)
                }
            }
        case .unsupported:
            Text(String(localized: "edgeGlow.settings.audio.unsupported",
                        defaultValue: "This version of macOS cannot share audio levels with umbar."))
                .foregroundStyle(permissionMutedText)
        default:
            EmptyView()
        }
    }

    private var fixedBinding: Binding<Color> {
        Binding(
            get: { EdgeGlowColor.rgb(hex: fixedColor)?.color ?? .white },
            set: { if let rgb = EdgeGlowRGB($0) { fixedColor = EdgeGlowColor.hex(rgb) } })
    }

    private static func name(_ style: EdgeGlowStyle) -> String {
        switch style {
        case .soft: String(localized: "edgeGlow.style.soft", defaultValue: "Soft")
        case .neon: String(localized: "edgeGlow.style.neon", defaultValue: "Neon")
        case .pulse: String(localized: "edgeGlow.style.pulse", defaultValue: "Pulse")
        }
    }

    private static func detail(_ style: EdgeGlowStyle) -> String {
        switch style {
        case .soft: String(localized: "edgeGlow.style.soft.detail", defaultValue: "Soft: a wide, blurred halo.")
        case .neon: String(localized: "edgeGlow.style.neon.detail", defaultValue: "Neon: a thin, bright outline.")
        case .pulse: String(localized: "edgeGlow.style.pulse.detail", defaultValue: "Pulse: flashes for events only, no glow while music plays.")
        }
    }

    private static func name(_ mode: EdgeGlowColorMode) -> String {
        switch mode {
        case .album: String(localized: "edgeGlow.color.album", defaultValue: "Album colour")
        case .fixed: String(localized: "edgeGlow.color.fixed", defaultValue: "Fixed colour")
        case .cycle: String(localized: "edgeGlow.color.cycle", defaultValue: "Colour cycle")
        }
    }

    private static func detail(_ mode: EdgeGlowColorMode) -> String? {
        switch mode {
        case .album, .fixed: nil
        case .cycle: String(localized: "edgeGlow.color.cycle.detail",
                            defaultValue: "Colour cycle: the music glow moves slowly through every hue, once every 30 seconds.")
        }
    }
}

/// One event's colour: a picker, and a way back to the default that
/// keeps its place when there is nothing to undo, so the pickers line up.
struct EdgeGlowEventColorRow: View {
    let event: EdgeGlowEventColor
    @Default private var hex: String?

    init(event: EdgeGlowEventColor) {
        self.event = event
        _hex = Default(event.key)
    }

    var body: some View {
        LabeledContent(event.name) {
            HStack(spacing: 8) {
                Button {
                    hex = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "edgeGlow.settings.resetColor", defaultValue: "Back to the default colour"))
                .accessibilityLabel(String(format: String(localized: "edgeGlow.settings.resetColor.a11y",
                                                          defaultValue: "Reset %@ to the default colour"), event.name))
                .opacity(hex == nil ? 0 : 1)
                .disabled(hex == nil)
                .accessibilityHidden(hex == nil)
                ColorPicker(event.name, selection: binding, supportsOpacity: false)
                    .labelsHidden()
            }
        }
    }

    private var binding: Binding<Color> {
        Binding(
            get: { event.color(hex) },
            set: { if let rgb = EdgeGlowRGB($0) { hex = EdgeGlowColor.hex(rgb) } })
    }
}
