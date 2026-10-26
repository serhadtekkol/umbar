//
//  CaffeinateSettings.swift
//  boringNotch
//
//  Settings > Caffeinate (F11, card #83). Durations (AC-11.2) and the
//  battery cut-off (BR-11.1) are fixed by the spec, so they are explained
//  here rather than offered as controls.
//

import Defaults
import SwiftUI

struct CaffeinateSettings: View {
    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .caffeinateEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Caffeinate in the notch")
                        Text("Keeps the Mac and its display awake. Choose the length in the notch: until you turn it off, 15 minutes, 1 hour or 2 hours.")
                            .font(.subheadline)
                            .foregroundStyle(permissionMutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } footer: {
                Text("On battery power, Caffeinate turns itself off when the charge drops below \(CaffeinatePolicy.lowBatteryThresholdPercent)% and tells you. Closing the lid still puts the Mac to sleep.")
                    .font(.caption)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Caffeinate")
    }
}
