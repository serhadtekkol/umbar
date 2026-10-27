//
//  QuickTogglesRow.swift
//  boringNotch
//
//  F20 UI: the compact toggles row on the "Now" page. Every permission and
//  failure state renders inline in the tile itself; nothing here opens a
//  popover, which would fight the notch's hover-to-close logic (same reason
//  as CaffeinateControl).
//

import Defaults
import SwiftUI

struct QuickTogglesRow: View {
    @ObservedObject private var store = QuickTogglesStore.shared
    @Default(.quickTogglesFocusShortcut) private var focusShortcut

    /// Row height; the "Now" page has ~150 pt under the header and the music
    /// block needs 128 of it, so the row stays one line.
    static let height: CGFloat = 22

    var body: some View {
        HStack(spacing: 6) {
            ForEach(QuickToggleKind.allCases, id: \.self) { kind in
                QuickToggleTile(kind: kind, tile: store.tile(for: kind)) {
                    Task { await store.activate(kind) }
                }
            }
            if store.showingDevices {
                deviceStrip
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.height)
        .animation(.smooth(duration: 0.2), value: store.showingDevices)
        .onAppear { store.refresh() }
        // The store reads the Shortcut name through a closure, which SwiftUI
        // cannot observe; keying on it re-renders the Focus tile when the
        // name is chosen in Settings while the panel is open.
        .id(focusShortcut)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "quickToggles.group", defaultValue: "Quick toggles"))
    }

    private var deviceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if store.devices.isEmpty {
                    Text(String(localized: "quickToggles.bluetooth.noDevices", defaultValue: "No paired devices"))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                ForEach(store.devices) { device in
                    QuickDeviceChip(device: device, activity: store.deviceActivity[device.id]) {
                        Task { await store.toggleDevice(device.id) }
                    }
                }
                Button {
                    store.backend.open(.bluetooth)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption2.bold())
                        .frame(width: 22, height: Self.height)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help(String(localized: "quickToggles.bluetooth.settings", defaultValue: "Bluetooth Settings"))
            }
        }
    }
}

// MARK: - Tile

