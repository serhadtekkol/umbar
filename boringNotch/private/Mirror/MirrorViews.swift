//
//  MirrorViews.swift
//  boringNotch
//
//  The mirror tile at the trailing end of Şimdi, and its Settings section.
//
//  The tile is the album art's size and shape, so the page keeps one grid.
//  It never starts the camera by appearing: a tap does (MirrorPolicy rule 3).
//

import AVFoundation
import Defaults
import SwiftUI

/// The live tile: reports whether it is in front of the user and draws
/// what `MirrorCamera` says.
struct MirrorTileLive: View {
    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var camera = MirrorCamera.shared
    @State private var onScreen = false

    /// Open on Şimdi. `currentView` changes the moment a tab is picked,
    /// before the page transition, so the camera stops on the click.
    private var visible: Bool {
        onScreen && vm.notchState == .open && coordinator.currentView == .home
    }

    var body: some View {
        MirrorTile(state: camera.tileState, previewLayer: camera.previewLayer, onTap: camera.tap)
            .onAppear { onScreen = true }
            .onChange(of: visible, initial: true) { _, now in
                camera.setTileVisible(now, owner: ObjectIdentifier(vm))
            }
            // Told directly, not through `visible`: a view that is gone may
            // not get its onChange.
            .onDisappear {
                onScreen = false
                camera.setTileVisible(false, owner: ObjectIdentifier(vm))
            }
    }
}

/// Values in, view out, so the offscreen render can draw every state with
/// a placeholder instead of a camera.
struct MirrorTile: View {
    let state: MirrorTileState
    let previewLayer: AVCaptureVideoPreviewLayer?
    let onTap: () -> Void
    /// Render only: stands in for the camera picture in the `.live` state.
    var livePlaceholder: AnyView? = nil

    static let side: CGFloat = 112

    private var radius: CGFloat {
        Defaults[.cornerRadiusScaling] ? MusicPlayerImageSizes.cornerRadiusInset.opened
            : MusicPlayerImageSizes.cornerRadiusInset.closed
    }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(PageTokens.raised)
                if state == .live {
                    live
                } else {
                    placeholder
                }
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(String(localized: "mirror.tile.a11y", defaultValue: "Mirror"))
        .accessibilityValue(caption)
        .accessibilityHint(help)
    }

    @ViewBuilder private var live: some View {
        if let livePlaceholder {
            livePlaceholder
        } else if let previewLayer {
            // Flipped so it behaves like a mirror: raise your right hand,
            // the hand on the right of the tile moves.
            MirrorPreviewLayerView(previewLayer: previewLayer)
                .scaleEffect(x: -1, y: 1)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 6) {
            Image(systemName: glyph)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(state == .denied ? PageTokens.danger : PageTokens.textSecondary)
                .accessibilityHidden(true)
            Text(caption)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PageTokens.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 8)
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
        case .idle: String(localized: "mirror.tile.idle", defaultValue: "Mirror")
        case .live: String(localized: "mirror.tile.live", defaultValue: "Mirror on")
        case .needsAccess: String(localized: "mirror.tile.needsAccess", defaultValue: "Allow camera")
        case .denied: String(localized: "mirror.tile.denied", defaultValue: "Camera access off")
        case .unavailable: String(localized: "mirror.tile.unavailable", defaultValue: "No camera")
        }
    }

    private var help: String {
        switch state {
        case .idle: String(localized: "mirror.tile.idle.help", defaultValue: "Show the camera. It turns off when the panel closes.")
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
                    Text(String(localized: "mirror.settings.enabled", defaultValue: "Mirror on the Now page"))
                    Text(String(localized: "mirror.settings.enabled.detail",
                                defaultValue: "A camera tile beside today's events. The camera turns on only when you tap the tile, and off when the panel closes or you switch pages. The picture is never recorded or sent anywhere."))
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
