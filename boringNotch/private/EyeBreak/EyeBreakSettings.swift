//
//  EyeBreakSettings.swift
//  boringNotch
//
//  Settings > Eye break (F14, card #83): on/off, the three BR-14.1 timings,
//  where the reminder appears (AC-14.7) and the full-screen hold (AC-14.5).
//

import Defaults
import SwiftUI

struct EyeBreakSettings: View {
    @Default(.eyeBreakEnabled) private var enabled
    @Default(.eyeBreakDelivery) private var delivery
    @Default(.eyeBreakIntervalMinutes) private var intervalMinutes
    @Default(.eyeBreakDurationSeconds) private var durationSeconds
    @Default(.eyeBreakIdleResetMinutes) private var idleResetMinutes

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .eyeBreakEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remind me to rest my eyes")
                        Text("After every \(intervalMinutes) minutes of use, umbar asks you to look about 6 metres (20 feet) away for \(durationSeconds) seconds. It never plays a sound.")
                            .font(.subheadline)
                            .foregroundStyle(permissionMutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                Stepper(value: $intervalMinutes, in: 5...60, step: 5) {
                    LabeledContent("Remind every") {
                        Text("\(intervalMinutes) min")
                    }
                }
                Stepper(value: $durationSeconds, in: 10...60, step: 5) {
                    LabeledContent("Look away for") {
                        Text("\(durationSeconds) s")
                    }
                }
                Stepper(value: $idleResetMinutes, in: 1...15) {
                    LabeledContent("Count as a break after") {
                        Text("\(idleResetMinutes) min idle")
                    }
                }
            } header: {
                Text("Timing")
            } footer: {
                Text("Time away from the keyboard and mouse counts as a break, and so does a locked or sleeping Mac.")
                    .font(.caption)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!enabled)

            Section {
                Picker("Show the reminder in", selection: $delivery) {
                    ForEach(EyeBreakDelivery.allCases) { option in
                        Text(Self.title(for: option)).tag(option)
                    }
                }
                Defaults.Toggle(key: .eyeBreakDeferDuringVideo) {
                    Text("Wait while a full-screen video or presentation is on")
                }
            } header: {
                Text("Reminder")
            } footer: {
                if delivery == .notification {
                    Text("macOS asks once whether umbar may send notifications. If they are not allowed, the reminder appears in the notch instead.")
                        .font(.caption)
                        .foregroundStyle(permissionMutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!enabled)
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Eye break")
    }

    private static func title(for delivery: EyeBreakDelivery) -> LocalizedStringKey {
        switch delivery {
        case .panel: return "Notch"
        case .notification: return "Notification"
        }
    }
}
