//
//  AutomaticMediaController.swift
//  boringNotch
//

import AppKit
import Combine
import Foundation

/// Follows Apple Music and Spotify at the same time and exposes whichever one
/// `PlayerArbiter` selects (BR-2.1) as a single controller.
///
/// This is the default media source. It uses only the players' public
/// AppleScript interfaces and their distributed notifications, so it needs no
/// private framework and spawns no helper process. The trade-off versus the
/// opt-in MediaRemote adapter is coverage: only these two players are seen.
///
/// Commands (play, seek, volume, ...) are sent to the currently selected
/// player. If nothing has been selected yet they go to the first running
/// player, so a play command from an idle notch still reaches something.
///
/// Threading: source publishers are received on the main queue and all state
/// in this class is mutated there only.
final class AutomaticMediaController: MediaControllerProtocol {
    static let sourceBundleIdentifiers = ["com.apple.Music", "com.spotify.client"]

    @Published private var playbackState: PlaybackState

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool { currentSource?.supportsVolumeControl ?? true }
    var supportsFavorite: Bool { currentSource?.supportsFavorite ?? false }

    private let sources: [String: any MediaControllerProtocol]
    private var latestStates: [String: PlaybackState] = [:]
    private var arbiter = PlayerArbiter(priority: AutomaticMediaController.sourceBundleIdentifiers)
    private var selectedSource: String?
    private var cancellables = Set<AnyCancellable>()

    /// - Parameter sources: Controllers to arbitrate between, keyed by the
    ///   player bundle identifier they report. Defaults to Apple Music and
    ///   Spotify.
    init(sources: [String: any MediaControllerProtocol]? = nil) {
        let resolved = sources ?? [
            "com.apple.Music": AppleMusicController(),
            "com.spotify.client": SpotifyController(),
        ]
        self.sources = resolved
        self.playbackState = PlaybackState(bundleIdentifier: Self.sourceBundleIdentifiers[0])

        for (bundleID, controller) in resolved {
            controller.playbackStatePublisher
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    self?.handle(state, from: bundleID)
                }
                .store(in: &cancellables)
        }

        // A quit player keeps its last published state forever; drop it so a
        // paused-then-quit Spotify does not hold the notch over a live Music.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier }
            .filter { resolved[$0] != nil }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bundleID in
                self?.arbiter.forget(source: bundleID)
                self?.latestStates[bundleID] = nil
                self?.publishSelection()
            }
            .store(in: &cancellables)
    }

    private var currentSource: (any MediaControllerProtocol)? {
        if let selectedSource, let controller = sources[selectedSource] {
            return controller
        }
        return Self.sourceBundleIdentifiers
            .compactMap { sources[$0] }
            .first { $0.isActive() }
    }

    private func handle(_ state: PlaybackState, from bundleID: String) {
        latestStates[bundleID] = state
        // Controllers start from a placeholder state stamped `.distantPast`;
        // anything else came from the player itself.
        arbiter.record(
            source: bundleID,
            isPlaying: state.isPlaying,
            hasReported: state.lastUpdated != .distantPast,
            at: Date()
        )
        publishSelection()
    }

    private func publishSelection() {
        selectedSource = arbiter.selected
        guard let selectedSource, let state = latestStates[selectedSource] else { return }
        if state != playbackState || state.lastUpdated != playbackState.lastUpdated {
            playbackState = state
        }
    }

    // MARK: - MediaControllerProtocol

    func setFavorite(_ favorite: Bool) async { await currentSource?.setFavorite(favorite) }
    func play() async { await currentSource?.play() }
    func pause() async { await currentSource?.pause() }
    func seek(to time: Double) async { await currentSource?.seek(to: time) }
    func nextTrack() async { await currentSource?.nextTrack() }
    func previousTrack() async { await currentSource?.previousTrack() }
    func togglePlay() async { await currentSource?.togglePlay() }
    func toggleShuffle() async { await currentSource?.toggleShuffle() }
    func toggleRepeat() async { await currentSource?.toggleRepeat() }
    func setVolume(_ level: Double) async { await currentSource?.setVolume(level) }

    func isActive() -> Bool {
        sources.values.contains { $0.isActive() }
    }

    func updatePlaybackInfo() async {
        // Only query running players: an AppleScript `tell application` to a
        // closed player would launch it.
        for controller in sources.values where controller.isActive() {
            await controller.updatePlaybackInfo()
        }
    }
}
