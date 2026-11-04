//
//  SongPeekSettings.swift
//  boringNotch
//
//  Settings › Media: the slider for how long the song name stays under the
//  closed island on a track change. Sits under the switch that turns the
//  sneak peek on, and is dimmed while that switch is off.
//

import SwiftUI

struct SongPeekDurationRow: View {
    @Binding var seconds: Double

    var body: some View {
        let value = SongPeekTiming.seconds(seconds)
        let title = String(localized: "songPeek.settings.duration", defaultValue: "Sneak peek duration")
        LabeledContent {
            HStack(spacing: 8) {
                Slider(
                    value: Binding(get: { value }, set: { seconds = SongPeekTiming.seconds($0) }),
                    in: SongPeekTiming.range,
                    step: SongPeekTiming.step
                ) {
                    Text(title)
                }
                .labelsHidden()
                .frame(minWidth: 120)
                .accessibilityValue(Self.label(value))
                Text(Self.label(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // Room for "10,0 sn" so the slider does not jump as the value changes.
                    .frame(minWidth: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(String(localized: "songPeek.settings.duration.detail",
                            defaultValue: "How long the song name stays under the notch. The volume and brightness indicator keep their own time."))
                    .font(.subheadline)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "3.0 s" / "3,0 sn", in the user's locale.
    static func label(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: 1)))
    }
}
