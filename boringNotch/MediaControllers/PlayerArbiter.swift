//
//  PlayerArbiter.swift
//  boringNotch
//

import Foundation

/// Decides which of several media players the notch follows when more than
/// one is available.
///
/// Implements business rule BR-2.1 (docs/spec.md):
/// - If one or more players are playing, the one that **started playing most
///   recently** wins.
/// - If none is playing, the one that was **paused most recently** wins.
///
/// Timestamps are the moments this arbiter *observed* a transition, not the
/// moments the players report. A player that is already playing when it is
/// first observed is treated as having started at that observation; a player
/// that is already paused when first observed has no known pause time.
/// When no pause time is known for any player, the tie is broken by the
/// registration order passed to `init(priority:)`, so the outcome is
/// deterministic.
///
/// This is a pure value type with no clock or AppKit dependency so the rule can
/// be exercised without real players.
struct PlayerArbiter: Equatable {
    private struct Activity: Equatable {
        var isPlaying: Bool
        var hasReported: Bool
        var startedPlayingAt: Date?
        var pausedAt: Date?
    }

    /// Bundle identifiers in tie-break order (first wins).
    private let priority: [String]
    private var activity: [String: Activity] = [:]

    /// - Parameter priority: Player bundle identifiers in the order used to break
    ///   ties when nothing else distinguishes them.
    init(priority: [String]) {
        self.priority = priority
    }

    /// Records the latest observed state of a player.
    ///
    /// - Parameters:
    ///   - source: The player's bundle identifier.
    ///   - isPlaying: Whether the player currently reports playback.
    ///   - hasReported: `false` while the player has never delivered real state
    ///     (its controller still holds the placeholder). Such players are never
    ///     selected.
    ///   - date: When the state was observed.
    mutating func record(source: String, isPlaying: Bool, hasReported: Bool, at date: Date) {
        var entry = activity[source]
            ?? Activity(isPlaying: false, hasReported: false, startedPlayingAt: nil, pausedAt: nil)
        let wasKnown = activity[source] != nil

        if isPlaying && (!entry.isPlaying || entry.startedPlayingAt == nil) {
            entry.startedPlayingAt = date
        } else if !isPlaying && entry.isPlaying && wasKnown {
            entry.pausedAt = date
        }
        entry.isPlaying = isPlaying
        entry.hasReported = entry.hasReported || hasReported
        activity[source] = entry
    }

    /// Forgets a player entirely, e.g. because its app quit.
    mutating func forget(source: String) {
        activity[source] = nil
    }

    /// The bundle identifier of the player to follow, or `nil` if no player has
    /// reported real state yet.
    var selected: String? {
        let candidates = activity.filter { $0.value.hasReported }

        let playing = candidates.filter { $0.value.isPlaying }
        if !playing.isEmpty {
            return best(of: playing) { $0.startedPlayingAt }
        }
        return best(of: candidates) { $0.pausedAt }
    }

    private func best(of entries: [String: Activity], by key: (Activity) -> Date?) -> String? {
        entries.max { lhs, rhs in
            let l = key(lhs.value) ?? .distantPast
            let r = key(rhs.value) ?? .distantPast
            if l != r { return l < r }
            // Equal (or both unknown) timestamps: the higher-priority source must
            // compare as "greater", i.e. have the lower index.
            let (lr, rr) = (rank(lhs.key), rank(rhs.key))
            if lr != rr { return lr > rr }
            // Unknown sources share a rank; order them by name so dictionary
            // iteration order never decides the result.
            return lhs.key > rhs.key
        }?.key
    }

    private func rank(_ source: String) -> Int {
        priority.firstIndex(of: source) ?? priority.count
    }
}
