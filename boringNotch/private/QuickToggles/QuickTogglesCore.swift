//
//  QuickTogglesCore.swift
//  boringNotch
//
//  F20 quick toggles: the state model, the tile mapping and the store.
//  Foundation + Combine only, so umbarTests can compile this file by
//  membership and drive the store with a fake backend. Everything that
//  touches CoreWLAN, IOBluetooth, Intents or AppleScript lives in
//  QuickTogglesSystemBackend.swift.
//

import Combine
import Foundation

// MARK: - System inputs

/// A privacy permission as the toggles need it. `.restricted` (MDM, parental
/// controls) is kept apart from `.denied` only so the mapping can be tested;
/// both send the user to System Settings.
enum QuickPermission: Equatable {
    case notDetermined
    case denied
    case restricted
    case granted
}

enum WiFiPower: Equatable {
    case on
    case off
    /// No Wi-Fi interface (Mac mini on Ethernet with the card removed, VMs).
    case noInterface
}

/// Why a toggle action failed. Only the cases the UI renders differently are
/// distinguished; everything else is `.failed`.
enum QuickToggleError: Error, Equatable {
    /// CoreWLAN refused: System Settings is set to require an administrator
    /// to change Wi-Fi power.
    case notPermitted
    /// The Automation permission for System Events was declined (-1743).
    case automationDenied
    case failed
}

/// The System Settings panes a tile can send the user to.
enum QuickSettingsPane: Equatable, CaseIterable {
    case wifi
    case bluetooth
    case bluetoothPrivacy
    case automationPrivacy
    case focus
    case appearance
}

enum QuickToggleKind: Equatable, CaseIterable {
    case wifi
    case bluetooth
    case focus
    case appearance
}

// MARK: - Tile model

/// What a tile shows. A tile is never just "on/off": every permission and
/// failure state has its own inline rendering instead of a modal.
enum QuickTileState: Equatable {
    case on
    case off
    /// The state cannot be read, but the action still works (Focus without
    /// the Focus Status permission).
    case unknown
    case working
    /// The permission was never asked; tapping asks, in context.
    case askPermission
    /// The permission was declined or is restricted; tapping opens Settings.
    case denied
    /// The user has to choose something first (the Focus shortcut).
    case needsSetup
    /// The hardware is missing or the build lacks the Info.plist key.
    case unavailable
    /// The last action failed; tapping retries.
    case failed
}

/// What tapping a tile does.
enum QuickTileAction: Equatable {
    case toggle
    case requestPermission
    case openSettings(QuickSettingsPane)
    case showDevices
    case runShortcut
    case openAppSettings
    case none
}

struct QuickTile: Equatable {
    let state: QuickTileState
    let action: QuickTileAction
}

/// Pure state-to-tile mapping. Kept free of the store so each rule can be
/// tested on its own.
enum QuickTogglesPolicy {
    static func wifi(power: WiFiPower, busy: Bool, error: QuickToggleError?) -> QuickTile {
        if busy { return QuickTile(state: .working, action: .none) }
        if power == .noInterface { return QuickTile(state: .unavailable, action: .openSettings(.wifi)) }
        switch error {
        case .notPermitted?: return QuickTile(state: .denied, action: .openSettings(.wifi))
        case .failed?, .automationDenied?: return QuickTile(state: .failed, action: .toggle)
        case nil: return QuickTile(state: power == .on ? .on : .off, action: .toggle)
        }
    }

    /// Bluetooth power has no public setter (IOBluetoothPreferenceSetControllerPowerState
    /// is private), so "off" deep-links to Settings instead of toggling.
    static func bluetooth(configured: Bool, permission: QuickPermission, powered: Bool?) -> QuickTile {
        guard configured else { return QuickTile(state: .unavailable, action: .openSettings(.bluetooth)) }
        switch permission {
        case .notDetermined: return QuickTile(state: .askPermission, action: .requestPermission)
        case .denied, .restricted: return QuickTile(state: .denied, action: .openSettings(.bluetoothPrivacy))
        case .granted:
            switch powered {
            case false?: return QuickTile(state: .off, action: .openSettings(.bluetooth))
            case true?: return QuickTile(state: .on, action: .showDevices)
            case nil: return QuickTile(state: .unknown, action: .showDevices)
            }
        }
    }

