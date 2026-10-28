//
//  BTBatteryDefaults.swift
//  boringNotch
//
//  Defaults key for F24 Bluetooth batteries.
//

import Defaults

extension Defaults.Keys {
    /// Battery levels of connected Bluetooth devices on Araçlar, and the
    /// 3 s "connected" glance on the closed island. Default on: it reads
    /// only public registry data and never prompts (IOBluetooth is used
    /// only after the Bluetooth permission was granted from the toggles).
    static let btBatteryEnabled = Key<Bool>("btBatteryEnabled", default: true)
}
