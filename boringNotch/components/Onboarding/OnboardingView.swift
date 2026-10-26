//
//  OnboardingView.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-23.
//

import SwiftUI

/// Onboarding is welcome + one overview screen. It never asks for a system
/// permission (AC-1.12, card #59): Calendar and Reminders are requested from
/// the calendar widget, Accessibility from the HUD setting, each on first use.
/// The music source defaults to system Now Playing and is changed in Settings.
enum OnboardingStep {
    case welcome
    case overview
}

struct OnboardingView: View {
    @State var step: OnboardingStep = .welcome
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeView {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                        step = .overview
                    }
                }
                .transition(.opacity)

            case .overview:
                OnboardingFinishView(
                    onFinish: {
                        BoringViewCoordinator.shared.firstLaunch = false
                        onFinish()
                    },
                    onOpenSettings: {
                        BoringViewCoordinator.shared.firstLaunch = false
                        onOpenSettings()
                    }
                )
                .transition(.opacity)
            }
        }
        .frame(width: 400, height: 600)
    }
}
