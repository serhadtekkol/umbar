//
//  LottieAnimationContainer.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 10. 29..
//

import SwiftUI
import Defaults

struct LottieAnimationContainer: View {
    @Default(.selectedVisualizer) var selectedVisualizer

    /// Default visualizer shipped in the bundle. Upstream fetched this same file
    /// (lottiefiles lf20_mniampqn.json, sha256 482fe9cd...d38147) from the
    /// lottiefiles CDN; bundling removes that network call and the remote JSON
    /// parser input (card #41).
    private static let defaultVisualizerURL = Bundle.main.url(
        forResource: "DefaultVisualizer", withExtension: "json"
    )

    var body: some View {
        if let selectedVisualizer {
            LottieView(url: selectedVisualizer.url, speed: selectedVisualizer.speed, loopMode: .loop)
        } else if let bundled = Self.defaultVisualizerURL {
            LottieView(url: bundled, speed: 1.0, loopMode: .loop)
        }
    }
}

#Preview {
    LottieAnimationContainer()
}
