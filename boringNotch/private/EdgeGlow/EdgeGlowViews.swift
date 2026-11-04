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
//  and nothing is scheduled. Only the shadow's colour changes per frame;
//  the island's own views are not rebuilt by it. A shadow takes no hits,
//  and adds nothing for VoiceOver (each event has its own ear or banner
//  that says it in words).
//

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

/// Apply to the island after its ears, so the glow is their silhouette too.
struct EdgeGlow: ViewModifier {
    let isOpen: Bool
    let islandHeight: CGFloat

    @Default(.edgeGlowEnabled) private var enabled
    @Default(.edgeGlowStyle) private var style
    @Default(.edgeGlowIntensity) private var intensity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var signals = EdgeGlowSignals.idle
    @State private var pulse: EdgeGlowEvent?
    @State private var pulseStart = Date.distantPast
    @State private var pulseEnd: Task<Void, Never>?
    @State private var settleTask: Task<Void, Never>?
    @State private var musicPlaying = false
    @State private var albumColor = Color.white
    @State private var envelope = EdgeGlowEnvelope()

    private var target: EdgeGlowState? {
        EdgeGlowPolicy.state(EdgeGlowContext(
            enabled: enabled, style: style, reduceMotion: reduceMotion, isOpen: isOpen,
            islandHeight: Double(islandHeight), musicPlaying: musicPlaying, pulse: pulse))
    }

    func body(content: Content) -> some View {
        let envelope = envelope
        let interval = envelope.frameInterval
        TimelineView(.animation(minimumInterval: interval ?? 1, paused: interval == nil)) { context in
            let level = envelope.level(at: context.date, pulseElapsed: context.date.timeIntervalSince(pulseStart))
            content
                // One silhouette: without it each ear casts its own glow
                // over its neighbour.
                .compositingGroup()
                .modifier(EdgeGlowShadow(style: style,
                                         color: envelope.state.map { color($0.tint) } ?? .clear,
                                         level: level * intensity))
        }
        .onChange(of: target, initial: true) { _, new in retarget(new) }
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
        .onReceive(MusicManager.shared.$avgColor) { albumColor = Self.albumTint($0) }
        .onDisappear {
            pulseEnd?.cancel()
            settleTask?.cancel()
        }
    }

    /// The system HUDs umbar replaces; music and battery peeks have their own island.
    private static let hudTypes: Set<SneakContentType> = [.volume, .brightness, .backlight, .mic]

    private func retarget(_ new: EdgeGlowState?) {
        envelope.update(to: new, now: Date(), reduceMotion: reduceMotion)
        settleTask?.cancel()
        guard envelope.releasedAt != nil else { return }
        // Stops the clock once the fade-out is over.
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
        pulseEnd?.cancel()
        pulseEnd = Task { @MainActor in
            try? await Task.sleep(for: .seconds(EdgeGlowPolicy.pulseDuration))
            guard !Task.isCancelled else { return }
            pulse = nil
        }
    }

    private func color(_ tint: EdgeGlowTint) -> Color {
        switch tint {
        case .album: albumColor
        case .timer: EdgeGlowTokens.timer
        case .eyeBreak: EdgeGlowTokens.eyeBreak
        case .camera: EdgeGlowTokens.camera
        case .microphone: EdgeGlowTokens.microphone
        case .hud: EdgeGlowTokens.hud
        }
    }

    private static func albumTint(_ color: NSColor) -> Color {
        guard let rgb = color.usingColorSpace(.sRGB) else { return EdgeGlowTokens.hud }
        let lifted = EdgeGlowPolicy.albumGlow(
            red: Double(rgb.redComponent), green: Double(rgb.greenComponent), blue: Double(rgb.blueComponent))
        return Color(red: lifted.red, green: lifted.green, blue: lifted.blue)
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

    func body(content: Content) -> some View {
        let layers = Self.layers(style)
        content
            .shadow(color: color.opacity(level * layers[0].opacity), radius: layers[0].radius)
            .shadow(color: color.opacity(level * layers[1].opacity), radius: layers[1].radius)
            .shadow(color: color.opacity(level * layers[2].opacity), radius: layers[2].radius)
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

    var body: some View {
        Section {
            Defaults.Toggle(key: .edgeGlowEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "edgeGlow.settings.enabled", defaultValue: "Glow around the closed notch"))
                    Text(String(localized: "edgeGlow.settings.enabled.detail",
                                defaultValue: "A soft light behind the notch. It breathes in the album's colour while music plays, and flashes briefly when a timer ends, an eye break starts, the camera or microphone turns on, or the volume or brightness changes. It goes out while the panel is open."))
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
        } header: {
            Text(String(localized: "edgeGlow.settings.header", defaultValue: "Edge glow"))
        } footer: {
            Text(Self.detail(style) + " "
                 + String(localized: "edgeGlow.settings.reduceMotion",
                          defaultValue: "With Reduce Motion on, the glow stays still and dim."))
                .font(.caption)
                .foregroundStyle(permissionMutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
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
}
