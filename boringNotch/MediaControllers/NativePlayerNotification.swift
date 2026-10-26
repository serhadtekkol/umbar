//
//  NativePlayerNotification.swift
//  boringNotch
//
//  Kept apart from NowPlayingWithFallbackController so the unit test bundle
//  can compile the rule without the controller and its dependencies (card #56).
//

import AppKit

/// Trust rule for the players' distributed notifications (card #69).
///
/// `com.apple.Music.playerInfo` and `com.spotify.client.PlaybackStateChanged`
/// carry no sender authentication: any local process can post
/// `Player State = Playing`. Believed, a forged one starts the stall clock
/// and, with MediaRemote quiet, kills the adapter and switches to the
/// AppleScript fallback, i.e. Apple Events and Automation prompts the user
/// never asked for.
///
/// A "Playing" therefore only counts while an app with that bundle id is
/// running. Anything that says "not playing" is always accepted: at worst it
/// clears the stall clock, which only delays detection of a broken adapter.
///
/// Residual, accepted: with the player genuinely running (but not playing),
/// a forged "Playing" is still believed. Telling those apart would need
/// AppleScript, which is exactly the traffic this path must not create.
enum NativePlayerNotification {
    static func isTrusted(bundleID: String, isPlaying: Bool, isRunning: (String) -> Bool) -> Bool {
        !isPlaying || isRunning(bundleID)
    }

    static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}
