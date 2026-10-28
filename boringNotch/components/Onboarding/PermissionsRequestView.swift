//
//  PermissionsRequestView.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-23.
//
//  In-context permission prompts (AC-1.12, card #59). Nothing here asks the
//  system for a permission on its own: every system dialog starts from an
//  explicit "Allow Access" click, after a one-sentence reason. The file keeps
//  its upstream name so the Xcode project needs no change; it is shared by
//  Settings and the notch, not only by onboarding.
//

import AppKit
import EventKit
import SwiftUI

/// The states a permission prompt distinguishes (§5 permission rule): never
/// asked, granted, turned off by the user, and blocked by an administrator.
enum PermissionState: Equatable {
    case notDetermined
    case granted
    case denied
    /// Screen Time or a configuration profile; the user cannot change it, so
    /// the prompt offers no button (design-language §7).
    case restricted

    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .fullAccess:
            self = .granted
        case .notDetermined:
            self = .notDetermined
        case .restricted:
            self = .restricted
        default:
            // .writeOnly cannot read events, so for umbar it is as good as
            // .denied: the user can turn full access on in System Settings.
            self = .denied
        }
    }

    /// Asked and not granted: no system prompt will appear again.
    var isBlocked: Bool { self == .denied || self == .restricted }
}

/// One sentence for the restricted state, shared by every prompt.
let permissionRestrictedMessage: LocalizedStringKey = "An administrator has turned off this access on this Mac. Only they can change it."

extension PermissionState {
    func glyph(_ feature: String) -> String {
        switch self {
        case .denied: "exclamationmark.circle"
        case .restricted: "lock"
        case .notDetermined, .granted: feature
        }
    }

    func message(reason: LocalizedStringKey, denied: LocalizedStringKey) -> LocalizedStringKey {
        switch self {
        case .denied: denied
        case .restricted: permissionRestrictedMessage
        case .notDetermined, .granted: reason
        }
    }
}

/// The System Settings › Privacy & Security pane behind each permission.
enum PrivacyPane: String {
    case calendars = "Privacy_Calendars"
    case reminders = "Privacy_Reminders"
    case accessibility = "Privacy_Accessibility"

    func open() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(rawValue)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

/// Secondary text on Settings and onboarding surfaces. `.secondary`
/// (secondaryLabelColor) measures under 4.5:1 on the light materials at
/// subheadline size, so muted copy uses the primary label at reduced opacity.
var permissionMutedText: some ShapeStyle { HierarchicalShapeStyle.primary.opacity(0.7) }

// MARK: - Settings form

/// Inline pre-prompt for a Settings form section. Renders nothing once the
/// permission is granted.
struct PermissionPrompt: View {
    let state: PermissionState
    let systemImage: String
    let title: LocalizedStringKey
    let reason: LocalizedStringKey
    let deniedMessage: LocalizedStringKey
    let pane: PrivacyPane
    var onNotNow: (() -> Void)? = nil
    let onAllow: () -> Void

    var body: some View {
        if state != .granted {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: state.glyph(systemImage))
                    .foregroundStyle(state.isBlocked ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.effectiveAccent))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.headline)
                    Text(state.message(reason: reason, denied: deniedMessage))
                        .font(.subheadline)
                        .foregroundStyle(permissionMutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        if state == .denied {
                            Button("Open System Settings") { pane.open() }
                        } else if state == .notDetermined {
                            Button("Allow Access", action: onAllow)
                        }
                        if let onNotNow {
                            Button("Not Now", action: onNotNow)
                        }
                    }
                    .controlSize(.regular)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .contain)
        }
    }
}

// MARK: - Notch

/// White capsule on the always-black notch: 21:1 label contrast, independent
/// of the user's accent colour.
struct NotchCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// The quieter choice next to a `NotchCapsuleButtonStyle` button: white
/// label on white 18 % over black, 13.6:1. Same fill as the caffeinate chips.
struct NotchSecondaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.white.opacity(0.18)))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// Full-size pre-prompt that stands in for a notch widget until the
/// permission it needs is granted.
struct NotchPermissionPrompt: View {
    let state: PermissionState
    let systemImage: String
    let title: LocalizedStringKey
    let reason: LocalizedStringKey
    let deniedMessage: LocalizedStringKey
    let pane: PrivacyPane
    let onAllow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: state.glyph(systemImage))
                    .accessibilityHidden(true)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)

            Text(state.message(reason: reason, denied: deniedMessage))
                .font(.caption)
                .foregroundStyle(Color(white: 0.65))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            Group {
                if state == .denied {
                    Button("Open System Settings") { pane.open() }
                } else if state == .notDetermined {
                    Button("Allow Access", action: onAllow)
                }
            }
            .buttonStyle(NotchCapsuleButtonStyle())
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

/// One-row prompt for a secondary permission inside a notch widget that
/// already works without it (Reminders inside the calendar).
struct NotchPermissionBanner: View {
    let state: PermissionState
    let systemImage: String
    let reason: LocalizedStringKey
    let deniedMessage: LocalizedStringKey
    let pane: PrivacyPane
    let onAllow: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        // Two rows so the reason is never truncated in the 215 pt widget,
        // in either language.
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: state.glyph(systemImage))
                    .font(.caption)
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)

                Text(state.message(reason: reason, denied: deniedMessage))
                    .font(.caption2)
                    .foregroundStyle(Color(white: 0.65))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(white: 0.65))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss"))
            }

            Group {
                if state == .denied {
                    Button("Open System Settings") { pane.open() }
                } else if state == .notDetermined {
                    Button("Allow Access", action: onAllow)
                }
            }
            .buttonStyle(NotchCapsuleButtonStyle())
            .padding(.leading, 18)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}
