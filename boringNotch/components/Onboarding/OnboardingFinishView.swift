//
//  OnboardingFinishView.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-23.
//
//  The last onboarding screen: what umbar does, and the promise that
//  permissions are asked for in context, not now (AC-1.12, card #59).
//  Every feature that is on by default says so, and how it asks or how to
//  turn it off (card #126): a fresh install should not be surprised by an
//  eye-break prompt or a permission ask it was never told about.
//

import Defaults
import SwiftUI

struct OnboardingFinishView: View {
    let onFinish: () -> Void
    let onOpenSettings: () -> Void

    @Default(.eyeBreakIntervalMinutes) private var eyeBreakMinutes
    @Default(.eyeBreakDurationSeconds) private var eyeBreakSeconds

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("What umbar can do")
                    .font(.title)
                    .fontWeight(.semibold)
                Text("Everything lives in the notch. Move the pointer over it or click it to open.")
                    .font(.body)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 44)
            .padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(
                    systemImage: "music.note",
                    title: "Now Playing",
                    detail: "Controls for whatever is playing on your Mac."
                )
                FeatureRow(
                    systemImage: "calendar",
                    title: "Calendar and reminders",
                    detail: "Today's events and reminders at a glance. On by default; umbar asks for access the first time you open it in the notch."
                )
                FeatureRow(
                    systemImage: "tray",
                    title: "File shelf",
                    detail: "Drop files on the notch to keep them close at hand."
                )
                FeatureRow(
                    systemImage: "speaker.wave.2",
                    title: "Volume and brightness indicator",
                    detail: "Shows volume and brightness in the notch. On by default; umbar asks for Accessibility the first time you change them."
                )
                FeatureRow(
                    systemImage: "eye",
                    title: "Eye break",
                    detail: "After every \(eyeBreakMinutes) minutes of use, umbar asks you to look away for \(eyeBreakSeconds) seconds. On by default; turn it off under Eye break in Settings."
                )
            }

            Label {
                Text("No permissions are requested now. When a feature needs your calendar, reminders or Accessibility, umbar tells you why and asks you then.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "lock.shield")
                    .accessibilityHidden(true)
            }
            .font(.subheadline)
            .foregroundStyle(permissionMutedText)
            .padding(.top, 24)

            Spacer(minLength: 20)

            HStack(spacing: 12) {
                Button("Customize in Settings", action: onOpenSettings)
                    .controlSize(.large)
                Spacer(minLength: 0)
                Button("Finish", action: onFinish)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }
}

private struct FeatureRow: View {
    let systemImage: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Color.effectiveAccent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingFinishView(onFinish: { }, onOpenSettings: { })
        .frame(width: 400, height: 600)
}
