//
//  ClosedSongTitle.swift
//  boringNotch
//
//  The song name in the closed island's left ear. A name wider than its
//  slot scrolls (MarqueeText); under Reduce Motion it stands still and is
//  cut off with an ellipsis instead. Width comes from ClosedMusicLayout.
//

import SwiftUI

struct ClosedSongTitle: View {
    let title: String
    let reduceMotion: Bool

    /// Neutral, not the album colour: the island is black in both
    /// appearances, and white at 0.85 holds ~15:1 on it whatever the art
    /// is. The spectrum beside it already carries the colour.
    private let color = Color.white.opacity(0.85)

    var body: some View {
        Group {
            if reduceMotion {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(color)
                    .frame(width: ClosedMusicLayout.titleWidth, alignment: .leading)
            } else {
                MarqueeText(.constant(title), textColor: color, minDuration: 1,
                            frameWidth: ClosedMusicLayout.titleWidth)
            }
        }
        .umbarFont(.display, size: 13)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}
