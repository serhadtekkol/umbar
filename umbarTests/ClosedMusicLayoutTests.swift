//
//  ClosedMusicLayoutTests.swift
//  umbarTests
//
//  The closed island's music ears: their width with and without the song
//  name, when the name is shown, and the short pause delay before they
//  fold (with quick pause/play not flickering). Pure; nothing is drawn.
//

import CoreGraphics
import Foundation
import Testing

@Suite("ClosedMusicLayout widths", .timeLimit(.minutes(1)))
struct ClosedMusicLayoutWidthTests {
    @Test func withoutTheNameTheEarsAreWhatTheyWere() {
        // 2 × (height − 12) + 20, the formula from before the name existed.
        #expect(ClosedMusicLayout.earsWidth(notchHeight: 32, showsTitle: false) == 60)
        #expect(ClosedMusicLayout.earsWidth(notchHeight: 45, showsTitle: false) == 86)
    }

    @Test func theNameWidensBothEarsByTheSameAmount() {
        let plain = ClosedMusicLayout.earsWidth(notchHeight: 32, showsTitle: false)
        let titled = ClosedMusicLayout.earsWidth(notchHeight: 32, showsTitle: true)
        let perEar = ClosedMusicLayout.titleWidth + ClosedMusicLayout.titleGap
        #expect(titled - plain == 2 * perEar)
    }

    @Test func theNameSlotStaysInItsBudget() {
        #expect((90...120).contains(ClosedMusicLayout.titleWidth))
        // A 254 pt notch with the name stays narrower than the battery
        // notification's 640 pt island.
        #expect(254 + ClosedMusicLayout.earsWidth(notchHeight: 45, showsTitle: true) < 640)
    }

    @Test func presenceScalesTheEarsAndIsClamped() {
        let full = ClosedMusicLayout.earsWidth(notchHeight: 32, showsTitle: true)
        #expect(ClosedMusicLayout.earsWidth(notchHeight: 32, showsTitle: true, presence: 0) == 0)
        #expect(ClosedMusicLayout.earsWidth(notchHeight: 32, showsTitle: true, presence: 0.5) == full / 2)
        #expect(ClosedMusicLayout.earsWidth(notchHeight: 32, showsTitle: true, presence: 2) == full)
        #expect(ClosedMusicLayout.earsWidth(notchHeight: 32, showsTitle: true, presence: -1) == 0)
    }

    @Test func noIslandHeightMeansNoArt() {
        #expect(ClosedMusicLayout.artSide(notchHeight: 0) == 0)
        #expect(ClosedMusicLayout.artSide(notchHeight: 8) == 0)
    }
}

@Suite("ClosedMusicLayout.showsTitle", .timeLimit(.minutes(1)))
struct ClosedMusicTitleTests {
    @Test func shownWhenOnWithANameAndAnIsland() {
        #expect(ClosedMusicLayout.showsTitle(enabled: true, title: "Yine Yazı Bekleriz (Akustik)",
                                             notchHeight: 32, inlinePeekShowing: false))
    }

    @Test func eachBlockerHidesIt() {
        #expect(!ClosedMusicLayout.showsTitle(enabled: false, title: "A", notchHeight: 32, inlinePeekShowing: false))
        #expect(!ClosedMusicLayout.showsTitle(enabled: true, title: "", notchHeight: 32, inlinePeekShowing: false))
        #expect(!ClosedMusicLayout.showsTitle(enabled: true, title: "  \n", notchHeight: 32, inlinePeekShowing: false))
        #expect(!ClosedMusicLayout.showsTitle(enabled: true, title: "A", notchHeight: 0, inlinePeekShowing: false))
        #expect(!ClosedMusicLayout.showsTitle(enabled: true, title: "A", notchHeight: 32, inlinePeekShowing: true))
    }
}

@Suite("ClosedMusicPresence", .timeLimit(.minutes(1)))
struct ClosedMusicPresenceTests {
    @Test func theDelayIsShort() {
        #expect((0.5...0.8).contains(ClosedMusicPresence.hideDelay))
    }

    @Test func startsFromThePlayer() {
        #expect(ClosedMusicPresence(playing: true).shown)
        #expect(!ClosedMusicPresence(playing: false).shown)
    }

    @Test func aPauseHidesOnceItsDelayIsDue() {
        var p = ClosedMusicPresence(playing: true)
        guard case .scheduleHide(let token) = p.playbackChanged(isPlaying: false) else {
            Issue.record("a pause should schedule a hide"); return
        }
        #expect(p.shown)
        let r1 = p.hideDue(token: token)
        #expect(r1)
        #expect(!p.shown)
    }

    @Test func playingAgainCancelsThePendingHide() {
        var p = ClosedMusicPresence(playing: true)
        guard case .scheduleHide(let token) = p.playbackChanged(isPlaying: false) else {
            Issue.record("a pause should schedule a hide"); return
        }
        let r2 = p.playbackChanged(isPlaying: true)
        #expect(r2 == .none)
        let r3 = p.hideDue(token: token)
        #expect(!r3)
        #expect(p.shown)
    }

    @Test func rapidTogglingOnlyHonoursTheLastPause() {
        var p = ClosedMusicPresence(playing: true)
        var tokens: [Int] = []
        for _ in 0..<5 {
            if case .scheduleHide(let t) = p.playbackChanged(isPlaying: false) { tokens.append(t) }
            _ = p.playbackChanged(isPlaying: true)
        }
        if case .scheduleHide(let t) = p.playbackChanged(isPlaying: false) { tokens.append(t) }
        #expect(tokens.count == 6)
        for stale in tokens.dropLast() {
            let fired = p.hideDue(token: stale)
            #expect(!fired)
        }
        #expect(p.shown)
        let r4 = p.hideDue(token: tokens.last!)
        #expect(r4)
        #expect(!p.shown)
    }

    @Test func playAfterTheHideBringsThemBack() {
        var p = ClosedMusicPresence(playing: true)
        if case .scheduleHide(let t) = p.playbackChanged(isPlaying: false) { _ = p.hideDue(token: t) }
        let r5 = p.playbackChanged(isPlaying: true)
        #expect(r5 == .enter)
        #expect(p.shown)
    }

    @Test func pausingWhileHiddenDoesNothing() {
        var p = ClosedMusicPresence(playing: false)
        let r6 = p.playbackChanged(isPlaying: false)
        #expect(r6 == .none)
        #expect(!p.shown)
    }

    @Test func aHideIsOnlyDueOnce() {
        var p = ClosedMusicPresence(playing: true)
        guard case .scheduleHide(let token) = p.playbackChanged(isPlaying: false) else { return }
        let r7 = p.hideDue(token: token)
        #expect(r7)
        let r8 = p.hideDue(token: token)
        #expect(!r8)
    }
}
