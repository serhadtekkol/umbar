//
//  QuickTogglesSystemBackend.swift
//  boringNotch
//
//  F20: the real system access behind the quick toggles. Public APIs only:
//  CoreWLAN (Wi-Fi power), IOBluetooth + CoreBluetooth (paired devices,
//  connect/disconnect, permission), Intents (Focus status, read-only),
//  /usr/bin/shortcuts (run the user's Focus shortcut), AppleScript to
//  System Events (appearance). No private frameworks, no SPI.
//

import AppKit
import CoreBluetooth
import CoreWLAN
import Defaults
import Intents
import IOBluetooth
import os

extension QuickTogglesStore {
    static let shared = QuickTogglesStore(
        backend: SystemQuickTogglesBackend(),
        focusShortcut: { Defaults[.quickTogglesFocusShortcut] }
    )
}

@MainActor
final class SystemQuickTogglesBackend: NSObject, QuickTogglesBackend {
    var onChange: (() -> Void)?

    private static let log = Logger(subsystem: "umbar", category: "QuickToggles")

    /// Bounds every outbound wait so a wedged daemon cannot leave a tile
    /// spinning forever. 15 s covers a Bluetooth page timeout (~5 s) plus
    /// the A2DP/HFP profile setup AirPods do after the baseband connects.
    private static let actionTimeout: Duration = .seconds(15)

    private let wifiClient = CWWiFiClient.shared()
    private var appearanceObserver: NSObjectProtocol?
    private var bluetoothPermissionRequester: BluetoothPermissionRequester?

    override init() {
        super.init()
        wifiClient.delegate = self
        // Power events need no permission (SSID events would need Location,
        // which is why only .powerDidChange is monitored).
        try? wifiClient.startMonitoringEvent(with: .powerDidChange)
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    // MARK: Wi-Fi

    func wifiPower() -> WiFiPower {
        guard let interface = wifiClient.interface() else { return .noInterface }
        return interface.powerOn() ? .on : .off
    }

    /// CWInterface.setPower is public and needs no entitlement for an
    /// unsandboxed app. It fails with kCWOperationNotPermittedErr when
    /// System Settings › Wi-Fi › Advanced requires an administrator to
    /// change Wi-Fi power; that maps to `.notPermitted`.
    func setWiFiPower(_ on: Bool) throws {
        guard let interface = wifiClient.interface() else { throw QuickToggleError.failed }
        do {
            try interface.setPower(on)
        } catch let error as NSError {
            Self.log.error("Wi-Fi setPower failed: \(error.domain, privacy: .public) \(error.code)")
            if error.domain == CWErrorDomain, error.code == CWErr.cwOperationNotPermittedErr.rawValue {
                throw QuickToggleError.notPermitted
            }
            throw QuickToggleError.failed
        }
    }

    // MARK: Bluetooth

    var bluetoothConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
    }

