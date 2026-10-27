//
//  FocusTimerSettings.swift
//  boringNotch
//
//  Settings > Focus timer (F18).
//

import Defaults
import SwiftUI

struct FocusTimerSettings: View {
    @Default(.focusTimerEnabled) private var enabled
    @Default(.focusTimerCustomFocusMinutes) private var customFocus
    @Default(.focusTimerCustomBreakMinutes) private var customBreak
    @Default(.focusTimerLongBreakMinutes) private var longBreak
    @Default(.focusTimerSessionsBeforeLongBreak) private var sessionsBeforeLong
    @Default(.focusTimerRunShortcuts) private var runShortcuts
    @Default(.focusTimerStartShortcut) private var startShortcut
    @Default(.focusTimerStopShortcut) private var stopShortcut

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .focusTimerEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Focus timer")
                        Text("Work in focused sessions with breaks in between. The time left shows next to the notch while it runs. It never plays a sound.")
                            .font(.subheadline)
                            .foregroundStyle(permissionMutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                Stepper(value: $customFocus, in: 5...120, step: 5) {
                    LabeledContent("Custom focus") { Text("\(customFocus) min") }
                }
                Stepper(value: $customBreak, in: 1...30) {
                    LabeledContent("Custom break") { Text("\(customBreak) min") }
                }
                Stepper(value: $longBreak, in: 5...60, step: 5) {
                    LabeledContent("Long break") { Text("\(longBreak) min") }
                }
                Stepper(value: $sessionsBeforeLong, in: 2...8) {
                    LabeledContent("Long break after") { Text("\(sessionsBeforeLong) sessions") }
                }
            } header: {
                Text("Timing")
            } footer: {
                Text("The 25/5 and 50/10 presets are fixed. The third button in the notch uses your custom times. While a focus session runs, eye-break reminders wait for the break.")
                    .font(.caption)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!enabled)

            Section {
                Defaults.Toggle(key: .focusTimerRunShortcuts) {
                    Text("Run a Shortcut when focus starts and ends")
                }
                TextField("Shortcut to run when focus starts", text: $startShortcut)
                    .disabled(!runShortcuts)
                TextField("Shortcut to run when focus ends", text: $stopShortcut)
                    .disabled(!runShortcuts)
            } header: {
                Text("Do Not Disturb")
            } footer: {
                Text("macOS does not let apps switch Focus on or off. Create two shortcuts in the Shortcuts app (for example Set Focus) and type their exact names here. Off by default.")
                    .font(.caption)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!enabled)
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Focus timer")
    }
}
