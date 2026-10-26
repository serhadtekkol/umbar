//
//  NowPlayingSupervisor.swift
//  boringNotch
//

import Foundation

/// Decides, from observed facts only, whether the notch should follow the
/// system Now Playing adapter or fall back to the AppleScript Apple Music +
/// Spotify path (BR-2.1), and when the adapter process should be (re)started.
///
/// Card #38: Now Playing is the default source, so a broken adapter must never
/// leave the notch blank. The adapter counts as failed when
/// - its resources or the MediaRemote symbols are missing, or the app
///   bundle fails its signature check before a spawn (`unavailable`,
///   permanent for this run: a bundle that was altered is not retried),
/// - `/usr/bin/perl` cannot be launched,
/// - the process exits without us asking it to (bad framework, missing
///   symbol, crash, ...), or
/// - it is *stalled*: Apple Music or Spotify reported that playback started
///   (their distributed notifications, no AppleScript involved), yet the
///   adapter produced no data within `stallGrace`. A working MediaRemote
///   always publishes a change when a native player starts.
///
/// After a failure the adapter is restarted with capped exponential backoff
/// (`retryBase` * 2^(n-1), at most `retryMax`) so a permanently broken
/// adapter costs one short-lived perl spawn every few minutes rather than a
/// respawn loop. No jitter: there is one local process, no herd to spread.
/// The failure count resets once a run has delivered data and stayed up for
/// `healthyAfter`.
///
/// While falling back, the restarted adapter keeps running; its first data
/// switches the notch back to Now Playing, so a browser that starts playing
/// later is picked up without user action.
///
/// Known gap: a native player that was already playing before umbar started
/// sends no notification, so a silent adapter is only detected at the next
/// play/pause/track change of Music or Spotify.
///
/// Pure value type with an injected clock (`now` on every call) so it can be
/// exercised without processes, timers or players.
struct NowPlayingSupervisor: Equatable {
    enum Source: Equatable {
        case nowPlaying
        case fallback
    }

    enum Failure: Equatable, CustomStringConvertible {
        case unavailable(String)
        case launchFailed(String)
        case exited(status: Int32)
        case stalled

        var description: String {
            switch self {
            case .unavailable(let why): return "unavailable (\(why))"
            case .launchFailed(let why): return "launch failed (\(why))"
            case .exited(let status): return "exited unexpectedly (status \(status))"
            case .stalled: return "stalled (no data while Music/Spotify started playing)"
            }
        }
    }

    enum Action: Equatable {
        case startAdapter
        case stopAdapter
        case switchSource(Source, reason: String)
        /// For logging: what failed and how long until the next attempt.
        case failed(Failure, retryIn: TimeInterval)
    }

    struct Config: Equatable {
        var stallGrace: TimeInterval = 8
        var retryBase: TimeInterval = 5
        var retryMax: TimeInterval = 600
        var healthyAfter: TimeInterval = 120
    }

    let config: Config
    private(set) var source: Source = .nowPlaying
    private(set) var consecutiveFailures = 0
    private(set) var isAdapterRunning = false
    private(set) var retryAt: Date?
    private(set) var permanentlyUnavailable = false

    private var adapterStartedAt: Date?
    private var lastDataAt: Date?
    private var nativePlaybackStartedAt: Date?

    init(config: Config = Config()) {
        self.config = config
    }

    /// Called once when the controller comes up.
    mutating func begin(now: Date, unavailableReason: String?) -> [Action] {
        if let unavailableReason {
            permanentlyUnavailable = true
            return switchTo(.fallback, reason: Failure.unavailable(unavailableReason).description)
        }
        return [.startAdapter]
    }

    mutating func adapterLaunched(now: Date) -> [Action] {
        isAdapterRunning = true
        adapterStartedAt = now
        lastDataAt = nil
        retryAt = nil
        return []
    }

    mutating func adapterLaunchFailed(now: Date, error: String) -> [Action] {
        isAdapterRunning = false
        return fail(.launchFailed(error), now: now)
    }