private struct QuickToggleTile: View {
    let kind: QuickToggleKind
    let tile: QuickTile
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if tile.state == .working {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                        .font(.caption.weight(.semibold))
                }
                Text(caption)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(height: QuickTogglesRow.height)
            .foregroundStyle(foreground)
            .background(Capsule().fill(background))
            .overlay {
                if tile.state == .denied || tile.state == .failed {
                    Capsule().strokeBorder(.orange.opacity(0.8), lineWidth: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(tile.action == .none)
        .opacity(tile.state == .unavailable ? 0.45 : 1)
        .help(hint)
        .accessibilityLabel(name)
        .accessibilityValue(stateDescription)
        .accessibilityHint(hint)
        .accessibilityAddTraits(tile.state == .on ? .isSelected : [])
    }

    private var isOn: Bool { tile.state == .on }
    private var foreground: Color {
        if isOn { return .black }
        if tile.state == .denied || tile.state == .failed { return .orange }
        return .white
    }
    private var background: Color { isOn ? .white.opacity(0.92) : .white.opacity(0.12) }

    private var symbol: String {
        switch kind {
        case .wifi: return tile.state == .off ? "wifi.slash" : "wifi"
        case .bluetooth: return "bluetooth"
        case .focus: return "moon.fill"
        case .appearance: return "circle.lefthalf.filled"
        }
    }

    private var name: String {
        switch kind {
        case .wifi: return String(localized: "quickToggles.wifi", defaultValue: "Wi-Fi")
        case .bluetooth: return String(localized: "quickToggles.bluetooth", defaultValue: "Bluetooth")
        case .focus: return String(localized: "quickToggles.focus", defaultValue: "Focus")
        case .appearance: return String(localized: "quickToggles.darkMode", defaultValue: "Dark Mode")
        }
    }

    /// Short text inside the tile. On/off tiles show their name; other states
    /// replace it with what a tap will do, so the state is never colour-only.
    private var caption: String {
        switch tile.state {
        case .on, .off, .unknown, .working, .unavailable: return name
        case .askPermission: return String(localized: "quickToggles.state.allow", defaultValue: "Allow…")
        case .denied: return String(localized: "quickToggles.state.denied", defaultValue: "Not allowed")
        case .needsSetup: return String(localized: "quickToggles.state.setUp", defaultValue: "Set up…")
        case .failed: return String(localized: "quickToggles.state.retry", defaultValue: "Retry")
        }
    }

    private var stateDescription: String {
        switch tile.state {
        case .on: return String(localized: "quickToggles.value.on", defaultValue: "On")
        case .off: return String(localized: "quickToggles.value.off", defaultValue: "Off")
        case .unknown: return String(localized: "quickToggles.value.unknown", defaultValue: "State unknown")
        case .working: return String(localized: "quickToggles.value.working", defaultValue: "Working")
        case .askPermission: return String(localized: "quickToggles.value.askPermission", defaultValue: "Permission needed")
        case .denied: return String(localized: "quickToggles.value.denied", defaultValue: "Permission denied")
        case .needsSetup: return String(localized: "quickToggles.value.needsSetup", defaultValue: "Not set up")
        case .unavailable: return String(localized: "quickToggles.value.unavailable", defaultValue: "Unavailable")
        case .failed: return String(localized: "quickToggles.value.failed", defaultValue: "Last change failed")
        }
    }

    private var hint: String {
        switch tile.action {
        case .toggle:
            return String(localized: "quickToggles.hint.toggle", defaultValue: "Click to switch on or off")
        case .requestPermission:
            return String(localized: "quickToggles.hint.requestBluetooth", defaultValue: "Click to allow umbar to use Bluetooth and list your devices")
        case .openSettings(let pane):
            switch pane {
            case .wifi where tile.state == .denied:
                return String(localized: "quickToggles.hint.wifiAdmin", defaultValue: "Changing Wi-Fi needs an administrator on this Mac. Click to open Wi-Fi Settings.")
            case .bluetooth where tile.state == .off:
                return String(localized: "quickToggles.hint.bluetoothOff", defaultValue: "Bluetooth is off. Click to open Bluetooth Settings.")
            case .bluetoothPrivacy, .automationPrivacy:
                return String(localized: "quickToggles.hint.privacy", defaultValue: "Click to allow it in Privacy & Security")
            default:
                return String(localized: "quickToggles.hint.settings", defaultValue: "Click to open System Settings")
            }
        case .showDevices:
            return String(localized: "quickToggles.hint.devices", defaultValue: "Click to show paired devices")
        case .runShortcut:
            return String(localized: "quickToggles.hint.shortcut", defaultValue: "Click to run your Focus shortcut")
        case .openAppSettings:
            return String(localized: "quickToggles.hint.chooseShortcut", defaultValue: "Click to choose a Focus shortcut in umbar Settings")
        case .none:
            return ""
        }
    }
}

// MARK: - Device chip

private struct QuickDeviceChip: View {
    let device: QuickBluetoothDevice
    let activity: QuickDeviceActivity?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if activity == .connecting || activity == .disconnecting {
                    ProgressView().controlSize(.mini)
                } else if activity == .failed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Image(systemName: device.isAudio ? "headphones" : "dot.radiowaves.left.and.right")
                }
                Text(device.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 110, alignment: .leading)
                if let level = device.battery?.headline {
                    Text(level.formatted(.percent))
                        .monospacedDigit()
                        .foregroundStyle(device.isConnected ? Color.black.opacity(0.6) : Color.white.opacity(0.7))
                }
            }
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .frame(height: QuickTogglesRow.height)
            .foregroundStyle(device.isConnected ? .black : .white)
            .background(Capsule().fill(device.isConnected ? .white.opacity(0.92) : .white.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(device.isConnected
            ? String(localized: "quickToggles.device.disconnect", defaultValue: "Click to disconnect")
            : String(localized: "quickToggles.device.connect", defaultValue: "Click to connect"))
        .accessibilityLabel(device.name)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        switch activity {
        case .connecting?: parts.append(String(localized: "quickToggles.device.connecting", defaultValue: "Connecting"))
        case .disconnecting?: parts.append(String(localized: "quickToggles.device.disconnecting", defaultValue: "Disconnecting"))
        case .failed?: parts.append(String(localized: "quickToggles.device.failed", defaultValue: "Could not connect"))
        case nil:
            parts.append(device.isConnected
                ? String(localized: "quickToggles.device.connected", defaultValue: "Connected")
                : String(localized: "quickToggles.device.notConnected", defaultValue: "Not connected"))
        }
        if let battery = device.battery {
            if let left = battery.left, let right = battery.right {
                parts.append(String(localized: "quickToggles.device.batteryLR", defaultValue: "Left \(left)%, right \(right)%"))
            } else if let single = battery.single {
                parts.append(String(localized: "quickToggles.device.battery", defaultValue: "Battery \(single)%"))
            }
            if let caseLevel = battery.caseLevel {
                parts.append(String(localized: "quickToggles.device.batteryCase", defaultValue: "Case \(caseLevel)%"))
            }
        }
        return parts.joined(separator: ", ")
    }
}
