//
//  HoverButton.swift
//  boringNotch
//
//  Created by Kraigo on 04.09.2024.
//

import SwiftUI

/// Island icon button. `.medium` is a bare glyph on a 28 pt hit target;
/// `.large` is the one emphasized control (play/pause): the same glyph size
/// on a 32 pt filled circle (`island.buttonBg` / `island.buttonFg`), so it
/// leads by fill, not by glyph size.
struct HoverButton: View {
    var icon: String
    var iconColor: Color = .primary
    var scale: Image.Scale = .medium
    var action: () -> Void
    var contentTransition: ContentTransition = .symbolEffect;

    static let iconSize: CGFloat = 24
    static let prominentSize: CGFloat = 28
    private static let glyphSize: CGFloat = 12
    private static let buttonBg = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
    private static let buttonFg = Color.black

    @State private var isHovering = false

    private var isProminent: Bool { scale == .large }

    var body: some View {
        let size = isProminent ? Self.prominentSize : Self.iconSize

        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: Self.glyphSize, weight: .semibold))
                .foregroundColor(isProminent ? Self.buttonFg : iconColor)
                .contentTransition(contentTransition)
                // The glyph swap (play ↔ pause) needs an animation in its
                // transaction to run the symbol replace; the player sets
                // isPlaying without one.
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: icon)
                .frame(width: size, height: size)
                .background(Circle().fill(background))
                .contentShape(Circle())
        }
        .buttonStyle(IslandPressStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private var background: Color {
        if isProminent {
            return Self.buttonBg.opacity(isHovering ? 0.85 : 1)
        }
        return isHovering ? Color.gray.opacity(0.2) : .clear
    }
}
