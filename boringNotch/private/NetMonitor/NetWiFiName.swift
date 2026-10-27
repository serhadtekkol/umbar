//
//  NetWiFiName.swift
//  boringNotch
//
//  F17: the optional Wi-Fi name label. Since macOS 14, CoreWLAN returns a
//  nil SSID unless the app holds Location authorisation, so the name is
//  strictly opt-in: CoreLocation is not touched at all until the user turns
//  on "Show the Wi-Fi name" in Settings > Network, and the system prompt is
//  only ever raised by that switch. umbar never asks for, reads or stores a
//  location; the authorisation is used for the SSID alone.
//

import AppKit
import CoreLocation
import CoreWLAN
import Defaults

@MainActor
final class NetLocationAccess: NSObject, ObservableObject {
    static let shared = NetLocationAccess()

    enum State: Equatable {
        /// This build has no Location usage description, so macOS would
        /// refuse the request without showing anything.
        case unavailable
        case notDetermined
        case granted
        case denied
    }

    @Published private(set) var state: State = .notDetermined

    /// Called when the state changes, so the monitor can relabel the
    /// current network without polling.
    var onChange: (() -> Void)?

    /// Created on first use only: a manager that exists is harmless, but
    /// not creating one keeps CoreLocation entirely out of the picture for
    /// users who never opt in.
    private var manager: CLLocationManager?

    private static var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSLocationUsageDescription") != nil
            || Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") != nil
    }

    /// Reads the current authorisation without prompting.
    func refresh() {
        guard Self.hasUsageDescription else {
            update(.unavailable)
            return
        }
        update(Self.map(ensureManager().authorizationStatus))
    }

    /// Raises the system prompt if the user has not answered yet. Does
    /// nothing once they have; a denial is changed in System Settings.
    func request() {
        refresh()
        guard state == .notDetermined else { return }
        ensureManager().requestWhenInUseAuthorization()
    }

    /// Opens System Settings > Privacy & Security > Location Services.
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }

    private func ensureManager() -> CLLocationManager {
        if let manager { return manager }
        let created = CLLocationManager()
        created.delegate = self
        manager = created
        return created
    }

    private func update(_ newState: State) {
        guard newState != state else { return }
        state = newState
        onChange?()
    }

    private static func map(_ status: CLAuthorizationStatus) -> State {
        switch status {
        case .authorizedAlways: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
}

extension NetLocationAccess: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.update(Self.map(status)) }
    }
}

enum NetWiFiName {
    /// The SSID of `interfaceName`, when the user opted in and macOS allows
    /// it; nil otherwise. Never logged.
    @MainActor
    static func current(interfaceName: String) -> String? {
        guard Defaults[.netMonitorShowWiFiName], NetLocationAccess.shared.state == .granted else { return nil }
        let ssid = CWWiFiClient.shared().interface(withName: interfaceName)?.ssid()
        return ssid.flatMap { $0.isEmpty ? nil : $0 }
    }
}
