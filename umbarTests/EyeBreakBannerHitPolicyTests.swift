//
//  EyeBreakBannerHitPolicyTests.swift
//  umbarTests
//
//  C7-H: the eye-break banner lets clicks through everywhere but its
//  buttons, and keeps the notch strip so hovering the notch still opens
//  the panel.
//

import CoreGraphics
import Testing

@Suite("EyeBreakBannerHitPolicy", .timeLimit(.minutes(1)))
struct EyeBreakBannerHitPolicyTests {
    // 420 pt banner centred in the 680 pt notch window, MacBook Air notch (45 pt).
    let banner = CGRect(x: 130, y: 0, width: 420, height: 110)
    let notch: CGFloat = 45
    let snooze = CGRect(x: 300, y: 70, width: 80, height: 26)
    let skip = CGRect(x: 388, y: 70, width: 64, height: 26)

    @Test func bannerBackgroundPassesThrough() {
        #expect(EyeBreakBannerHitPolicy.passesThrough(CGPoint(x: 200, y: 80), banner: banner, notchHeight: notch, targets: [snooze, skip]))
    }

    @Test func buttonsKeepTheirClicks() {
        #expect(!EyeBreakBannerHitPolicy.passesThrough(CGPoint(x: 340, y: 80), banner: banner, notchHeight: notch, targets: [snooze, skip]))
        #expect(!EyeBreakBannerHitPolicy.passesThrough(CGPoint(x: 420, y: 83), banner: banner, notchHeight: notch, targets: [snooze, skip]))
    }

    @Test func notchStripIsKeptForHover() {
        #expect(!EyeBreakBannerHitPolicy.passesThrough(CGPoint(x: 340, y: 10), banner: banner, notchHeight: notch, targets: []))
        #expect(!EyeBreakBannerHitPolicy.passesThrough(CGPoint(x: 340, y: 44.9), banner: banner, notchHeight: notch, targets: []))
        #expect(EyeBreakBannerHitPolicy.passesThrough(CGPoint(x: 340, y: 45), banner: banner, notchHeight: notch, targets: []))
    }

    @Test func offTheBannerIsLeftToTheWindow() {
        #expect(!EyeBreakBannerHitPolicy.passesThrough(CGPoint(x: 600, y: 80), banner: banner, notchHeight: notch, targets: []))
        #expect(!EyeBreakBannerHitPolicy.passesThrough(CGPoint(x: 200, y: 140), banner: banner, notchHeight: notch, targets: []))
    }

    @Test func emptyBannerBeforeLayoutPassesNothing() {
        #expect(!EyeBreakBannerHitPolicy.passesThrough(CGPoint(x: 0, y: 0), banner: .zero, notchHeight: notch, targets: []))
    }

    @Test func screenPointMapsToTopLeftWindowSpace() {
        // 680 x 256 window at the top of a 1332 pt tall screen, x 704.
        let window = CGRect(x: 704, y: 1076, width: 680, height: 256)
        let p = EyeBreakBannerHitPolicy.windowPoint(screen: CGPoint(x: 1044, y: 1332), windowFrame: window)
        #expect(p == CGPoint(x: 340, y: 0))
        let q = EyeBreakBannerHitPolicy.windowPoint(screen: CGPoint(x: 704, y: 1076), windowFrame: window)
        #expect(q == CGPoint(x: 0, y: 256))
    }
}
