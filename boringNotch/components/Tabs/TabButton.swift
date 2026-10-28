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
/// The capsule is the tab's own background, so it resizes with the label.
struct TabButton: View {
    let tab: PanelTab
    let selected: Bool
    let onClick: () -> Void

    /// Every tab is this tall, selected or not, so the capsule never changes
    /// height and stays centred on the bar.
    static let height: CGFloat = 28
    /// Unselected: a 14 pt glyph in a 28 pt circle (the §3.6 minimum hit
    /// target). Selected: glyph + label.
    private static let iconOnlyPadding: CGFloat = 7
    private static let labelledPadding: CGFloat = 10

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 5) {
                icon
                    .frame(width: 14, height: 14)
                if selected {
                    Text(tab.label)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .transition(labelTransition)
                }
            }
            .padding(.horizontal, selected ? Self.labelledPadding : Self.iconOnlyPadding)
            // A fixed height (not minHeight): the capsule wraps exactly the
            // glyph + label + padding of whichever tab it sits on.
            .frame(height: Self.height)
            .frame(minWidth: Self.height)
            // The capsule is the tab's own background, not a shared one that
            // travels: it widens with the label on the same layout spring, so
            // label and capsule never come apart mid-switch.
            .background {
                Capsule()
                    .fill(PageTokens.raisedStrong)
                    .opacity(selected ? 1 : 0)
            }
            // Label and capsule are clipped together to the widening tab, so
            // the label never draws past its own capsule.
            .clipShape(Capsule())
            .foregroundStyle(selected ? PageTokens.textPrimary : PageTokens.textSecondary)
            .contentShape(Capsule())
        }
        .buttonStyle(IslandPressStyle())
        .help(tab.label)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The label grows in from the glyph while its tab widens; on the tab
    /// being left it fades fast so it never overlaps the neighbour sliding in.
    private var labelTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.16).delay(0.06)),
            removal: .opacity.animation(.easeIn(duration: 0.06))
        )
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
