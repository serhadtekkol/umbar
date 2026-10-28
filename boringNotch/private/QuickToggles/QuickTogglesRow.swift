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
    @ObservedObject private var store: QuickTogglesStore
    @Default(.quickTogglesFocusShortcut) private var focusShortcut

    /// `store` is injectable for the Debug frame renderer's fixture.
    init(store: QuickTogglesStore = .shared) { self.store = store }

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
        // Deliberately no animation on `wifiOffArmed`: the Wi-Fi tile widens
        // and its neighbours slid under it mid-transition (seen in the frame
        // renderer). The instant swap is the tap's feedback.
        .animation(.smooth(duration: 0.2), value: store.showingDevices)
        .onAppear { store.refresh() }
        // Panel closed or another page: a pending "turn off?" must not
        // survive to the next time the row is seen.
        .onDisappear { store.disarmWiFiOff() }
        .onChange(of: store.wifiOffArmed) { _, armed in
            guard armed else { return }
            AccessibilityNotification.Announcement(String(
                localized: "quickToggles.wifi.confirmOff.announcement",
                defaultValue: "Turn off Wi-Fi? Click again to confirm."
            )).post()
        }
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
                    glyph
                }
                Text(name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .fixedSize()
                if let actionCaption {
                    Text(actionCaption)
                        .font(.caption2)
                        .opacity(0.75)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: QuickTogglesRow.height)
            .foregroundStyle(foreground)
            .background(Capsule().fill(background))
            .overlay {
                if isWarning {
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
    /// The orange outline and text: something needs the user's attention
    /// before the tile does its usual thing. The caption always says what.
    private var isWarning: Bool { [.denied, .failed, .confirmingOff].contains(tile.state) }
    private var foreground: Color {
        if isOn { return .black }
        if isWarning { return .orange }
        return .white
    }
    private var background: Color { isOn ? .white.opacity(0.92) : .white.opacity(0.12) }

    @ViewBuilder private var glyph: some View {
        switch kind {
        case .bluetooth:
            // SF Symbols has no Bluetooth rune (`bluetooth` drew nothing).
            BluetoothGlyph()
                .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                .frame(width: 6, height: 10)
                .frame(width: 12)
        case .wifi:
            switch tile.state {
            case .off: symbol("wifi.slash")
            case .confirmingOff: symbol("wifi.exclamationmark")
            default: symbol("wifi")
            }
        case .focus: symbol("moon.fill")
        case .appearance: symbol("circle.lefthalf.filled")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.caption.weight(.semibold))
    }

    private var name: String {
        switch kind {
        case .wifi: return String(localized: "quickToggles.wifi", defaultValue: "Wi-Fi")
        case .bluetooth: return String(localized: "quickToggles.bluetooth", defaultValue: "Bluetooth")
        case .focus: return String(localized: "quickToggles.focus", defaultValue: "Focus")
        case .appearance: return String(localized: "quickToggles.darkMode", defaultValue: "Dark Mode")
        }
    }

    /// Said after the name when the tile is not a plain on/off switch: what a
    /// tap will do, so the state is never colour-only. After the name, not in
    /// its place: "İzin ver…" alone did not say which toggle it was, and its
    /// ellipsis read as a truncated label.
    private var actionCaption: String? {
        switch tile.state {
        case .on, .off, .unknown, .working, .unavailable: return nil
        case .askPermission: return String(localized: "quickToggles.state.allow", defaultValue: "Allow")
        case .denied: return String(localized: "quickToggles.state.denied", defaultValue: "Not allowed")
        case .needsSetup: return String(localized: "quickToggles.state.setUp", defaultValue: "Set up")
        case .failed: return String(localized: "quickToggles.state.retry", defaultValue: "Retry")
        case .confirmingOff: return String(localized: "quickToggles.state.confirmOff", defaultValue: "Turn off?")
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
        case .confirmingOff: return String(localized: "quickToggles.value.confirmingOff", defaultValue: "On, waiting for confirmation to turn off")
        }
    }

    private var hint: String {
        switch tile.action {
        case .toggle where tile.state == .confirmingOff:
            return String(localized: "quickToggles.hint.confirmOff", defaultValue: "Click again to turn off Wi-Fi")
        case .toggle:
            return String(localized: "quickToggles.hint.toggle", defaultValue: "Click to switch on or off")
        case .armOff:
            return String(localized: "quickToggles.hint.armOff", defaultValue: "Click to turn off. You will be asked to click again.")
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

/// The Bluetooth rune, drawn to stroke at caption size.
private struct BluetoothGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()
        path.move(to: p(0, 0.27))
        path.addLine(to: p(1, 0.73))
        path.addLine(to: p(0.5, 1))
        path.addLine(to: p(0.5, 0))
        path.addLine(to: p(1, 0.27))
        path.addLine(to: p(0, 0.73))
        return path
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