    /// There is no public Focus setter; the tile runs a Shortcut the user
    /// picked (the Shortcuts "Set Focus" action can toggle Do Not Disturb).
    static func focus(shortcut: String, isFocused: Bool?, running: Bool, failed: Bool) -> QuickTile {
        if running { return QuickTile(state: .working, action: .none) }
        if shortcut.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return QuickTile(state: .needsSetup, action: .openAppSettings)
        }
        if failed { return QuickTile(state: .failed, action: .runShortcut) }
        switch isFocused {
        case true?: return QuickTile(state: .on, action: .runShortcut)
        case false?: return QuickTile(state: .off, action: .runShortcut)
        case nil: return QuickTile(state: .unknown, action: .runShortcut)
        }
    }

    static func appearance(isDark: Bool, busy: Bool, error: QuickToggleError?) -> QuickTile {
        if busy { return QuickTile(state: .working, action: .none) }
        switch error {
        case .automationDenied?: return QuickTile(state: .denied, action: .openSettings(.automationPrivacy))
        case .failed?, .notPermitted?: return QuickTile(state: .failed, action: .toggle)
        case nil: return QuickTile(state: isDark ? .on : .off, action: .toggle)
        }
    }
}

// MARK: - Bluetooth devices

/// Last battery levels a device reported, in percent. AirPods report three
/// values, most other devices one.
struct QuickBattery: Equatable {
    var single: Int?
    var left: Int?
    var right: Int?
    var caseLevel: Int?

    var isEmpty: Bool { single == nil && left == nil && right == nil && caseLevel == nil }

    /// The lowest bud level, which is what decides whether the user can
    /// keep listening. Falls back to the single value.
    var headline: Int? {
        let buds = [left, right].compactMap { $0 }
        return buds.min() ?? single
    }
}

struct QuickBluetoothDevice: Equatable, Identifiable {
    /// Normalised address (see `QuickBluetoothAddress.normalize`).
    let id: String
    let name: String
    let isConnected: Bool
    /// Headphones and speakers, the devices a one-click connect is for.
    let isAudio: Bool
    var battery: QuickBattery?
}

enum QuickDeviceActivity: Equatable {
    case connecting
    case disconnecting
    case failed
}

enum QuickBluetoothAddress {
    /// IOBluetooth formats addresses as `aa-bb-cc-dd-ee-ff`, system_profiler
    /// as `AA:BB:CC:DD:EE:FF`; both reduce to `AABBCCDDEEFF`.
    static func normalize(_ address: String) -> String {
        address.uppercased().filter { $0.isHexDigit }
    }
}

