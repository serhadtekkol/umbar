//
//  TabButton.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-24.
//

import SwiftUI

/// One page tab. Unselected: icon only, the label in the tooltip and for
/// VoiceOver. Selected: icon plus label on a `raisedStrong` capsule, so the
/// page you are on is named in words, not only by a glyph (Can's review).
struct TabButton: View {
    let tab: PanelTab
    let selected: Bool
    let onClick: () -> Void

    static let height: CGFloat = 26

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 4) {
                icon
                    .frame(width: 14, height: 14)
                if selected {
                    Text(tab.label)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, selected ? 10 : 7)
            .frame(minWidth: 28, minHeight: Self.height)
            .foregroundStyle(selected ? PageTokens.textPrimary : PageTokens.textSecondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab.label)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var icon: some View {
        switch tab.icon {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
        }
    }
}
