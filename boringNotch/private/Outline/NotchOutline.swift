//
//  NotchOutline.swift
//  boringNotch
//
//  A hairline of light around the island so its edge reads against a dark
//  wallpaper or a dark app. Drawn like the edge glow: a tight shadow of the
//  composited silhouette, so the ears, the drip and the open panel all get
//  one outline and nothing is drawn over the content.
//

import Defaults
import SwiftUI

extension Defaults.Keys {
    /// On by default (the user asked for it). Settings > Appearance.
    static let notchOutlineEnabled = Key<Bool>("notchOutlineEnabled", default: true)
    /// 0…1; 0.5 is the shipped look.
    static let notchOutlineStrength = Key<Double>("notchOutlineStrength", default: 0.5)
}

struct NotchOutline: ViewModifier {
    @Default(.notchOutlineEnabled) private var enabled
    @Default(.notchOutlineStrength) private var strength
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let s = enabled ? min(max(strength, 0), 1) * (contrast == .increased ? 1.5 : 1) : 0
        content
            .compositingGroup()
            .shadow(color: .white.opacity(0.55 * s), radius: 0.5)
            .shadow(color: .white.opacity(0.18 * s), radius: 1.5)
    }
}
