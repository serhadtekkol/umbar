//
//  NativePlayerNotificationTests.swift
//  umbarTests
//
//  Card #69: a "Playing" distributed notification only counts while the
//  player that supposedly sent it is running. Ported from the
//  media-hardening scratch harness (h69).
//

import Foundation
import Testing

private let music = "com.apple.Music"
private let spotify = "com.spotify.client"
private let nothingRuns: (String) -> Bool = { _ in false }
private let onlyMusicRuns: (String) -> Bool = { $0 == music }

private let epoch = Date(timeIntervalSince1970: 0)

/// Replays the controller's flow: a "Playing" from Music goes through the
/// trust rule, then the supervisor, then a tick past the stall grace.
private func actionsAfterPlayingFromMusic(isRunning: (String) -> Bool) -> [NowPlayingSupervisor.Action] {
    var supervisor = NowPlayingSupervisor()
    _ = supervisor.begin(now: epoch, unavailableReason: nil)
    _ = supervisor.adapterLaunched(now: epoch)
    if NativePlayerNotification.isTrusted(bundleID: music, isPlaying: true, isRunning: isRunning) {
        _ = supervisor.nativePlayback(now: epoch.addingTimeInterval(1), startedPlaying: true)
    }
    return supervisor.tick(now: epoch.addingTimeInterval(20))
}

@Suite("NativePlayerNotification")
struct NativePlayerNotificationTests {
    @Test func playingFromAPlayerThatIsNotRunningIsIgnored() {
        #expect(!NativePlayerNotification.isTrusted(bundleID: music, isPlaying: true, isRunning: nothingRuns))
        #expect(
            !NativePlayerNotification.isTrusted(bundleID: spotify, isPlaying: true, isRunning: onlyMusicRuns),
            "another player running does not vouch for Spotify"
        )
    }

    @Test func playingFromARunningPlayerIsTrusted() {
        #expect(NativePlayerNotification.isTrusted(bundleID: music, isPlaying: true, isRunning: onlyMusicRuns))
    }

    /// "Not playing" can at worst clear the stall clock, so it is always
    /// accepted, and the running check is not even consulted.
    @Test(arguments: [music, spotify, "com.example.anything"])
    func notPlayingIsAlwaysTrusted(_ bundleID: String) {
        var consulted = false
        let trusted = NativePlayerNotification.isTrusted(bundleID: bundleID, isPlaying: false) { _ in
            consulted = true
            return false
        }
        #expect(trusted)
        #expect(!consulted)
    }

    @Test func forgedPlayingDoesNotStallTheAdapter() {
        #expect(actionsAfterPlayingFromMusic(isRunning: nothingRuns).isEmpty, "no stop, no switch to the AppleScript fallback")
    }

    @Test func genuinePlayingWithASilentAdapterIsStillDetectedAsAStall() {
        let actions = actionsAfterPlayingFromMusic(isRunning: onlyMusicRuns)
        #expect(actions.contains(.stopAdapter))
        #expect(actions.contains {
            if case .switchSource(.fallback, _) = $0 { return true }
            return false
        })
    }

    @Test func aBundleIDNoAppHasIsNotRunning() {
        #expect(!NativePlayerNotification.isRunning("com.example.umbar-tests.no-such-app"))
    }
}
