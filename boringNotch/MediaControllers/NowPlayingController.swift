//
//  NowPlayingController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import AppKit
import Combine
import Foundation

final class NowPlayingController: ObservableObject, MediaControllerProtocol {
    func updatePlaybackInfo() async {
        await fetchFavoriteStateIfSupported()
    }

    // MARK: - Properties
    @Published private(set) var playbackState: PlaybackState = .init(
        bundleIdentifier: "com.apple.Music"
    )

    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music" || bundleID == "com.spotify.client"
    }

    var supportsFavorite: Bool {
        let bundleID = playbackState.bundleIdentifier
        return bundleID == "com.apple.Music"
    }

    func setFavorite(_ favorite: Bool) async {
        let bundleID = playbackState.bundleIdentifier
        
        if bundleID == "com.apple.Music" {
            let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
            if !runningApps.isEmpty {
                let script = """
                tell application "Music"
                    try
                        set favorited of current track to \(favorite ? "true" : "false")
                    end try
                end tell
                """
                try? await AppleScriptHelper.executeVoid(script)
            }
        }
        
        // Update the favorite state locally and fetch updated info
        try? await Task.sleep(for: .milliseconds(150))
        await updatePlaybackInfo()
    }

    private var lastMusicItem:
        (title: String, artist: String, album: String, duration: TimeInterval, artworkData: Data?)?

    // MARK: - Media Remote Functions
    private let mediaRemoteBundle: CFBundle
    private let MRMediaRemoteSendCommandFunction: @convention(c) (Int, AnyObject?) -> Void
    private let MRMediaRemoteSetElapsedTimeFunction: @convention(c) (Double) -> Void
    private let MRMediaRemoteSetShuffleModeFunction: @convention(c) (Int) -> Void
    private let MRMediaRemoteSetRepeatModeFunction: @convention(c) (Int) -> Void

    private let adapter = NowPlayingAdapterProcess()
    private let decoder = JSONDecoder()
    /// Log the first data and the first artwork of each adapter run once, so
    /// the log shows the pipeline works without logging every update.
    /// (MediaRemote usually delivers artwork in a later update than the
    /// title.)
    private var hasLoggedFirstData = false
    private var hasLoggedFirstArtwork = false
    private var hasLoggedRejectedArtwork = false

    /// Adapter health signals for `NowPlayingWithFallbackController`.
    /// `onAdapterData` fires (on the main thread) for every update that
    /// carried at least one now-playing field; `onAdapterExit` when the child
    /// ended without `stopAdapter()`.
    var onAdapterData: (() -> Void)?
    var onAdapterExit: ((Int32, String) -> Void)?

    // MARK: - Initialization

    /// Resolves the MediaRemote command symbols used for play/pause, next,
    /// previous, seek, shuffle and repeat. Returns nil when they are gone
    /// (a future macOS); the caller then falls back to AppleScript.
    ///
    /// Commands are sent in-process: verified on macOS 27.0.1 that an
    /// unentitled process can still send MRMediaRemoteSendCommand /
    /// MRMediaRemoteSetElapsedTime to a browser (Chrome) session. Only
    /// *reading* now-playing info needs the entitled `/usr/bin/perl`
    /// adapter, which keeps us at exactly one helper process.
    ///
    /// Does not start the adapter; call `startAdapter()`.
    init?() {
        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")),
            let MRMediaRemoteSendCommandPointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSendCommand" as CFString),
            let MRMediaRemoteSetElapsedTimePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetElapsedTime" as CFString),
            let MRMediaRemoteSetShuffleModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetShuffleMode" as CFString),
            let MRMediaRemoteSetRepeatModePointer = CFBundleGetFunctionPointerForName(
                bundle, "MRMediaRemoteSetRepeatMode" as CFString)
            
        else { return nil }

        mediaRemoteBundle = bundle
        MRMediaRemoteSendCommandFunction = unsafeBitCast(
            MRMediaRemoteSendCommandPointer, to: (@convention(c) (Int, AnyObject?) -> Void).self)
        MRMediaRemoteSetElapsedTimeFunction = unsafeBitCast(
            MRMediaRemoteSetElapsedTimePointer, to: (@convention(c) (Double) -> Void).self)
        MRMediaRemoteSetShuffleModeFunction = unsafeBitCast(
            MRMediaRemoteSetShuffleModePointer, to: (@convention(c) (Int) -> Void).self)
        MRMediaRemoteSetRepeatModeFunction = unsafeBitCast(
            MRMediaRemoteSetRepeatModePointer, to: (@convention(c) (Int) -> Void).self)

        adapter.onLine = { [weak self] line in self?.handleAdapterLine(line) }
        adapter.onUnexpectedExit = { [weak self] status, stderrTail in
            self?.onAdapterExit?(status, stderrTail)
        }
    }

    deinit {
        // Blocks briefly so a replacement controller (source switch) never
        // overlaps with a still-running old stream.
        adapter.stop(waitForExit: 0.5)
    }

    /// Starts the stream child. No-op while it is already running.
    ///
    /// - Throws: `NowPlayingAdapterError.resourcesMissing` when the adapter
    ///   is not bundled, `.integrityCheckFailed` when the app bundle no
    ///   longer matches its signature (nothing is spawned then), or the
    ///   `Process` error when perl cannot be launched.
    func startAdapter() throws {
        guard !adapter.isRunning else { return }
        guard MediaRemoteAdapterBundle.isAvailable,
              let scriptURL = MediaRemoteAdapterBundle.scriptURL,
              let frameworkPath = MediaRemoteAdapterBundle.frameworkPath
        else {
            throw NowPlayingAdapterError.resourcesMissing
        }
        // Before every spawn, not once per run: perl runs whatever is on
        // disk at that moment (card #68).
        try MediaRemoteAdapterBundle.verifyIntegrity()
        try adapter.start(scriptURL: scriptURL, frameworkPath: frameworkPath)
        hasLoggedFirstData = false
        hasLoggedFirstArtwork = false
        hasLoggedRejectedArtwork = false
    }

    func stopAdapter() {
        adapter.stop()
    }

    var adapterProcessIdentifier: Int32? { adapter.processIdentifier }

    // MARK: - Protocol Implementation
    func play() async {
        MRMediaRemoteSendCommandFunction(0, nil)
    }

    func pause() async {
        MRMediaRemoteSendCommandFunction(1, nil)
    }

    func togglePlay() async {
        MRMediaRemoteSendCommandFunction(2, nil)
    }

    func nextTrack() async {
        MRMediaRemoteSendCommandFunction(4, nil)
    }

    func previousTrack() async {
        MRMediaRemoteSendCommandFunction(5, nil)
    }

    func seek(to time: Double) async {
        MRMediaRemoteSetElapsedTimeFunction(time)
    }

    func isActive() -> Bool {
        return true
    }
    
    func toggleShuffle() async {
        // MRMediaRemoteSendCommandFunction(6, nil)
        MRMediaRemoteSetShuffleModeFunction(playbackState.isShuffled ? 1 : 3)
        playbackState.isShuffled.toggle()
    }
    
    func toggleRepeat() async {
        // MRMediaRemoteSendCommandFunction(7, nil)
        let newRepeatMode = (playbackState.repeatMode == .off) ? 3 : (playbackState.repeatMode.rawValue - 1)
        playbackState.repeatMode = RepeatMode(rawValue: newRepeatMode) ?? .off
        MRMediaRemoteSetRepeatModeFunction(newRepeatMode)
    }
    
    func setVolume(_ level: Double) async {
        // MediaRemote framework doesn't provide direct volume control for the active audio session
        // As a workaround, try to control the currently active music app directly
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        
        let bundleID = playbackState.bundleIdentifier
        if !bundleID.isEmpty {
            if bundleID == "com.apple.Music" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
                if !runningApps.isEmpty {
                    let script = "tell application \"Music\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            } else if bundleID == "com.spotify.client" {
                let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client")
                if !runningApps.isEmpty {
                    let script = "tell application \"Spotify\" to set sound volume to \(volumePercentage)"
                    try? await AppleScriptHelper.executeVoid(script)
                }
            }
        }
        
        playbackState.volume = clampedLevel
    }
    
    // MARK: - Stream Processing

    /// What an update says about artwork, decided on the I/O queue.
    private enum ArtworkField {
        /// The update has no artwork field.
        case absent
        /// Base64-decoded, size- and type-checked image bytes.
        case image(Data, typeIdentifier: String)
        /// The field was present but unusable; treated as "no artwork" so the
        /// app icon is shown instead.
        case rejected(ArtworkImageDecoder.Rejection)
    }

    /// Runs on the adapter's I/O queue. JSON and the base64 artwork (up to
    /// a few MB) are decoded here so the main thread only assigns state
    /// (card #70).
    private func handleAdapterLine(_ line: Data) {
        // Non-data lines (none today) and malformed JSON are skipped, as before.
        guard let update = try? decoder.decode(NowPlayingUpdate.self, from: line) else { return }
        let artwork: ArtworkField
        if let base64 = update.payload.artworkData {
            switch ArtworkImageDecoder.validatedArtwork(base64: base64) {
            case .success(let validated):
                artwork = .image(validated.data, typeIdentifier: validated.typeIdentifier)
            case .failure(let rejection):
                artwork = .rejected(rejection)
            }
        } else {
            artwork = .absent
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.handleAdapterUpdate(update, artwork: artwork)
            switch artwork {
            case .image(let data, let type) where !self.hasLoggedFirstArtwork:
                self.hasLoggedFirstArtwork = true
                NSLog("[NowPlaying] first adapter artwork: \(data.count) bytes, \(type)")
            case .rejected(let rejection) where !self.hasLoggedRejectedArtwork:
                self.hasLoggedRejectedArtwork = true
                NSLog("[NowPlaying] adapter artwork ignored: \(rejection)")
            default:
                break
            }
            if update.payload.carriesNowPlayingData {
                if !self.hasLoggedFirstData {
                    self.hasLoggedFirstData = true
                    // Bundle id and state only: titles are the user's listening history.
                    NSLog("[NowPlaying] first adapter data: app \(self.playbackState.bundleIdentifier), playing \(self.playbackState.isPlaying), artwork \(self.playbackState.artwork != nil)")
                }
                self.onAdapterData?()
            }
        }
    }

    // MARK: - Update Methods
    private func handleAdapterUpdate(_ update: NowPlayingUpdate, artwork: ArtworkField) {
        let payload = update.payload
        let diff = update.diff ?? false

        var newPlaybackState = PlaybackState(bundleIdentifier: playbackState.bundleIdentifier)
        
        newPlaybackState.title = payload.title ?? (diff ? self.playbackState.title : "")
        newPlaybackState.artist = payload.artist ?? (diff ? self.playbackState.artist : "")
        newPlaybackState.album = payload.album ?? (diff ? self.playbackState.album : "")
        newPlaybackState.duration = payload.duration ?? (diff ? self.playbackState.duration : 0)
        
        if let elapsedTime = payload.elapsedTime {
            newPlaybackState.currentTime = elapsedTime
        } else if diff {
            if payload.playing == false {
                let timeSinceLastUpdate = Date().timeIntervalSince(self.playbackState.lastUpdated)
                newPlaybackState.currentTime = self.playbackState.currentTime + (self.playbackState.playbackRate * timeSinceLastUpdate)
            } else {
                newPlaybackState.currentTime = self.playbackState.currentTime
            }
        } else {
            newPlaybackState.currentTime = 0
        }

        
        if let shuffleMode = payload.shuffleMode {
            newPlaybackState.isShuffled = shuffleMode != 1
        } else if !diff {
            newPlaybackState.isShuffled = false
        } else {
            newPlaybackState.isShuffled = self.playbackState.isShuffled
        }
        if let repeatModeValue = payload.repeatMode {
            newPlaybackState.repeatMode = RepeatMode(rawValue: repeatModeValue) ?? .off
        } else if !diff {
            newPlaybackState.repeatMode = .off
        } else {
            newPlaybackState.repeatMode = self.playbackState.repeatMode
        }

        switch artwork {
        case .image(let data, _):
            newPlaybackState.artwork = data
        case .rejected:
            newPlaybackState.artwork = nil
        case .absent:
            if !diff { newPlaybackState.artwork = nil }
        }

        if let dateString = payload.timestamp,
           let date = ISO8601DateFormatter().date(from: dateString) {
            newPlaybackState.lastUpdated = date
        } else if !diff {
            newPlaybackState.lastUpdated = Date()
        } else {
            newPlaybackState.lastUpdated = self.playbackState.lastUpdated
        }

        newPlaybackState.playbackRate = payload.playbackRate ?? (diff ? self.playbackState.playbackRate : 1.0)
        newPlaybackState.isPlaying = payload.playing ?? (diff ? self.playbackState.isPlaying : false)
        newPlaybackState.bundleIdentifier = (
            payload.parentApplicationBundleIdentifier ??
            payload.bundleIdentifier ??
            (diff ? self.playbackState.bundleIdentifier : "")
        )
        
        newPlaybackState.volume = payload.volume ?? (diff ? self.playbackState.volume : 0.5)
        
        self.playbackState = newPlaybackState
        
        // Fetch favorite state for supported apps asynchronously
        // await fetchFavoriteStateIfSupported()
    }
    
     private func fetchFavoriteStateIfSupported() async {
         let bundleID = playbackState.bundleIdentifier
        
         if bundleID == "com.apple.Music" {
             let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music")
             guard !runningApps.isEmpty else { return }
             
             let script = """
             tell application "Music"
                 try
                     return favorited of current track
                 on error
                     return false
                 end try
             end tell
             """
             if let result = try? await AppleScriptHelper.execute(script) {
                 var updated = self.playbackState
                 updated.isFavorite = result.booleanValue
                 self.playbackState = updated
             }
         }
     }
    
}