    /// CBManager.authorization is a class property and reads TCC without
    /// prompting; IOBluetooth shares the same Bluetooth permission.
    func bluetoothPermission() -> QuickPermission {
        switch CBManager.authorization {
        case .allowedAlways: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func requestBluetoothPermission() async -> QuickPermission {
        guard bluetoothConfigured else { return .denied }
        let requester = BluetoothPermissionRequester()
        bluetoothPermissionRequester = requester
        await requester.request()
        bluetoothPermissionRequester = nil
        return bluetoothPermission()
    }

    func bluetoothPowered() -> Bool? {
        guard bluetoothConfigured, bluetoothPermission() == .granted,
              let controller = IOBluetoothHostController.default() else { return nil }
        return controller.powerState == kBluetoothHCIPowerStateON
    }

    func bluetoothDevices() async -> [QuickBluetoothDevice] {
        guard bluetoothConfigured, bluetoothPermission() == .granted else { return [] }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let batteries = await Self.readBatteries()
        return paired.compactMap { device in
            guard let address = device.addressString else { return nil }
            let id = QuickBluetoothAddress.normalize(address)
            let connected = device.isConnected()
            return QuickBluetoothDevice(
                id: id,
                name: device.name ?? address,
                isConnected: connected,
                isAudio: device.deviceClassMajor == kBluetoothDeviceClassMajorAudio,
                // Levels are cached from the last connection; showing them
                // for a disconnected device would be stale data.
                battery: connected ? batteries[id] : nil
            )
        }
    }

    func connect(deviceID: String) async -> Bool {
        guard let device = pairedDevice(deviceID) else { return false }
        let waiter = ConnectionWaiter()
        let status = device.openConnection(waiter)
        guard status == kIOReturnSuccess else {
            Self.log.error("openConnection refused: \(status)")
            return false
        }
        return await waiter.wait(timeout: Self.actionTimeout)
    }

    func disconnect(deviceID: String) async -> Bool {
        guard let device = pairedDevice(deviceID) else { return false }
        return device.closeConnection() == kIOReturnSuccess
    }

    private func pairedDevice(_ id: String) -> IOBluetoothDevice? {
        guard bluetoothConfigured, bluetoothPermission() == .granted else { return nil }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.first { QuickBluetoothAddress.normalize($0.addressString ?? "") == id }
    }

    /// Runs system_profiler off the main actor. Only called after the
    /// Bluetooth permission is granted, so its Bluetooth query cannot be
    /// the first thing to trigger a prompt attributed to umbar.
    private static func readBatteries() async -> [String: QuickBattery] {
        let output = try? await QuickToggleProcess.run(
            "/usr/sbin/system_profiler", ["-json", "-detailLevel", "basic", "SPBluetoothDataType"],
            timeout: .seconds(5)
        )
        return output.map(QuickBatteryParser.parse) ?? [:]
    }

    // MARK: Focus

    var focusConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSFocusStatusUsageDescription") != nil
    }

    func focusPermission() -> QuickPermission {
        guard focusConfigured else { return .denied }
        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func requestFocusPermission() async -> QuickPermission {
        guard focusConfigured else { return .denied }
        _ = await INFocusStatusCenter.default.requestAuthorization()
        return focusPermission()
    }

    func focusIsActive() -> Bool? {
        guard focusPermission() == .granted else { return nil }
        return INFocusStatusCenter.default.focusStatus.isFocused
    }

    /// `shortcuts run` executes in the background without bringing the
    /// Shortcuts app forward, unlike the shortcuts://run-shortcut URL.
    func runShortcut(named name: String) async throws {
        _ = try await QuickToggleProcess.run("/usr/bin/shortcuts", ["run", name], timeout: Self.actionTimeout)
    }

    func shortcutNames() async -> [String] {
        guard let data = try? await QuickToggleProcess.run("/usr/bin/shortcuts", ["list"], timeout: .seconds(10)),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
    }

    // MARK: Appearance

    /// The global AppleInterfaceStyle default is "Dark" in dark mode and
    /// absent in light mode. NSApp.effectiveAppearance is not used: the
    /// notch window forces darkAqua, so the app's own appearance says
    /// nothing about the system's.
    func isDarkMode() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    /// There is no public appearance setter. System Events' "appearance
    /// preferences" is the documented scripting route; it costs one
    /// Automation prompt, shown on the first tap. Setting it also turns
    /// off "Auto" appearance, same as choosing Light or Dark in Settings.
    func setDarkMode(_ dark: Bool) async throws {
        let script = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark ? "true" : "false")"
        do {
            try await AppleScriptHelper.executeVoid(script)
        } catch let error as NSError {
            let number = error.userInfo[NSAppleScript.errorNumber] as? Int
            Self.log.error("Appearance script failed: \(number ?? 0)")
            // -1743 errAEEventNotPermitted: Automation declined.
            // -1744 errAEEventWouldRequireUserConsent: not yet decided and
            // the prompt could not be shown.
            if number == -1743 || number == -1744 { throw QuickToggleError.automationDenied }
            throw QuickToggleError.failed
        }
    }

    // MARK: Navigation

    func open(_ pane: QuickSettingsPane) {
        guard let url = URL(string: Self.settingsURL(pane)) else { return }
        NSWorkspace.shared.open(url)
    }

    func openAppSettings() {
        DispatchQueue.main.async { SettingsWindowController.shared.showWindow() }
    }

    /// System Settings (macOS 13+) extension identifiers.
    private static func settingsURL(_ pane: QuickSettingsPane) -> String {
        switch pane {
        case .wifi: return "x-apple.systempreferences:com.apple.wifi-settings-extension"
        case .bluetooth: return "x-apple.systempreferences:com.apple.BluetoothSettings"
        case .bluetoothPrivacy: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        case .automationPrivacy: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case .focus: return "x-apple.systempreferences:com.apple.Focus-Settings.extension"
        case .appearance: return "x-apple.systempreferences:com.apple.Appearance-Settings.extension"
        }
    }
}

extension SystemQuickTogglesBackend: CWEventDelegate {
    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.onChange?() }
    }
}

// MARK: - Helpers

/// Creating a CBCentralManager is the public way to show the Bluetooth
/// prompt; its first state callback arrives once the user has answered.
private final class BluetoothPermissionRequester: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var continuation: CheckedContinuation<Void, Never>?

    @MainActor
    func request() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
        }
        manager = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // .unknown/.resetting come before the user has answered.
        guard central.state != .unknown, central.state != .resetting else { return }
        continuation?.resume()
        continuation = nil
    }
}

/// Target for IOBluetoothDevice.openConnection(_:), which reports through
/// the informal `connectionComplete:status:` selector on the main run loop.
private final class ConnectionWaiter: NSObject {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        finish(status == kIOReturnSuccess)
    }

    @MainActor
    func wait(timeout: Duration) async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(false)
            }
        }
    }

    private func finish(_ ok: Bool) {
        guard result == nil else { return }
        result = ok
        continuation?.resume(returning: ok)
        continuation = nil
    }
}

/// Runs a system tool with a hard timeout and returns stdout. Arguments go
/// straight to execve, never through a shell, so a Shortcut name cannot
/// inject anything.
enum QuickToggleProcess {
    struct Failure: Error {
        let status: Int32
    }

    static func run(_ path: String, _ arguments: [String], timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            let lock = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resume(_ result: Result<Data, Error>) {
                let first = lock.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }

            do {
                try process.run()
            } catch {
                resume(.failure(error))
                return
            }

            // Drain stdout on its own queue: a pipe that fills
            // (system_profiler JSON can pass the 64 KB pipe buffer) would
            // otherwise block the child and it would never exit.
            DispatchQueue.global(qos: .userInitiated).async {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let status = process.terminationStatus
                resume(status == 0 ? .success(data) : .failure(Failure(status: status)))
            }

            let nanos = timeout.components.seconds * 1_000_000_000
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanos))) {
                if process.isRunning { process.terminate() }
                resume(.failure(Failure(status: -1)))
            }
        }
    }
}
