//
//  PlayerArbiterTests.swift
//  umbarTests
//
//  BR-2.1: most recently started player wins; with none playing, the most
//  recently paused one; registration order breaks remaining ties.
//

import Foundation
import Testing

private let music = "com.apple.Music"
private let spotify = "com.spotify.client"
private let epoch = Date(timeIntervalSince1970: 1000)
private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }
private func arbiter() -> PlayerArbiter { PlayerArbiter(priority: [music, spotify]) }

@Suite("PlayerArbiter")
struct PlayerArbiterTests {
    @Test func nothingReportedSelectsNothing() {
        var a = arbiter()
        #expect(a.selected == nil)
        a.record(source: spotify, isPlaying: false, hasReported: false, at: at(0))
        #expect(a.selected == nil, "a placeholder state is not a report")
    }

    @Test func mostRecentlyStartedPlayerWins() {
        var a = arbiter()
        a.record(source: music, isPlaying: true, hasReported: true, at: at(0))
        a.record(source: spotify, isPlaying: true, hasReported: true, at: at(5))
        #expect(a.selected == spotify)
        a.record(source: music, isPlaying: true, hasReported: true, at: at(9))
        #expect(a.selected == spotify, "a repeated playing update keeps the original start time")
        a.record(source: music, isPlaying: false, hasReported: true, at: at(10))
        a.record(source: music, isPlaying: true, hasReported: true, at: at(11))
        #expect(a.selected == music, "restarting Music after Spotify selects Music")
    }

    @Test func playingBeatsPausedAndMostRecentPauseWinsWhenIdle() {
        var a = arbiter()
        a.record(source: music, isPlaying: true, hasReported: true, at: at(0))
        a.record(source: spotify, isPlaying: true, hasReported: true, at: at(1))
        a.record(source: spotify, isPlaying: false, hasReported: true, at: at(2))
        #expect(a.selected == music)
        a.record(source: music, isPlaying: false, hasReported: true, at: at(3))
        #expect(a.selected == music, "Music paused last")
        a.record(source: spotify, isPlaying: true, hasReported: true, at: at(4))
        a.record(source: spotify, isPlaying: false, hasReported: true, at: at(5))
        #expect(a.selected == spotify, "Spotify paused last")
    }

    @Test func bothFirstSeenPausedFallsBackToPriority() {
        var a = arbiter()
        a.record(source: spotify, isPlaying: false, hasReported: true, at: at(0))
        a.record(source: music, isPlaying: false, hasReported: true, at: at(1))
        #expect(a.selected == music)
    }

    @Test func equalStartTimesFallBackToPriority() {
        var a = arbiter()
        a.record(source: music, isPlaying: true, hasReported: true, at: at(0))
        a.record(source: spotify, isPlaying: true, hasReported: true, at: at(0))
        #expect(a.selected == music)
    }

    @Test func forgottenPlayerIsDropped() {
        var a = arbiter()
        a.record(source: music, isPlaying: true, hasReported: true, at: at(0))
        a.record(source: spotify, isPlaying: true, hasReported: true, at: at(1))
        a.forget(source: spotify)
        #expect(a.selected == music)
    }

    @Test func unreportedPlayerIsNeverSelected() {
        var a = arbiter()
        a.record(source: spotify, isPlaying: false, hasReported: false, at: at(0))
        a.record(source: music, isPlaying: false, hasReported: true, at: at(1))
        #expect(a.selected == music)
    }
}
