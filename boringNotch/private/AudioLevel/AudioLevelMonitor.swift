//
//  AudioLevelMonitor.swift
//  boringNotch
//
//  Live loudness of the now-playing app's audio output, for the edge glow's
//  audio-reactive mode. Off unless the user turns that mode on; the system
//  asks for audio-capture permission the first time it starts. Levels are
//  computed in memory and never stored or sent anywhere.
//
//  Contract shared by the edge glow (reader) and the capture (writer).
//
//  How it hears: a Core Audio process tap on the now-playing app's
//  processes (MusicManager's bundle ID, helpers included; see
//  AudioTapTargeting), or on all system output except umbar when that app
//  has no outputting process. The all-system fallback is never used while
//  another app has the microphone open (a call or a recording would be
//  measured along with the music); capture then waits. The tap is unmuted
//  (the user still hears everything) and private (no device shows up
//  anywhere).
//
//  When it runs: only between setActive(true) and setActive(false), and
//  only while MusicManager reports playback. A pause tears the tap down
//  after a short grace period; so does setActive(false), at once. Nothing
//  about Core Audio is touched before the first setActive(true).
//

import AppKit
import Combine
import CoreAudio
import Foundation
import os

@MainActor
final class AudioLevelMonitor: ObservableObject {
    static let shared = AudioLevelMonitor()

    /// `.unknown` until the first setActive(true) has asked, and also when
    /// this macOS offers no way to read the permission (capture then runs
    /// and the system prompts by itself). `.unsupported` is not produced on
    /// the macOS versions umbar ships for; it stays in the contract for a
    /// system where process taps are unavailable.
    enum Authorization: Equatable { case unknown, granted, denied, unsupported }

    /// Smoothed loudness, 0…1 (-50…0 dBFS). 0 while stopped.
    @Published private(set) var level: Float = 0
    /// Smoothed band energies, 0…1 on the same dB scale: below ~250 Hz,
    /// ~250 Hz–4 kHz, above ~4 kHz. Typical music reads lower in treble than
    /// in bass; that is the music, not a calibration error.
    @Published private(set) var bass: Float = 0
    @Published private(set) var mid: Float = 0
    @Published private(set) var treble: Float = 0
    /// True while a tap is live and delivering samples.
    @Published private(set) var isRunning = false
    @Published private(set) var authorization: Authorization = .unknown

    /// Where the running tap listens; nil while stopped. For the probe and
    /// logs; not part of the glow's contract.
    private(set) var target: AudioTapTargeting.Target?

    private static let log = Logger(subsystem: "umbar", category: "AudioLevel")
    private static let publishInterval: TimeInterval = 1.0 / 30
    /// How long a pause may last before the tap is destroyed. Covers the gap
    /// between tracks, where some players report "paused" for a moment.
    private static let pauseGrace: TimeInterval = 2
    /// How often the process list is re-read while running, to follow an
    /// app whose audio moves to a helper after playback has begun (browsers
    /// start their audio process lazily) without a HAL notification.
    private static let retargetInterval: TimeInterval = 3

    private let engine = AudioCaptureEngine()
    private var requested = false
    private var permissionRequestInFlight = false
    private var musicPlaying = false
    private var nowPlaying: String?
    private var meter: AudioLevelMeter?
    private var smoothed = AudioLevelReading.silent

    private var musicCancellables = Set<AnyCancellable>()
    private var publishTimer: Timer?
    private var retargetTimer: Timer?
    private var pauseTeardown: DispatchWorkItem?
    private var halListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    private init() {}

    /// Starts or stops capture. Safe to call repeatedly; the glow calls it
    /// with `true` only while the mode is on and music is playing.
    ///
    /// The first `true` asks for the audio-capture permission if the user
    /// has not decided yet; a denial sets `authorization = .denied` and
    /// leaves everything stopped. Later `true` calls re-read the permission,
    /// so granting it in System Settings takes effect on the next start.
    func setActive(_ active: Bool) {
        guard active != requested else { return }
        requested = active
        if active {
            authorizeThenStart()
        } else {
            stopObserving()
            reconcile()
        }
    }

    // MARK: - Permission

