//
//  NetMonitorDefaults.swift
//  boringNotch
//
//  Defaults keys for F17 network traffic. Kept out of Constants.swift like
//  CaffeinateDefaults.swift.
//

import Defaults

extension Defaults.Keys {
    /// Measures traffic and shows the network column on the Şimdi page.
    /// Off stops all sampling; the stored totals stay until reset.
    static let netMonitorEnabled = Key<Bool>("netMonitorEnabled", default: true)

    /// Shows the current download speed in the closed notch's left ear.
    /// Off by default: the ear is for "what is happening", and a speed that
    /// is always there stops meaning anything.
    static let netMonitorShowInClosedNotch = Key<Bool>("netMonitorShowInClosedNotch", default: false)

    /// Labels the network with its Wi-Fi name. Needs Location (macOS hides
    /// the SSID otherwise), so it is off until the user turns it on.
    static let netMonitorShowWiFiName = Key<Bool>("netMonitorShowWiFiName", default: false)
}
