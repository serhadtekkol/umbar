//
//  NowPlayingWithFallbackController.swift
//  boringNotch
//

import AppKit
import Combine
import Foundation

/// The default media source (card #38): system Now Playing through the
/// MediaRemote adapter, so browsers (YouTube Music in Safari/Chrome) and any
/// other media app show up, with an automatic fallback to the AppleScript
/// Apple Music + Spotify path (`AutomaticMediaController`, BR-2.1) whenever the
/// adapter is missing, exits, or goes silent.
///
/// The fallback decision lives in `NowPlayingSupervisor` (pure, tested); this
/// class wires it to the real adapter process, the players' distributed
/// notifications and a single one-shot timer, and forwards the state and
/// commands of whichever source is active. Every transition is logged with a
/// `[NowPlaying]` prefix.
///
/// The AppleScript controllers are created only while falling back and
/// released on recovery, so a healthy Now Playing path sends no Apple Events
/// (no Automation prompts) at all.
///
/// Threading: all state is mutated on the main thread.
final class NowPlayingWithFallbackController: MediaControllerProtocol {
    @Published private var playbackState = PlaybackState(bundleIdentifier: "")

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool { activeController?.supportsVolumeControl ?? false }
    var supportsFavorite: Bool { activeController?.supportsFavorite ?? false }

    /// nil when the private MediaRemote symbols are gone.
    private let nowPlaying: NowPlayingController?
    private var fallback: AutomaticMediaController?
    private var supervisor: NowPlayingSupervisor
    private var wakeTimer: DispatchSourceTimer?
    private var sourceCancellable: AnyCancellable?
    private var cancellables = Set<AnyCancellable>()
    /// Last reported playing state per native player, for the stall rule.
    private var nativePlaying: [String: Bool] = [:]
    private let clock: () -> Date

    init(config: NowPlayingSupervisor.Config = .init(), clock: @escaping () -> Date = Date.init) {
        self.clock = clock
        self.supervisor = NowPlayingSupervisor(config: config)
        self.nowPlaying = NowPlayingController()

        nowPlaying?.onAdapterData = { [weak self] in
            self?.apply { $0.adapterData(now: $1) }
        }
        nowPlaying?.onAdapterExit = { [weak self] status, stderrTail in
            let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty {
                NSLog("[NowPlaying] adapter stderr: \(detail.suffix(300))")
            }
            self?.apply { $0.adapterExited(now: $1, status: status) }
        }

        observeNativePlayers()

        let unavailableReason: String?
        if nowPlaying == nil {
            unavailableReason = "MediaRemote symbols not found"
        } else if !MediaRemoteAdapterBundle.isAvailable {
            unavailableReason = NowPlayingAdapterError.resourcesMissing.description
        } else {
            unavailableReason = nil
        }
        // Follow Now Playing from the start; a failure switches away.
        if unavailableReason == nil { follow(.nowPlaying) }
        apply { $0.begin(now: $1, unavailableReason: unavailableReason) }
    }

    deinit {
        wakeTimer?.cancel()
        nowPlaying?.stopAdapter()
    }

    // MARK: - Supervisor plumbing

    private func apply(_ event: (inout NowPlayingSupervisor, Date) -> [NowPlayingSupervisor.Action]) {
        let now = clock()
        let actions = event(&supervisor, now)
        for action in actions {
            perform(action, now: now)
        }
        scheduleWake()
    }

    private func perform(_ action: NowPlayingSupervisor.Action, now: Date) {
        switch action {
        case .startAdapter:
            guard let nowPlaying else { return }
            do {
                try nowPlaying.startAdapter()
                NSLog("[NowPlaying] adapter started (pid \(nowPlaying.adapterProcessIdentifier.map(String.init) ?? "?"))")
                apply { $0.adapterLaunched(now: $1) }
            } catch {
                apply { $0.adapterLaunchFailed(now: $1, error: "\(error)") }
            }
        case .stopAdapter:
            nowPlaying?.stopAdapter()
        case .failed(let failure, let retryIn):
            NSLog("[NowPlaying] adapter \(failure); retrying in \(Int(retryIn))s")
        case .switchSource(let source, let reason):
            NSLog("[NowPlaying] source -> \(source == .nowPlaying ? "Now Playing" : "Apple Music + Spotify (fallback)"): \(reason)")
            follow(source)
        }
    }

