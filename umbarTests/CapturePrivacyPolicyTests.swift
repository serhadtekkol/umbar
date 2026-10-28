//
//  CapturePrivacyPolicyTests.swift
//  umbarTests
//
//  Muhittin L5: the clipboard history on screen keeps the notch window out
//  of screen capture; off screen, the user's setting decides.
//

import Testing

@Suite("CapturePrivacyPolicy", .timeLimit(.minutes(1)))
struct CapturePrivacyPolicyTests {
    @Test func userSettingAloneDecidesWhileNothingSensitiveIsShown() {
        #expect(!CapturePrivacyPolicy.excludesFromCapture(userHides: false, sensitiveOnScreen: false))
        #expect(CapturePrivacyPolicy.excludesFromCapture(userHides: true, sensitiveOnScreen: false))
    }

    @Test(arguments: [false, true])
    func sensitiveContentExcludesWhateverTheSetting(_ userHides: Bool) {
        #expect(CapturePrivacyPolicy.excludesFromCapture(userHides: userHides, sensitiveOnScreen: true))
    }

    @Test func restoreWaitsForTheCloseAnimation() {
        // contentOut 0.1 s + close spring settled ~0.32 s after a 0.04 s delay.
        #expect(CapturePrivacyPolicy.restoreDelay >= 0.4)
        #expect(CapturePrivacyPolicy.restoreDelay <= 1)
    }

    @Test func overlappingViewsKeepItShowingUntilTheLastLeaves() {
        var tally = SensitiveContentTally()
        #expect(!tally.isShowing)
        tally.appear()
        tally.appear()
        tally.disappear()
        #expect(tally.isShowing)
        tally.disappear()
        #expect(!tally.isShowing)
    }

    @Test func anUnmatchedDisappearDoesNotHideALaterAppear() {
        var tally = SensitiveContentTally()
        tally.disappear()
        #expect(tally.count == 0)
        tally.appear()
        #expect(tally.isShowing)
    }
}
