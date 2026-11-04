//
//  TypefaceSettingsSection.swift
//  boringNotch
//
//  Settings › Appearance › Typeface: the picker, and a strip drawn like the
//  closed island so the choice is seen before the notch is hovered.
//

import Defaults
import SwiftUI

struct TypefaceSettingsSection: View {
    @Default(.umbarTypeface) private var typeface

    var body: some View {
        Section {
            Picker(String(localized: "typeface.settings.picker", defaultValue: "Typeface"), selection: $typeface) {
                ForEach(UmbarTypeface.allCases) { face in
                    Text(face.displayName).tag(face)
                }
            }
            TypefacePreview()
                .environment(\.umbarTypeface, typeface)
        } header: {
            Text(String(localized: "typeface.settings.header", defaultValue: "Notch text"))
        } footer: {
            Text(String(localized: "typeface.settings.footer",
                        defaultValue: "Used for the song name, clocks, percentages and titles in the notch. Longer text, such as calendar details, stays in the system font so it reads easily. Doto and Pixelify Sans are included under the SIL Open Font License."))
                .font(.caption)
                .foregroundStyle(permissionMutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension UmbarTypeface {
    var displayName: String {
        switch self {
        case .system: return String(localized: "typeface.system", defaultValue: "System")
        case .rounded: return String(localized: "typeface.rounded", defaultValue: "System Rounded")
        case .monospaced: return String(localized: "typeface.monospaced", defaultValue: "Monospace")
        case .dotMatrix: return String(localized: "typeface.dotMatrix", defaultValue: "Dot matrix")
        case .pixel: return String(localized: "typeface.pixel", defaultValue: "Pixel")
        }
    }
}

/// The song name and a clock on black, at the island's own sizes. The
/// island is black in both appearances, so the strip is too.
private struct TypefacePreview: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 12))
                .foregroundStyle(.gray)
            // A song name, not UI copy: the same in every language, with
            // the Turkish letters a face must have (ğ ş ı İ ç ö ü).
            Text(verbatim: "Gözlerin İstanbul'u Dinliyor · Çağrı Şıklar")
                .umbarFont(.display, size: 13)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(verbatim: "04:18 · 62%")
                .umbarFont(.numeric, size: 11, weight: 600, design: .rounded)
                .foregroundStyle(.gray)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "typeface.settings.preview", defaultValue: "Preview of the chosen typeface"))
    }
}
