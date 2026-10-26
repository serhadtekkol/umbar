//
//  HUDAccessCardPolicy.swift
//  boringNotch
//
//  When the notch may explain, on its own, that the HUD needs Accessibility
//  (K13, AC-15.7, AC-15.9). Foundation only, for umbarTests.
//

import Foundation

enum HUDAccessCardPolicy {
    /// How long the card stays before it closes by itself (AC-15.9).
    static let autoDismissAfter: Duration = .seconds(10)

    /// The card appears once per install, never during onboarding, and only
    /// while the HUD is wanted but cannot run.
    static func shouldOffer(hudOn: Bool, authorized: Bool, alreadyShown: Bool, onboardingDone: Bool) -> Bool {
        hudOn && !authorized && !alreadyShown && onboardingDone
    }
}
