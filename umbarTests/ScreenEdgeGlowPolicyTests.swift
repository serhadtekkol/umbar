//
//  ScreenEdgeGlowPolicyTests.swift
//  umbarTests
//
//  The screen edge glow: when it draws and when its window shows, the
//  frame-rate cap, how far the bands beside the notch reach, how far the
//  light has run along them, the glint, the panel strip, and the
//  fullscreen check against fixture window lists. Nothing is drawn,
//  captured or played.
//

import Foundation
import Testing

@Suite("ScreenEdgeGlowPolicy", .timeLimit(.minutes(1)))
struct ScreenEdgeGlowPolicyTests {
    private func context(music: Bool = false, pulse: EdgeGlowEvent? = nil, open: Bool = false,
                         height: Double = 32, reduceMotion: Bool = false, style: EdgeGlowStyle = .soft,
                         enabled: Bool = true) -> EdgeGlowContext {
        EdgeGlowContext(enabled: enabled, style: style, reduceMotion: reduceMotion, isOpen: open,
                        islandHeight: height, musicPlaying: music, pulse: pulse)
    }

    // MARK: State and visibility

    @Test func idleDrawsNothing() {
        #expect(ScreenEdgeGlowPolicy.state(context(), screenEdgeEnabled: true) == nil)
        #expect(!ScreenEdgeGlowPolicy.showsWindow(drawing: false, fullscreen: false))
    }