    private func scheduleWake() {
        wakeTimer?.cancel()
        wakeTimer = nil
        guard let deadline = supervisor.nextDeadline else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(0, deadline.timeIntervalSince(clock())))
        timer.setEventHandler { [weak self] in
            self?.apply { $0.tick(now: $1) }
        }
        timer.resume()
        wakeTimer = timer
    }

    // MARK: - Sources

    private var activeController: (any MediaControllerProtocol)? {
        supervisor.source == .nowPlaying ? nowPlaying : fallback
    }

    private func follow(_ source: NowPlayingSupervisor.Source) {
        let controller: any MediaControllerProtocol
        switch source {
        case .nowPlaying:
            guard let nowPlaying else { return }
            fallback = nil
            controller = nowPlaying
        case .fallback:
            let automatic = fallback ?? AutomaticMediaController()
            fallback = automatic
            controller = automatic
        }
        sourceCancellable = controller.playbackStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.playbackState = state
            }
        if controller.isActive() {
            Task { await controller.updatePlaybackInfo() }
        }
    }

    /// Apple Music and Spotify announce state changes over distributed
    /// notifications without any permission; that is the independent signal
    /// that tells a silent adapter apart from "nothing is playing".
    private func observeNativePlayers() {
        let center = DistributedNotificationCenter.default()
        let names = [
            "com.apple.Music.playerInfo": "com.apple.Music",
            "com.spotify.client.PlaybackStateChanged": "com.spotify.client",
        ]
        for (name, bundleID) in names {
            center.publisher(for: Notification.Name(name))
                .receive(on: DispatchQueue.main)
                .sink { [weak self] notification in
                    let state = notification.userInfo?["Player State"] as? String
                    self?.nativePlayerChanged(bundleID, isPlaying: state == "Playing")
                }
                .store(in: &cancellables)
        }
        // A player quit mid-playback sends no "Paused"; treat quitting as stopped.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .compactMap { ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier }
            .filter { names.values.contains($0) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bundleID in
                self?.nativePlayerChanged(bundleID, isPlaying: false)
            }
            .store(in: &cancellables)
    }

    private func nativePlayerChanged(_ bundleID: String, isPlaying: Bool) {
        nativePlaying[bundleID] = isPlaying
        if isPlaying {
            // "Playing" means a start or a track change; both make a working
            // MediaRemote publish, so both restart the stall clock.
            apply { $0.nativePlayback(now: $1, startedPlaying: true) }
        } else if !nativePlaying.values.contains(true) {
            apply { $0.nativePlayback(now: $1, startedPlaying: false) }
        }
        // One player paused while another still plays: keep the earlier clock.
    }

    // MARK: - MediaControllerProtocol

    func setFavorite(_ favorite: Bool) async { await activeController?.setFavorite(favorite) }
    func play() async { await activeController?.play() }
    func pause() async { await activeController?.pause() }
    func seek(to time: Double) async { await activeController?.seek(to: time) }
    func nextTrack() async { await activeController?.nextTrack() }
    func previousTrack() async { await activeController?.previousTrack() }
    func togglePlay() async { await activeController?.togglePlay() }
    func toggleShuffle() async { await activeController?.toggleShuffle() }
    func toggleRepeat() async { await activeController?.toggleRepeat() }
    func setVolume(_ level: Double) async { await activeController?.setVolume(level) }
    func isActive() -> Bool { activeController?.isActive() ?? false }
    func updatePlaybackInfo() async { await activeController?.updatePlaybackInfo() }
}
