//
//  WelcomeView.swift
//  boringNotch
//
//  Created by Richard Kunkli on 2024. 09. 26..
//

import SwiftUI

struct WelcomeView: View {
    var onGetStarted: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 8) {
                // "logo2" carries light and dark renditions of AppIcon.icon,
                // exported with ictool from design/ (card #54).
                Image("logo2")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                    .accessibilityHidden(true)
                    .padding(.bottom, 12)
                Text("umbar")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text("Welcome")
                    .font(.title)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 32)
                Button {
                    onGetStarted?()
                } label: {
                    Text("Get started")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                }
                .buttonStyle(BorderedProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            Spacer()
            // GPL-3.0 attribution for the upstream project; keep it visible
            // (card #40, see NOTICE).
            // .primary at 65% rather than .secondary: secondaryLabelColor on the
            // light material measures ~3.8:1, under AA for footnote-size text.
            Text("umbar is a fork of boring.notch by TheBoredTeam, GPL-3.0")
                .font(.footnote)
                .foregroundStyle(.primary.opacity(0.65))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.bottom, 52)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background {
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .ignoresSafeArea()
        }
    }
}

#Preview {
    WelcomeView()
}