enum QuickDeviceOrdering {
    /// Connected first, then audio devices, then by name, so AirPods sit at
    /// the start of the row where one click reaches them.
    static func sorted(_ devices: [QuickBluetoothDevice]) -> [QuickBluetoothDevice] {
        devices.sorted { a, b in
            if a.isConnected != b.isConnected { return a.isConnected }
            if a.isAudio != b.isAudio { return a.isAudio }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// Reads battery levels from `system_profiler -json SPBluetoothDataType`.
/// There is no public IOBluetooth API for AirPods battery; system_profiler
/// is a shipped, documented tool and its JSON keys have been stable since
/// macOS 12. If Apple renames them this returns an empty map and the row
/// simply shows no battery.
enum QuickBatteryParser {
    static func parse(_ data: Data) -> [String: QuickBattery] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return [:] }

        var result: [String: QuickBattery] = [:]
        for controller in controllers {
            for key in ["device_connected", "device_not_connected"] {
                guard let entries = controller[key] as? [[String: Any]] else { continue }
                for entry in entries {
                    for case let props as [String: Any] in entry.values {
                        guard let address = props["device_address"] as? String else { continue }
                        let battery = QuickBattery(
                            single: percent(props["device_batteryLevelMain"] ?? props["device_batteryLevel"]),
                            left: percent(props["device_batteryLevelLeft"]),
                            right: percent(props["device_batteryLevelRight"]),
                            caseLevel: percent(props["device_batteryLevelCase"])
                        )
                        if !battery.isEmpty {
                            result[QuickBluetoothAddress.normalize(address)] = battery
                        }
                    }
                }
            }
        }
        return result
    }

    /// system_profiler localises the percent sign position ("74%" in
    /// English, "%74" in Turkish), so only the digits are trusted.
    static func percent(_ value: Any?) -> Int? {
        guard let text = value as? String else { return nil }
        let digits = text.filter(\.isNumber)
        guard let number = Int(digits), (0...100).contains(number) else { return nil }
        return number
    }
}

// MARK: - Backend

/// Everything the store needs from the system. The real implementation is
/// `SystemQuickTogglesBackend`; tests use a fake so nothing on the test
/// machine is ever switched.
///
/// Contract: none of the read methods may show a permission prompt. Only
/// `requestBluetoothPermission`, `requestFocusPermission`, `setDarkMode`
/// (Automation) and the Bluetooth device calls may, and the store calls them
/// only from a user action.
@MainActor
protocol QuickTogglesBackend: AnyObject {
    /// Called by the backend whenever a system state it observes changes.
    var onChange: (() -> Void)? { get set }

    func wifiPower() -> WiFiPower
    func setWiFiPower(_ on: Bool) throws

    /// False when the build lacks NSBluetoothAlwaysUsageDescription; touching
    /// IOBluetooth then would get the process killed by TCC.
    var bluetoothConfigured: Bool { get }
    func bluetoothPermission() -> QuickPermission
    func requestBluetoothPermission() async -> QuickPermission
    func bluetoothPowered() -> Bool?
    func bluetoothDevices() async -> [QuickBluetoothDevice]
    func connect(deviceID: String) async -> Bool
    func disconnect(deviceID: String) async -> Bool

    var focusConfigured: Bool { get }
    func focusPermission() -> QuickPermission
    func requestFocusPermission() async -> QuickPermission
    /// Nil unless the Focus Status permission is granted.
    func focusIsActive() -> Bool?
    func runShortcut(named name: String) async throws
    func shortcutNames() async -> [String]

    func isDarkMode() -> Bool
    func setDarkMode(_ dark: Bool) async throws

    func open(_ pane: QuickSettingsPane)
    func openAppSettings()
}

// MARK: - Store

/// Observable state for the toggles row. Owns no system resources itself;
/// it maps backend reads to tiles and turns taps into backend calls.
@MainActor
final class QuickTogglesStore: ObservableObject {
    @Published private(set) var wifiPower: WiFiPower = .noInterface
    @Published private(set) var wifiBusy = false
    @Published private(set) var wifiError: QuickToggleError?

    @Published private(set) var bluetoothPermission: QuickPermission = .notDetermined
    @Published private(set) var bluetoothPowered: Bool?
    @Published private(set) var devices: [QuickBluetoothDevice] = []
    @Published private(set) var deviceActivity: [String: QuickDeviceActivity] = [:]
    @Published var showingDevices = false

    @Published private(set) var focusActive: Bool?
    @Published private(set) var focusRunning = false
    @Published private(set) var focusFailed = false

    @Published private(set) var isDark = false
    @Published private(set) var appearanceBusy = false
    @Published private(set) var appearanceError: QuickToggleError?

    let backend: QuickTogglesBackend
    private let focusShortcut: () -> String

