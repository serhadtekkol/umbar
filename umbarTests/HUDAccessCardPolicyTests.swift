//
//  HUDAccessCardPolicyTests.swift
//  umbarTests
//
//  K13: the notch explains the HUD's Accessibility need once, never during
//  onboarding, and only while the HUD cannot run (AC-15.7, AC-15.9).
//

import Testing

@Suite("HUDAccessCardPolicy")
struct HUDAccessCardPolicyTests {
    @Test func offeredOnceTheHUDIsWantedButBlocked() {
        #expect(HUDAccessCardPolicy.shouldOffer(hudOn: true, authorized: false, alreadyShown: false, onboardingDone: true))
    }

    @Test(arguments: [
        (hudOn: false, authorized: false, alreadyShown: false, onboardingDone: true),
        (hudOn: true, authorized: true, alreadyShown: false, onboardingDone: true),
        (hudOn: true, authorized: false, alreadyShown: true, onboardingDone: true),
        (hudOn: true, authorized: false, alreadyShown: false, onboardingDone: false),
    ])
    func notOffered(_ c: (hudOn: Bool, authorized: Bool, alreadyShown: Bool, onboardingDone: Bool)) {
        #expect(!HUDAccessCardPolicy.shouldOffer(
            hudOn: c.hudOn, authorized: c.authorized, alreadyShown: c.alreadyShown, onboardingDone: c.onboardingDone))
    }

    @Test func dismissesWithinTenSeconds() {
        #expect(HUDAccessCardPolicy.autoDismissAfter == .seconds(10))
    }
}
