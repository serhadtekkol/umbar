//
//  CapturePrivacy.swift
//  boringNotch
//
//  Muhittin L5: tracks whether a view that must not be captured (the
//  clipboard history) is on screen. The notch windows read it to set their
//  sharingType (BoringNotchSkyLightWindow); the policy is
//  CapturePrivacyPolicy.
//

import Combine
import SwiftUI

@MainActor
final class CapturePrivacy: ObservableObject {
    static let shared = CapturePrivacy()

    /// True from the first sensitive view's appearance until
    /// `CapturePrivacyPolicy.restoreDelay` after the last one left.
    @Published private(set) var sensitiveOnScreen = false

    private var tally = SensitiveContentTally()
    private var restore: DispatchWorkItem?

    func appear() {
        tally.appear()
        restore?.cancel()
        restore = nil
        if !sensitiveOnScreen { sensitiveOnScreen = true }
    }

    func disappear() {
        tally.disappear()
        guard !tally.isShowing else { return }
        restore?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.tally.isShowing else { return }
            self.sensitiveOnScreen = false
        }
        restore = work
        DispatchQueue.main.asyncAfter(deadline: .now() + CapturePrivacyPolicy.restoreDelay, execute: work)
    }
}

extension View {
    /// Keeps the notch window out of screen shares and recordings while this
    /// view is on screen. On every notch window, not only the one showing
    /// the view: a second screen's notch excluded for a moment costs nothing.
    func excludedFromScreenCapture() -> some View {
        onAppear { CapturePrivacy.shared.appear() }
            .onDisappear { CapturePrivacy.shared.disappear() }
    }
}
