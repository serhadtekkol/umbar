//
//  MirrorViews.swift
//  boringNotch
//
//  The Ayna page (the last panel tab, there only while the mirror is on)
//  and the mirror's Settings section.
//
//  The page is one large preview, centred and as tall as the page, with a
//  small camera on/off status beside it. Showing the page starts the
//  camera; leaving it stops it (MirrorPolicy rule 3).
//

import AVFoundation
import Defaults
import SwiftUI

/// The live page: reports whether it is in front of the user and draws
/// what `MirrorCamera` says.
struct MirrorPageLive: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var camera = MirrorCamera.shared
    @State private var onScreen = false

    /// Open on Ayna. `currentView` changes the moment another tab is
    /// picked, before the page transition, so the camera stops on the click.
    private var visible: Bool {
        onScreen && vm.notchState == .open && coordinator.currentView == .mirror
    }

    var body: some View {
        MirrorPageContent(state: camera.tileState, previewLayer: camera.previewLayer, onTap: camera.tap)
            .onAppear { onScreen = true }
            .onChange(of: visible, initial: true) { _, now in
                camera.setTileVisible(now, owner: vm)
            }
            // Told directly, not through `visible`: a view that is gone may
            // not get its onChange.
            .onDisappear {
                onScreen = false
                camera.setTileVisible(false, owner: vm)
            }
    }
}

/// Values in, view out, so the offscreen render can draw every state with
/// a placeholder instead of a camera.
struct MirrorPageContent: View {
    let state: MirrorTileState
    let previewLayer: AVCaptureVideoPreviewLayer?
    let onTap: () -> Void
    /// Render only: stands in for the camera picture in the `.live` state.
    var livePlaceholder: AnyView? = nil

    /// Built-in Mac cameras are 16:9; the fill gravity crops anything else.
    private static let aspect: CGFloat = 16 / 9
    private static let radius: CGFloat = PageTokens.tileRadius

    private static let statusWidth: CGFloat = 150

    var body: some View {
        // The preview takes the page's full height and its width follows
        // from the aspect; measured, because an aspect-fit view proposes
        // its width-derived height to the page and overflows it.
        GeometryReader { geometry in
            let height = geometry.size.height
            let width = min(height * Self.aspect,
                            geometry.size.width - Self.statusWidth - PageTokens.l)
            HStack(alignment: .center, spacing: PageTokens.l) {
                preview
                    .frame(width: width, height: width / Self.aspect)
                status
                    .frame(width: Self.statusWidth, alignment: .leading)
            }
            .frame(width: geometry.size.width, height: height, alignment: .center)
        }
    }

    private var preview: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(PageTokens.raised)
                if state.showsCameraPicture {
                    live.excludedFromScreenCapture()
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(String(localized: "mirror.tile.a11y", defaultValue: "Mirror"))
        .accessibilityValue(statusTitle)
        .accessibilityHint(help)
    }

    @ViewBuilder private var live: some View {
        if let livePlaceholder {
            livePlaceholder
        } else if let previewLayer {
            // Flipped so it behaves like a mirror: raise your right hand,
            // the hand on the right of the picture moves.
            MirrorPreviewLayerView(previewLayer: previewLayer)
                .scaleEffect(x: -1, y: 1)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: glyph)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(state == .denied ? PageTokens.danger : PageTokens.textSecondary)
                .accessibilityHidden(true)
            Text(caption)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PageTokens.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 12)
        }
    }

    /// The small on/off status beside the preview. The dot always comes
    /// with the words, so it is not told by colour alone.
    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state == .live ? Self.onGreen : PageTokens.textSecondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(statusTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PageTokens.textPrimary)
            }
            Text(statusDetail)
                .font(.system(size: 11))
                .foregroundStyle(PageTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// systemGreen, dark: the colour of macOS's own camera indicator.
    private static let onGreen = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)

    private var statusTitle: String {
        state == .live
            ? String(localized: "mirror.page.status.on", defaultValue: "Camera on")
            : String(localized: "mirror.page.status.off", defaultValue: "Camera off")
    }

    private var statusDetail: String {
        switch state {
        case .live: String(localized: "mirror.page.status.on.detail",
                           defaultValue: "Turns off when you leave this tab, close the panel, or after 5 minutes.")
        case .idle: String(localized: "mirror.page.idle", defaultValue: "Tap the mirror to turn the camera on.")
        case .needsAccess, .denied, .unavailable: help
        }
    }

    private var glyph: String {
        switch state {
        case .idle, .live: "web.camera"
        case .needsAccess: "lock"
        case .denied: "exclamationmark.triangle"
        case .unavailable: "video.slash"
        }
    }

    private var caption: String {
        switch state {
        case .idle, .live: String(localized: "mirror.page.status.off", defaultValue: "Camera off")
        case .needsAccess: String(localized: "mirror.tile.needsAccess", defaultValue: "Allow camera")
        case .denied: String(localized: "mirror.tile.denied", defaultValue: "Camera access off")
        case .unavailable: String(localized: "mirror.tile.unavailable", defaultValue: "No camera")
        }
    }

    private var help: String {
        switch state {
        case .idle: String(localized: "mirror.page.idle.help", defaultValue: "Turn the camera on")
        case .live: String(localized: "mirror.tile.live.help", defaultValue: "Turn the camera off")
        case .needsAccess: String(localized: "mirror.tile.needsAccess.help", defaultValue: "Ask macOS for camera access")
        case .denied: String(localized: "mirror.tile.denied.help", defaultValue: "Open camera privacy settings")
        case .unavailable: String(localized: "mirror.tile.unavailable.help", defaultValue: "Connect a camera to use the mirror")
        }
    }
}

private struct MirrorPreviewLayerView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.layer = previewLayer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = nsView.bounds
        CATransaction.commit()
    }
}

// MARK: - Settings

/// Goes in Settings > General under "Camera and microphone".
struct MirrorSettingsSection: View {
    @ObservedObject private var camera = MirrorCamera.shared
    @Default(.mirrorEnabled) private var enabled

    var body: some View {
        Section {
            // Not a Defaults.Toggle: turning it on is the user action that
            // may raise the camera prompt, so it goes through MirrorCamera.
            Toggle(isOn: Binding(get: { enabled }, set: { camera.userSetEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "mirror.settings.enabled", defaultValue: "Mirror tab in the panel"))
                    Text(String(localized: "mirror.settings.enabled.detail",
                                defaultValue: "Adds a Mirror tab to the panel. The camera turns on while that tab is open, and off when you leave it, close the panel, or after 5 minutes. The picture is never recorded or sent anywhere."))
                        .font(.subheadline)
                        .foregroundStyle(permissionMutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if enabled && camera.access == .denied {
                HStack {
                    Text(String(localized: "mirror.settings.denied", defaultValue: "Camera access is off for umbar."))
                        .foregroundStyle(permissionMutedText)
                    Spacer()
                    Button(String(localized: "mirror.settings.openPrivacy", defaultValue: "Open System Settings")) {
                        MirrorCamera.openPrivacySettings()
                    }
                }
            }
        } header: {
            Text(String(localized: "mirror.settings.header", defaultValue: "Mirror"))
        }
    }
}