    /// A decoded line with at least one now-playing field.
    mutating func adapterData(now: Date) -> [Action] {
        guard isAdapterRunning else { return [] }
        lastDataAt = now
        if source == .fallback {
            return switchTo(.nowPlaying, reason: "adapter recovered (data received)")
        }
        return []
    }

    /// A pre-spawn check found the adapter unusable for the rest of this run
    /// (card #68: the bundle no longer matches its signature). Nothing was
    /// spawned; no retry is scheduled.
    mutating func adapterUnavailable(now: Date, reason: String) -> [Action] {
        isAdapterRunning = false
        permanentlyUnavailable = true
        retryAt = nil
        return switchTo(.fallback, reason: Failure.unavailable(reason).description)
    }

    /// The process ended without the controller asking it to.
    mutating func adapterExited(now: Date, status: Int32) -> [Action] {
        guard isAdapterRunning else { return [] }
        isAdapterRunning = false
        return fail(.exited(status: status), now: now)
    }

    /// Aggregated Apple Music / Spotify state from their notifications.
    /// `startedPlaying` is true on a transition into playing (or a track
    /// change while playing), false when nothing native is playing anymore.
    mutating func nativePlayback(now: Date, startedPlaying: Bool) -> [Action] {
        nativePlaybackStartedAt = startedPlaying ? now : nil
        return []
    }

    /// Re-evaluates the time-based rules. Call at `nextDeadline` (or any time).
    mutating func tick(now: Date) -> [Action] {
        if isAdapterRunning {
            if let stallDeadline, now >= stallDeadline {
                return fail(.stalled, now: now)
            }
            if consecutiveFailures > 0, let healthyDeadline, now >= healthyDeadline {
                consecutiveFailures = 0
            }
            return []
        }
        if !permanentlyUnavailable, let retryAt, now >= retryAt {
            self.retryAt = nil
            return [.startAdapter]
        }
        return []
    }

    /// Earliest moment at which `tick` could change something, if any.
    var nextDeadline: Date? {
        var candidates: [Date] = []
        if isAdapterRunning {
            if let stallDeadline { candidates.append(stallDeadline) }
            if consecutiveFailures > 0, let healthyDeadline { candidates.append(healthyDeadline) }
        } else if !permanentlyUnavailable, let retryAt {
            candidates.append(retryAt)
        }
        return candidates.min()
    }

    /// Backoff before restart attempt number `failures` (1-based).
    func retryDelay(afterFailures failures: Int) -> TimeInterval {
        let exponent = Double(max(0, failures - 1))
        return min(config.retryMax, config.retryBase * pow(2, exponent))
    }

    // MARK: - Private

    /// The adapter must have produced data after the later of "it started"
    /// and "a native player started"; otherwise it is stalled at this moment.
    private var stallDeadline: Date? {
        guard let nativePlaybackStartedAt, let adapterStartedAt else { return nil }
        let reference = max(nativePlaybackStartedAt, adapterStartedAt)
        if let lastDataAt, lastDataAt >= reference { return nil }
        return reference.addingTimeInterval(config.stallGrace)
    }

    private var healthyDeadline: Date? {
        guard lastDataAt != nil, let adapterStartedAt else { return nil }
        return adapterStartedAt.addingTimeInterval(config.healthyAfter)
    }

    private mutating func fail(_ failure: Failure, now: Date) -> [Action] {
        var actions: [Action] = []
        if isAdapterRunning {
            isAdapterRunning = false
            actions.append(.stopAdapter)
        }
        consecutiveFailures += 1
        let delay = retryDelay(afterFailures: consecutiveFailures)
        retryAt = now.addingTimeInterval(delay)
        actions.append(.failed(failure, retryIn: delay))
        actions += switchTo(.fallback, reason: failure.description)
        return actions
    }

    private mutating func switchTo(_ newSource: Source, reason: String) -> [Action] {
        guard source != newSource else { return [] }
        source = newSource
        return [.switchSource(newSource, reason: reason)]
    }
}