struct NowPlayingUpdate: Codable {
    let payload: NowPlayingPayload
    let diff: Bool?
}

struct NowPlayingPayload: Codable {
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double?
    let elapsedTime: Double?
    let shuffleMode: Int?
    let repeatMode: Int?
    let artworkData: String?
    let timestamp: String?
    let playbackRate: Double?
    let playing: Bool?
    let parentApplicationBundleIdentifier: String?
    let bundleIdentifier: String?
    let volume: Double?
}

extension NowPlayingPayload {
    /// True when the update says anything about what is playing. An empty
    /// payload (`{}`), which MediaRemote yields when it denies access, does not
    /// count as the adapter working.
    var carriesNowPlayingData: Bool {
        title != nil || artist != nil || playing != nil || bundleIdentifier != nil
            || parentApplicationBundleIdentifier != nil || elapsedTime != nil
    }
}

enum NowPlayingAdapterError: Error, CustomStringConvertible {
    case resourcesMissing
    /// The app bundle failed its code-signature check; the reason is the
    /// Security framework's message. Permanent for this run.
    case integrityCheckFailed(String)

    var description: String {
        switch self {
        case .resourcesMissing: return "adapter script or framework not bundled"
        case .integrityCheckFailed(let reason): return "app bundle signature check failed: \(reason)"
        }
    }
}
