//
//  EyeBreakPromptView.swift
//  boringNotch
//
//  Notch content shown while an eye-break reminder is active (AC-14.1).
//

import Defaults
import SwiftUI

struct EyeBreakPromptView: View {
    @ObservedObject var manager = EyeBreakManager.shared

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "eye")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "eyebreak.title", defaultValue: "Look 20 feet away"))
                    .font(.headline)
                    .foregroundStyle(.white)
                countdown
                    .font(.system(.title3, design: .rounded).monospacedDigit())
                    .foregroundStyle(.gray)
            }

            Spacer(minLength: 8)

            Button(String(localized: "eyebreak.snooze", defaultValue: "Snooze 5 min")) {
                manager.snooze()
            }
            Button(String(localized: "eyebreak.skip", defaultValue: "Skip")) {
                manager.skip()
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "eyebreak.title", defaultValue: "Look 20 feet away"))
    }

    /// Per-second countdown is local to the view (TimelineView) so the manager
    /// does not have to publish every second.
    @ViewBuilder private var countdown: some View {
        if case .prompting(let endsAt) = manager.phase {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(endsAt.timeIntervalSince(ctx.date).rounded(.up)))
                Text(String(localized: "eyebreak.countdown", defaultValue: "\(left) s"))
            }
        }
    }
}
