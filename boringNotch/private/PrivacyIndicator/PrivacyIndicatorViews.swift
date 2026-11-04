//
//  PrivacyIndicatorViews.swift
//  boringNotch
//
//  F23 UI: the closed-notch ear, the Şimdi row and the settings section.
//
//  Colours follow the macOS convention (green camera, orange microphone)
//  and always come with a shape: the video and microphone glyphs, so the
//  two are told apart without colour.
//

import Defaults
import SwiftUI

private enum PrivacyTokens {
    static let textPrimary = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
    static let raised = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
    /// systemGreen / systemOrange dark-mode values, as in the menu bar dot.
    static let camera = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let microphone = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
}

/// The words for a usage, shared by the row and VoiceOver.
enum PrivacyIndicatorText {
    static var camera: String { String(localized: "privacy.camera", defaultValue: "Camera") }
    static var cameraInUse: String { String(localized: "privacy.camera.inUse", defaultValue: "Camera in use") }
    static var microphoneInUse: String { String(localized: "privacy.microphone.inUse", defaultValue: "Microphone in use") }

    static func microphoneApps(_ apps: [String]) -> String {
        String(format: String(localized: "privacy.microphone.apps", defaultValue: "Microphone: %@"),
               apps.formatted(.list(type: .and)))
    }

    static func microphoneLine(_ usage: PrivacyUsage) -> String {
        usage.microphoneApps.isEmpty ? microphoneInUse : microphoneApps(usage.microphoneApps)
    }

    /// One sentence for VoiceOver, e.g. "Camera in use, Microphone: Zoom".
    static func accessibility(_ usage: PrivacyUsage) -> String {
        var parts: [String] = []
        if usage.camera { parts.append(cameraInUse) }
        if usage.microphone { parts.append(microphoneLine(usage)) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Closed-notch ear

/// A narrow tab on the trailing edge of the closed notch, outside
/// `CaffeinateClosedBadge` when that one is showing, so the two never
/// cover each other. Declared before Caffeinate's badge in ContentView so
/// Caffeinate's ear draws over this one's flat inner end.
struct PrivacyClosedBadge: View {
    @ObservedObject private var monitor = PrivacyIndicatorMonitor.shared
    @ObservedObject private var caffeinate = CaffeinateService.shared
    let isClosed: Bool
    let height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = isClosed && height > 0 && monitor.usage.isActive
        let inner = caffeinate.isActive ? CaffeinateClosedBadge.width(height: height) : 0
        ZStack {
            if shown {
                PrivacyClosedEar(usage: monitor.usage, height: height, innerWidth: inner)
                    .transition(.ear(inward: -(inner + PrivacyClosedEar.width), reduce: reduceMotion))
            }
        }
        .animation(UmbarMotion.ear(reduce: reduceMotion), value: shown)
        .animation(UmbarMotion.ear(reduce: reduceMotion), value: inner)
    }
}

/// The tab itself, values in, so the renderer can draw it beside a fixture
/// Caffeinate ear.
struct PrivacyClosedEar: View {
    let usage: PrivacyUsage
    let height: CGFloat
    /// Width of the trailing ears already out (Caffeinate's), which this
    /// one sits beyond. Its black runs under them, so there is no seam.
    let innerWidth: CGFloat

    static let width: CGFloat = 18

    var body: some View {
        let total = innerWidth + Self.width
        VStack(spacing: 3) {
            if usage.camera { glyph("video.fill", PrivacyTokens.camera) }
            if usage.microphone { glyph("mic.fill", PrivacyTokens.microphone) }
        }
        .frame(width: Self.width, height: height)
        .frame(width: total, alignment: .trailing)
        .background(.black, in: UnevenRoundedRectangle(bottomTrailingRadius: 8, topTrailingRadius: 0))
        .offset(x: total)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PrivacyIndicatorText.accessibility(usage))
    }

    private func glyph(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(tint)
            .frame(height: 9)
    }
}

// MARK: - Şimdi row

/// One capsule line under Today naming what is in use. Draws nothing when
/// nothing is.
struct PrivacyUsageRow: View {
    let usage: PrivacyUsage

    var body: some View {
        if usage.isActive {
            HStack(spacing: 6) {
                if usage.camera {
                    segment("video.fill", PrivacyTokens.camera,
                            usage.microphone ? PrivacyIndicatorText.camera : PrivacyIndicatorText.cameraInUse)
                        .fixedSize()
                }
                if usage.camera && usage.microphone {
                    Text(verbatim: "·").foregroundStyle(PrivacyTokens.textPrimary.opacity(0.5))
                }
                if usage.microphone {
                    // Beside the mic glyph the names alone say it; the
                    // "Microphone:" prefix would push them into truncation.
                    segment("mic.fill", PrivacyTokens.microphone,
                            usage.microphoneApps.isEmpty
                                ? PrivacyIndicatorText.microphoneInUse
                                : usage.microphoneApps.formatted(.list(type: .and)))
                }
            }
            .font(.system(size: 11, weight: .medium))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(PrivacyTokens.raised, in: Capsule())
            .help(PrivacyIndicatorText.accessibility(usage))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PrivacyIndicatorText.accessibility(usage))
        }
    }

    private func segment(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .foregroundStyle(PrivacyTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

// MARK: - Settings

/// Goes in Settings > General under the live activities.
struct PrivacyIndicatorSettingsSection: View {
    var body: some View {
        Section {
            Defaults.Toggle(key: .privacyIndicatorEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "privacy.settings.enabled", defaultValue: "Show when the camera or microphone is in use"))
                    Text(String(localized: "privacy.settings.enabled.detail",
                                defaultValue: "A dot beside the closed notch, and on the Now page the apps using the microphone. macOS does not tell other apps which one uses the camera, so the camera is shown without a name. umbar never turns the microphone on; the camera only for the mirror, while its tab is open. While the mirror is on, the camera dot is hidden."))
                        .font(.subheadline)
                        .foregroundStyle(permissionMutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text(String(localized: "privacy.settings.header", defaultValue: "Camera and microphone"))
        }
    }
}