    /// - Parameters:
    ///   - backend: system access; a fake in tests.
    ///   - focusShortcut: reads the chosen Shortcut name. Injected so the
    ///     store does not depend on Defaults.
    init(backend: QuickTogglesBackend, focusShortcut: @escaping () -> String) {
        self.backend = backend
        self.focusShortcut = focusShortcut
        backend.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    var wifiTile: QuickTile { QuickTogglesPolicy.wifi(power: wifiPower, busy: wifiBusy, error: wifiError) }
    var bluetoothTile: QuickTile {
        QuickTogglesPolicy.bluetooth(
            configured: backend.bluetoothConfigured,
            permission: bluetoothPermission,
            powered: bluetoothPowered
        )
    }
    var focusTile: QuickTile {
        QuickTogglesPolicy.focus(shortcut: focusShortcut(), isFocused: focusActive, running: focusRunning, failed: focusFailed)
    }
    var appearanceTile: QuickTile {
        QuickTogglesPolicy.appearance(isDark: isDark, busy: appearanceBusy, error: appearanceError)
    }

    func tile(for kind: QuickToggleKind) -> QuickTile {
        switch kind {
        case .wifi: return wifiTile
        case .bluetooth: return bluetoothTile
        case .focus: return focusTile
        case .appearance: return appearanceTile
        }
    }

    /// Re-reads every state without prompting. Safe to call on each panel open.
    func refresh() {
        wifiPower = backend.wifiPower()
        if backend.bluetoothConfigured {
            bluetoothPermission = backend.bluetoothPermission()
            bluetoothPowered = bluetoothPermission == .granted ? backend.bluetoothPowered() : nil
        }
        focusActive = backend.focusConfigured ? backend.focusIsActive() : nil
        isDark = backend.isDarkMode()
        // A refused Automation permission can be granted in Settings while
        // the panel is closed; clear it so the next tap tries again.
        if appearanceError != .automationDenied { appearanceError = nil }
        if showingDevices && bluetoothTile.state == .off { showingDevices = false }
    }

    /// Runs the tile's action for a tap.
    func activate(_ kind: QuickToggleKind) async {
        switch tile(for: kind).action {
        case .none:
            return
        case .openSettings(let pane):
            if kind == .appearance { appearanceError = nil }
            backend.open(pane)
        case .openAppSettings:
            backend.openAppSettings()
        case .requestPermission:
            bluetoothPermission = await backend.requestBluetoothPermission()
            refresh()
            if bluetoothPermission == .granted { await showDevices() }
        case .showDevices:
            if showingDevices { showingDevices = false } else { await showDevices() }
        case .runShortcut:
            await runFocusShortcut()
        case .toggle:
            switch kind {
            case .wifi: toggleWiFi()
            case .appearance: await toggleAppearance()
            case .bluetooth, .focus: return
            }
        }
    }

    /// Connects a disconnected device and disconnects a connected one.
    func toggleDevice(_ id: String) async {
        guard deviceActivity[id] != .connecting, deviceActivity[id] != .disconnecting,
              let device = devices.first(where: { $0.id == id }) else { return }
        deviceActivity[id] = device.isConnected ? .disconnecting : .connecting
        let ok = device.isConnected
            ? await backend.disconnect(deviceID: id)
            : await backend.connect(deviceID: id)
        await reloadDevices()
        deviceActivity[id] = ok ? nil : .failed
    }

    // MARK: Private

    private func showDevices() async {
        showingDevices = true
        await reloadDevices()
    }

    private func reloadDevices() async {
        devices = QuickDeviceOrdering.sorted(await backend.bluetoothDevices())
    }

    private func toggleWiFi() {
        guard wifiPower != .noInterface else { return }
        wifiBusy = true
        wifiError = nil
        do {
            try backend.setWiFiPower(wifiPower != .on)
        } catch let error as QuickToggleError {
            wifiError = error
        } catch {
            wifiError = .failed
        }
        wifiBusy = false
        wifiPower = backend.wifiPower()
    }

    private func toggleAppearance() async {
        appearanceBusy = true
        appearanceError = nil
        do {
            try await backend.setDarkMode(!isDark)
        } catch let error as QuickToggleError {
            appearanceError = error
        } catch {
            appearanceError = .failed
        }
        appearanceBusy = false
        isDark = backend.isDarkMode()
    }

    private func runFocusShortcut() async {
        let name = focusShortcut()
        focusRunning = true
        focusFailed = false
        do {
            try await backend.runShortcut(named: name)
        } catch {
            focusFailed = true
        }
        focusRunning = false
        focusActive = backend.focusConfigured ? backend.focusIsActive() : nil
    }
}
