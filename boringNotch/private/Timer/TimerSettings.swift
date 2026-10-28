//
//  TimerSettings.swift
//  boringNotch
//
//  Settings > Timer (F25).
//

import Defaults
import SwiftUI

struct TimerSettings: View {
    @Default(.timerEnabled) private var enabled
    @Default(.timerCustomMinutes) private var customMinutes

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .timerEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Timer and stopwatch")
                        Text("A countdown and a stopwatch on the Tools page, in the same card as the focus timer. The time shows next to the notch while it runs.")
                            .font(.subheadline)
                            .foregroundStyle(permissionMutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                Stepper(value: $customMinutes, in: TimerEngine.minuteRange) {
                    LabeledContent("Custom length") { Text("\(customMinutes) min") }
                }
            } header: {
                Text("Timing")
            } footer: {
                Text("The 1, 5, 10 and 25 minute presets are fixed. The custom length can also be changed on the card.")
                    .font(.caption)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!enabled)

            Section {
                Defaults.Toggle(key: .timerNotifies) {
                    Text("Send a notification when the timer ends")
                }
                Defaults.Toggle(key: .timerPlaysSound) {
                    Text("Play a sound when the timer ends")
                }
            } header: {
                Text("When time is up")
            } footer: {
                Text("The notch always shows the end. The notification needs umbar to be allowed in System Settings > Notifications; umbar does not ask for it here. The sound is off by default.")
                    .font(.caption)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!enabled)
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Timer")
    }
}
