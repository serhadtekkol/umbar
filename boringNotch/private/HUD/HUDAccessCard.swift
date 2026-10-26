//
//  HUDAccessCard.swift
//  boringNotch
//
//  K13: the HUD is on for fresh installs, but its event tap needs
//  Accessibility, which umbar never asks for at launch or in onboarding
//  (AC-D.4, #59). Instead the notch explains it once, in context:
//
//  - on the first volume change, seen through the CoreAudio listener that
//    VolumeManager already runs (needs no permission), or
//  - on the first panel open, which also covers someone who only uses the
//    brightness keys: brightness changes cannot be observed without the
//    private DisplayServices call, so they are not used as a trigger.
//
//  The system prompt opens only from the card's "Allow" (AC-15.7).
//

import Combine
import Defaults
import SwiftUI

@MainActor
final class HUDAccessCard: ObservableObject {
    static let shared = HUDAccessCard()

    @Published private(set) var isShowing = false

    private var volumeCancellable: AnyCancellable?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    /// Watches for the first volume change while the card can still appear.
    /// Once it has appeared the subscription is dropped (no background work).
    func start() {
        guard !Defaults[.hudAccessCardShown] else { return }
        volumeCancellable = VolumeManager.shared.$lastChangeAt
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in await self?.offerIfNeeded() }
            }
    }

    /// The panel opened. Also the moment to pick up Accessibility granted
    /// later in System Settings, without a relaunch (AC-15.9).
    func notchDidOpen() {
        Task { @MainActor in
            let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
            if authorized {
                if Defaults[.hudReplacement] {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            } else {
                await offerIfNeeded(authorized: false)
            }
        }
    }

    func notchDidClose() {
        hide()
    }

    func allow() {
        hide()
        if Defaults[.accessibilityPromptShown] {
            // macOS shows its prompt once per app; after that only the pane helps.
            PrivacyPane.accessibility.open()
            return
        }
        Defaults[.accessibilityPromptShown] = true
        Task { @MainActor in
            if await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true) {
                await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
            }
        }
    }

    func notNow() {
        hide()
    }

    private func offerIfNeeded(authorized known: Bool? = nil) async {
        guard canOffer(authorized: false) else { return }
        let authorized: Bool
        if let known {
            authorized = known
        } else {
            authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
        }
        // Re-checked after the await: two triggers can race here.
        guard canOffer(authorized: authorized) else { return }
        show()
    }

    private func canOffer(authorized: Bool) -> Bool {
        HUDAccessCardPolicy.shouldOffer(
            hudOn: Defaults[.hudReplacement],
            authorized: authorized,
            alreadyShown: Defaults[.hudAccessCardShown] || isShowing,
            onboardingDone: !BoringViewCoordinator.shared.firstLaunch
        )
    }

    private func show() {
        Defaults[.hudAccessCardShown] = true
        volumeCancellable = nil
        isShowing = true
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: HUDAccessCardPolicy.autoDismissAfter)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        isShowing = false
    }
}

/// Notch content while the card is up. Same black surface and capsule
/// buttons as the notch permission prompts (PermissionsRequestView.swift).
struct HUDAccessCardView: View {
    @ObservedObject private var card = HUDAccessCard.shared
    @Default(.accessibilityPromptShown) private var promptShown

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "dial.medium")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)

            Text("To show volume and brightness in the notch, umbar needs Accessibility access.")
                .font(.subheadline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("Not Now") { card.notNow() }
                .buttonStyle(NotchSecondaryCapsuleButtonStyle())
            Button(promptShown ? "Open System Settings" : "Allow") { card.allow() }
                .buttonStyle(NotchCapsuleButtonStyle())
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}