    private func authorizeThenStart() {
        switch AudioCapturePermission.status() {
        case .granted:
            authorization = .granted
            startObserving()
        case .denied:
            authorization = .denied
            Self.log.notice("audio capture permission denied; staying stopped")
        case .unavailable:
            Self.log.notice("audio capture permission cannot be read on this system; starting anyway")
            startObserving()
        case .notDetermined:
            guard !permissionRequestInFlight else { return }
            permissionRequestInFlight = true
            AudioCapturePermission.requestAccess { status in
                MainActor.assumeIsolated {
                    let monitor = AudioLevelMonitor.shared
                    monitor.permissionRequestInFlight = false
                    switch status {
                    case .granted: monitor.authorization = .granted
                    case .denied: monitor.authorization = .denied
                    case .notDetermined, .unavailable: break
                    }
                    if status != .denied, monitor.requested { monitor.startObserving() }
                }
            }
        }
    }

    // MARK: - Inputs

    private func startObserving() {
        guard musicCancellables.isEmpty else { return }
        let music = MusicManager.shared
        musicPlaying = music.isPlaying
        nowPlaying = music.bundleIdentifier
        music.$isPlaying
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in
                MainActor.assumeIsolated { self?.playbackChanged(playing) }
            }
            .store(in: &musicCancellables)
        music.$bundleIdentifier
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] bundleID in
                MainActor.assumeIsolated {
                    self?.nowPlaying = bundleID
                    self?.reconcile()
                }
            }
            .store(in: &musicCancellables)

        // Headphones in or out, AirPlay picked: the aggregate is clocked by
        // the old device and must be rebuilt around the new one. A process
        // starting or stopping audio may move the now-playing app's sound.
        addHALListener(kAudioHardwarePropertyDefaultOutputDevice)
        addHALListener(kAudioHardwarePropertyProcessObjectList)
        // A process starting its microphone flips a per-process property,
        // which neither listener above reports; the retarget timer would
        // catch it within a few seconds. The privacy indicator already
        // listens to exactly that property, so when it is enabled its
        // change triggers a re-check at once. It is only a trigger: the
        // decision reads the HAL itself, so it holds with the indicator off.
        PrivacyIndicatorMonitor.shared.$usage
            .map(\.microphone)
            .removeDuplicates()
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { _ in
                MainActor.assumeIsolated { AudioLevelMonitor.shared.reconcile() }
            }
            .store(in: &musicCancellables)

        let retarget = Timer(timeInterval: Self.retargetInterval, repeats: true) { _ in
            MainActor.assumeIsolated { AudioLevelMonitor.shared.reconcile() }
        }
        retarget.tolerance = 1
        RunLoop.main.add(retarget, forMode: .common)
        retargetTimer = retarget

        reconcile()
    }

    private func stopObserving() {
        musicCancellables.removeAll()
        retargetTimer?.invalidate()
        retargetTimer = nil
        pauseTeardown?.cancel()
        pauseTeardown = nil
        for (address, block) in halListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        halListeners.removeAll()
    }

    private func addHALListener(_ selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { AudioLevelMonitor.shared.reconcile() }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        if status == noErr {
            halListeners.append((address, block))
        } else {
            Self.log.error("listen for \(selector, privacy: .public) failed: \(status, privacy: .public)")
        }
    }

    private func playbackChanged(_ playing: Bool) {
        pauseTeardown?.cancel()
        pauseTeardown = nil
        if playing {
            musicPlaying = true
            reconcile()
            return
        }
        let teardown = DispatchWorkItem {
            MainActor.assumeIsolated {
                let monitor = AudioLevelMonitor.shared
                monitor.musicPlaying = false
                monitor.reconcile()
            }
        }
        pauseTeardown = teardown
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pauseGrace, execute: teardown)
    }

    // MARK: - Capture

    /// Brings the capture in line with the inputs: off unless requested,
    /// permitted and playing; otherwise on, aimed at the current target.
    /// The engine does the HAL work off the main thread and leaves a live
    /// session alone when nothing it depends on has changed.
    private func reconcile() {
        let wanted = requested && authorization != .denied && musicPlaying
        engine.apply(
            wanted: wanted,
            nowPlaying: nowPlaying,
            ownBundleID: Bundle.main.bundleIdentifier
        ) { meter, target in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AudioLevelMonitor.shared.adopt(meter: meter, target: target) }
            }
        }
    }

    private func adopt(meter newMeter: AudioLevelMeter?, target newTarget: AudioTapTargeting.Target?) {
        if newTarget != target {
            switch newTarget {
            case .processes(let ids)?:
                // The app's bundle ID says what the user is listening to: hashed,
                // so two log lines can still be matched without naming it.
                Self.log.notice("tapping now-playing app \(self.nowPlaying ?? "?", privacy: .private(mask: .hash)) (\(ids.count) process(es))")
            case .global?:
                Self.log.notice("tapping all system output (no outputting process for \(self.nowPlaying ?? "nil", privacy: .private(mask: .hash)))")
            case nil:
                Self.log.notice("capture stopped")
            }
        }
        target = newTarget
        guard newMeter !== meter else { return }
        meter = newMeter
        isRunning = newMeter != nil
        if newMeter == nil {
            publishTimer?.invalidate()
            publishTimer = nil
            smoothed = .silent
            publish(.silent)
        } else if publishTimer == nil {
            let timer = Timer(timeInterval: Self.publishInterval, repeats: true) { _ in
                MainActor.assumeIsolated { AudioLevelMonitor.shared.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            publishTimer = timer
        }
    }

    private func tick() {
        guard let meter else { return }
        smoothed = smoothed.smoothed(toward: meter.latest())
        publish(smoothed)
    }

    /// Assigns only what changed, so a silent stretch sends SwiftUI nothing.
    private func publish(_ reading: AudioLevelReading) {
        if level != reading.level { level = reading.level }
        if bass != reading.bass { bass = reading.bass }
        if mid != reading.mid { mid = reading.mid }
        if treble != reading.treble { treble = reading.treble }
    }

    #if DEBUG
    /// Analyses completed by the running meter; the probe uses it to show
    /// that samples are arriving at all.
    var analysisCount: UInt64 { meter?.analysisCount ?? 0 }
    #endif
}

/// Owns the AudioTapSession on a private serial queue, so the HAL calls
/// (which can take tens of milliseconds, more when a Bluetooth device
/// wakes) never block the main thread. Everything inside is touched only
/// on `queue`.
private final class AudioCaptureEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.serhadbahadir.umbar.audio-level", qos: .userInitiated)
    private var session: AudioTapSession?
    private var sessionApp: String?
    /// The inputs of the last failed build. The monitor re-applies every few
    /// seconds; without this a HAL that keeps refusing would be asked (and
    /// logged) every time. Retried after `retryDelay`, or at once when the
    /// app, the target or the output device changes.
    private var lastFailure: (target: AudioTapTargeting.Target, output: String?, at: Date)?
    private static let retryDelay: TimeInterval = 30
    /// True while capture is held back by the microphone rule; only so the
    /// log says it once, not every few seconds.
    private var withheld = false
    private static let log = Logger(subsystem: "umbar", category: "AudioLevel")

    func apply(
        wanted: Bool,
        nowPlaying: String?,
        ownBundleID: String?,
        completion: @escaping @Sendable (AudioLevelMeter?, AudioTapTargeting.Target?) -> Void
    ) {
        queue.async { [self] in
            guard wanted else {
                session?.invalidate()
                session = nil
                sessionApp = nil
                lastFailure = nil
                withheld = false
                completion(nil, nil)
                return
            }
            let proposed = AudioTapTargeting.target(
                nowPlaying: nowPlaying,
                candidates: AudioProcessList.candidates(),
                ownBundleID: ownBundleID)
            let outputUID = try? AudioHardwareSystem.shared.defaultOutputDevice?.uid
            if let session, session.outputDeviceUID == outputUID,
               !AudioTapTargeting.shouldRebuild(
                   current: session.target, currentApp: sessionApp,
                   proposed: proposed, app: nowPlaying) {
                // Same tap, possibly a new app with the same target (both
                // global): remember the app so the next comparison is fair.
                if session.target == proposed { sessionApp = nowPlaying }
                completion(session.meter, session.target)
                return
            }
            session?.invalidate()
            session = nil
            guard let proposed else {
                // Microphone in use and no per-app tap possible.
                if !withheld { Self.log.notice("microphone in use; not tapping all system output") }
                withheld = true
                sessionApp = nil
                completion(nil, nil)
                return
            }
            withheld = false
            if let lastFailure, lastFailure.target == proposed, lastFailure.output == outputUID,
               Date().timeIntervalSince(lastFailure.at) < Self.retryDelay {
                completion(nil, nil)
                return
            }
            do {
                let fresh = try AudioTapSession(target: proposed)
                session = fresh
                sessionApp = nowPlaying
                lastFailure = nil
                completion(fresh.meter, fresh.target)
            } catch {
                sessionApp = nil
                lastFailure = (proposed, outputUID, Date())
                Self.log.error("audio level capture did not start: \(String(describing: error), privacy: .public)")
                completion(nil, nil)
            }
        }
    }
}