    @Test func followsTheNotchGlowsState() {
        #expect(ScreenEdgeGlowPolicy.state(context(music: true), screenEdgeEnabled: true)
            == EdgeGlowState(tint: .album, animation: .breathing))
        #expect(ScreenEdgeGlowPolicy.state(context(pulse: .camera), screenEdgeEnabled: true)
            == EdgeGlowState(tint: .camera, animation: .pulse))
        // Pulse style: events only, as the notch.
        #expect(ScreenEdgeGlowPolicy.state(context(music: true, style: .pulse), screenEdgeEnabled: true) == nil)
    }

    @Test func eitherSwitchOffPutsItOut() {
        #expect(ScreenEdgeGlowPolicy.state(context(music: true), screenEdgeEnabled: false) == nil)
        #expect(ScreenEdgeGlowPolicy.state(context(music: true, enabled: false), screenEdgeEnabled: true) == nil)
    }

    @Test func anOpenPanelOrHiddenIslandDoesNotPutItOut() {
        // The panel covers the notch, not the edges; fullscreen is checked per screen.
        #expect(ScreenEdgeGlowPolicy.state(context(music: true, open: true), screenEdgeEnabled: true) != nil)
        #expect(ScreenEdgeGlowPolicy.state(context(pulse: .hud, height: 0), screenEdgeEnabled: true) != nil)
    }

    @Test func reduceMotionIsSteady() {
        #expect(ScreenEdgeGlowPolicy.state(context(music: true, reduceMotion: true), screenEdgeEnabled: true)?.animation == .steady)
        #expect(ScreenEdgeGlowPolicy.state(context(pulse: .timerFinished, reduceMotion: true), screenEdgeEnabled: true)?.animation == .steady)
    }

    @Test func windowShowsOnlyWhileDrawingAndNotFullscreen() {
        #expect(ScreenEdgeGlowPolicy.showsWindow(drawing: true, fullscreen: false))
        #expect(!ScreenEdgeGlowPolicy.showsWindow(drawing: true, fullscreen: true))
        #expect(!ScreenEdgeGlowPolicy.showsWindow(drawing: false, fullscreen: true))
    }

    @Test func frameRateIsCappedAt30() {
        #expect(ScreenEdgeGlowPolicy.frameInterval(1.0 / 60) == 1.0 / 30)
        #expect(ScreenEdgeGlowPolicy.frameInterval(1.0 / 24) == 1.0 / 24)
        // No clock stays no clock: steady and audio-driven frames.
        #expect(ScreenEdgeGlowPolicy.frameInterval(nil) == nil)
        #expect(ScreenEdgeGlowPolicy.frameInterval(EdgeGlowPolicy.frameInterval(.steady)) == nil)
        #expect(ScreenEdgeGlowPolicy.frameInterval(EdgeGlowPolicy.frameInterval(.pulse))! >= 1.0 / 30)
    }

    // MARK: Band geometry

    @Test func defaultSpreadIsBetweenOneAndOneAndAHalfNotchWidths() {
        let spread = 1.25
        #expect(ScreenEdgeGlowPolicy.spreadRange.contains(spread))
        let length = ScreenEdgeGlowPolicy.bandLength(screenWidth: 1512, notchWidth: 190, spread: spread)
        #expect(length >= 190 && length <= 285)
        #expect(abs(length - 237.5) < 1e-9)
    }

    @Test func theBandNeverReachesTheCorner() {
        // Widest spread on a narrow screen: cut short of the corner.
        let length = ScreenEdgeGlowPolicy.bandLength(screenWidth: 900, notchWidth: 200, spread: 2.5)
        #expect(length == (900 - 200) / 2 - ScreenEdgeGlowPolicy.cornerMargin)
        #expect(200 / 2 + length < 900 / 2)
    }

    @Test func spreadIsClampedAndNaNSafe() {
        let low = ScreenEdgeGlowPolicy.bandLength(screenWidth: 3000, notchWidth: 200, spread: 0)
        #expect(Double(low) == 200 * ScreenEdgeGlowPolicy.spreadRange.lowerBound)
        let high = ScreenEdgeGlowPolicy.bandLength(screenWidth: 3000, notchWidth: 200, spread: 10)
        #expect(Double(high) == 200 * ScreenEdgeGlowPolicy.spreadRange.upperBound)
        #expect(ScreenEdgeGlowPolicy.bandLength(screenWidth: 3000, notchWidth: 200, spread: .nan) == 200)
    }

    @Test func noNotchUsesTheFallbackWidth() {
        let length = ScreenEdgeGlowPolicy.bandLength(screenWidth: 2560, notchWidth: 0, spread: 1)
        #expect(length == ScreenEdgeGlowPolicy.fallbackNotchWidth)
    }

    @Test func aTinyScreenGetsNoBandRatherThanANegativeOne() {
        #expect(ScreenEdgeGlowPolicy.bandLength(screenWidth: 100, notchWidth: 190, spread: 1) == 0)
    }

    @Test func thePanelIsAStripAtTheTopOfItsScreen() {
        let screen = CGRect(x: 1512, y: -200, width: 2560, height: 1080)
        let strip = ScreenEdgeGlowPolicy.panelFrame(screen: screen)
        #expect(strip.width == screen.width && strip.minX == screen.minX)
        #expect(strip.maxY == screen.maxY)
        #expect(strip.height == ScreenEdgeGlowPolicy.panelHeight)
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 50)
        #expect(ScreenEdgeGlowPolicy.panelFrame(screen: tiny) == tiny)
    }

    // MARK: Flow phase

    @Test func reachRunsOutFromTheNotch() {
        #expect(ScreenEdgeGlowPolicy.reach(.breathing, elapsed: 0) == 0)
        #expect(ScreenEdgeGlowPolicy.reach(.breathing, elapsed: ScreenEdgeGlowPolicy.revealDuration) == 1)
        #expect(ScreenEdgeGlowPolicy.reach(.breathing, elapsed: 100) == 1)
        #expect(ScreenEdgeGlowPolicy.reach(.breathing, elapsed: -1) == 0)
        var last = -1.0
        for i in 0...20 {
            let r = ScreenEdgeGlowPolicy.reach(.audio, elapsed: Double(i) * 0.05)
            #expect(r >= last)
            last = r
        }
    }

    @Test func anEventSweepsOutDuringItsFirstFlash() {
        let half = EdgeGlowPolicy.pulseDuration / 2
        #expect(ScreenEdgeGlowPolicy.reach(.pulse, elapsed: 0) == 0)
        #expect(ScreenEdgeGlowPolicy.reach(.pulse, elapsed: half / 2) > 0.5)
        #expect(ScreenEdgeGlowPolicy.reach(.pulse, elapsed: half) == 1)
    }

    @Test func steadyIsTheWholeRimAndNoGlint() {
        #expect(ScreenEdgeGlowPolicy.reach(.steady, elapsed: 0) == 1)
        #expect(ScreenEdgeGlowPolicy.glint(.steady, time: 12, elapsed: 3) == nil)
    }

    @Test func pulseGlintIsTheSweepsHeadAndEndsWithIt() throws {
        let g = try #require(ScreenEdgeGlowPolicy.glint(.pulse, time: 0, elapsed: 0.2))
        #expect(g.position == ScreenEdgeGlowPolicy.reach(.pulse, elapsed: 0.2))
        #expect(abs(g.strength - (1 - g.position)) < 1e-9)
        #expect(ScreenEdgeGlowPolicy.glint(.pulse, time: 0, elapsed: EdgeGlowPolicy.pulseDuration / 2) == nil)
    }

    @Test func ambientGlintTravelsOutwardAndRepeats() throws {
        let period = ScreenEdgeGlowPolicy.glintPeriod
        let base = period * 1000
        let start = try #require(ScreenEdgeGlowPolicy.glint(.breathing, time: base, elapsed: 10))
        #expect(start.position < 1e-6)
        #expect(start.strength < 1e-6)
        let mid = try #require(ScreenEdgeGlowPolicy.glint(.breathing, time: base + period / 2, elapsed: 10))
        #expect(abs(mid.position - 0.5) < 1e-9)
        #expect(abs(mid.strength - 1) < 1e-9)
        let again = try #require(ScreenEdgeGlowPolicy.glint(.breathing, time: base + period * 1.5, elapsed: 10))
        #expect(abs(again.position - mid.position) < 1e-9)
    }

    @Test func ambientGlintNeverRunsAheadOfTheReveal() throws {
        let period = ScreenEdgeGlowPolicy.glintPeriod
        let g = try #require(ScreenEdgeGlowPolicy.glint(.audio, time: period * 0.9, elapsed: 0.1))
        #expect(g.position <= ScreenEdgeGlowPolicy.reach(.audio, elapsed: 0.1))
    }

    @Test func glintHandlesNegativeTime() throws {
        let g = try #require(ScreenEdgeGlowPolicy.glint(.breathing, time: -1, elapsed: 10))
        #expect(g.position >= 0 && g.position <= 1)
    }

    @Test func easeOutIsClampedAndHandlesNaN() {
        #expect(ScreenEdgeGlowPolicy.easeOut(-1) == 0)
        #expect(ScreenEdgeGlowPolicy.easeOut(2) == 1)
        #expect(ScreenEdgeGlowPolicy.easeOut(.nan) == 1)
        #expect(ScreenEdgeGlowPolicy.easeOut(0.5) > 0.5)
    }

    // MARK: Fullscreen

    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let me: Int32 = 100

    @Test func aWindowCoveringTheScreenIsFullscreen() {
        let w = ScreenEdgeGlowPolicy.WindowInfo(bounds: screen, layer: 0, ownerPID: 200)
        #expect(ScreenEdgeGlowPolicy.isFullscreen(screen: screen, windows: [w], ownPID: me))
    }

    @Test func aZoomedWindowUnderTheMenuBarIsNot() {
        let w = ScreenEdgeGlowPolicy.WindowInfo(bounds: CGRect(x: 0, y: 37, width: 1512, height: 945), layer: 0, ownerPID: 200)
        #expect(!ScreenEdgeGlowPolicy.isFullscreen(screen: screen, windows: [w], ownPID: me))
    }

    @Test func ownWindowsOtherLayersAndInvisibleWindowsDoNotCount() {
        let windows: [ScreenEdgeGlowPolicy.WindowInfo] = [
            .init(bounds: screen, layer: 0, ownerPID: me),
            .init(bounds: screen, layer: 25, ownerPID: 200),
            .init(bounds: screen, layer: -2_147_483_624, ownerPID: 300),
            .init(bounds: screen, layer: 0, ownerPID: 400, alpha: 0),
        ]
        #expect(!ScreenEdgeGlowPolicy.isFullscreen(screen: screen, windows: windows, ownPID: me))
    }

    @Test func aWindowOnAnotherScreenDoesNotCount() {
        let second = CGRect(x: 1512, y: -200, width: 2560, height: 1080)
        let w = ScreenEdgeGlowPolicy.WindowInfo(bounds: second, layer: 0, ownerPID: 200)
        #expect(!ScreenEdgeGlowPolicy.isFullscreen(screen: screen, windows: [w], ownPID: me))
        #expect(ScreenEdgeGlowPolicy.isFullscreen(screen: second, windows: [w], ownPID: me))
    }

    @Test func appKitFramesMapToDisplayCoordinates() {
        // Main screen 982 high; a screen above it at AppKit y 982.
        let above = CGRect(x: -100, y: 982, width: 2560, height: 1080)
        #expect(ScreenEdgeGlowPolicy.displayRect(fromAppKit: above, mainScreenHeight: 982)
            == CGRect(x: -100, y: -1080, width: 2560, height: 1080))
        #expect(ScreenEdgeGlowPolicy.displayRect(fromAppKit: screen, mainScreenHeight: 982) == screen)
    }
}
