//
//  CritterSettingsSection.swift
//  boringNotch
//
//  Settings > Appearance > Idle critter: on/off, how often, which one,
//  whether it may cross while music plays, and a way to see one now.
//

import Defaults
import SwiftUI

struct CritterSettingsSection: View {
    @Default(.critterEnabled) private var enabled
    @Default(.critterFrequency) private var frequency
    @Default(.critterChoice) private var choice

    var body: some View {
        Section {
            Defaults.Toggle(key: .critterEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "critter.settings.enabled", defaultValue: "Send a critter across now and then"))
                    Text(String(localized: "critter.settings.enabled.detail",
                                defaultValue: "Now and then, while the notch is closed and quiet, a small critter eats a row of crumbs under it, slips into the notch and comes out the other side. It never blocks a click."))
                        .font(.subheadline)
                        .foregroundStyle(permissionMutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker(String(localized: "critter.settings.frequency", defaultValue: "How often"), selection: $frequency) {
                ForEach(CritterFrequency.allCases, id: \.self) { option in
                    Text(Self.name(option)).tag(option)
                }
            }
            .disabled(!enabled)
            Picker(String(localized: "critter.settings.character", defaultValue: "Character"), selection: $choice) {
                ForEach(CritterChoice.allCases, id: \.self) { option in
                    Text(Self.name(option)).tag(option)
                }
            }
            .disabled(!enabled)
            Defaults.Toggle(key: .critterWhileMusic) {
                Text(String(localized: "critter.settings.whileMusic", defaultValue: "Also while music plays"))
            }
            .disabled(!enabled)
            LabeledContent {
                Button(String(localized: "critter.settings.preview", defaultValue: "Send one now")) {
                    CritterPreview.requested.send()
                }
            } label: {
                Text(String(localized: "critter.settings.preview.label", defaultValue: "Preview"))
            }
            .disabled(!enabled)
        } header: {
            Text(String(localized: "critter.settings.header", defaultValue: "Idle critter"))
        } footer: {
            Text(String(localized: "critter.settings.footer",
                        defaultValue: "It stays away while the panel is open, while the pointer is on the notch, during a HUD, a live activity or an eye break, in full screen, and while the Mac is locked or asleep. With Reduce Motion on, it does not appear at all."))
                .font(.caption)
                .foregroundStyle(permissionMutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func name(_ frequency: CritterFrequency) -> String {
        switch frequency {
        case .rarely: String(localized: "critter.frequency.rarely", defaultValue: "Rarely (about every 15 min)")
        case .sometimes: String(localized: "critter.frequency.sometimes", defaultValue: "Now and then (about every 5 min)")
        case .often: String(localized: "critter.frequency.often", defaultValue: "Often (about every minute)")
        }
    }

    static func name(_ choice: CritterChoice) -> String {
        switch choice {
        case .mixed: String(localized: "critter.choice.mixed", defaultValue: "A different one each time")
        case .beetle: String(localized: "critter.choice.beetle", defaultValue: "Beetle")
        case .caterpillar: String(localized: "critter.choice.caterpillar", defaultValue: "Caterpillar")
        case .comet: String(localized: "critter.choice.comet", defaultValue: "Comet")
        }
    }
}
