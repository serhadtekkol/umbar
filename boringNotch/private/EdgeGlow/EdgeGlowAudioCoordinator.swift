//
//  EdgeGlowAudioCoordinator.swift
//  boringNotch
//
//  The one owner of the edge glow's audio capture. It lives for the life
//  of the app and alone calls AudioLevelMonitor.setActive; the glows only
//  read `capturesAudio`.
//
//  Why not the views: with "Show on all displays" each screen has its own
//  glow, and they shared one capture. One screen's glow sending `false`
//  stopped every other screen's, and a window that went away without its
//  view's last change left the capture running for as long as music
//  played. The answer does not depend on a screen (EdgeGlowPolicy), so it
//  is worked out once, here, from the settings, the player and Reduce
//  Motion.
//

import AppKit
import Combine
import Defaults

@MainActor
final class EdgeGlowAudioCoordinator: ObservableObject {
    static let shared = EdgeGlowAudioCoordinator()

    /// Whether the capture is meant to run. The glows ignore samples while
    /// this is false.
    @Published private(set) var capturesAudio = false

    private var observations: [AnyCancellable] = []

    private init() {}

    /// Follows the inputs for the life of the app. Call once at launch.
    func start() {
        guard observations.isEmpty else { return }
        let keys: [Defaults._AnyKey] = [.edgeGlowEnabled, .edgeGlowStyle, .edgeGlowAudioReactive]
        // Emits once at subscription, which applies the persisted state.
        observations.append(
            Defaults.publisher(keys: keys, options: [.initial])
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.reconcile() } }
        )
        observations.append(
            MusicManager.shared.$isPlaying
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.reconcile() } }
        )
        observations.append(
            NSWorkspace.shared.notificationCenter
                .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.reconcile() } }
        )
    }

    private func reconcile() {
        let on = EdgeGlowPolicy.capturesAudio(
            enabled: Defaults[.edgeGlowEnabled], style: Defaults[.edgeGlowStyle],
            audioReactive: Defaults[.edgeGlowAudioReactive], musicPlaying: MusicManager.shared.isPlaying,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        guard on != capturesAudio else { return }
        capturesAudio = on
        AudioLevelMonitor.shared.setActive(on)
    }
}
