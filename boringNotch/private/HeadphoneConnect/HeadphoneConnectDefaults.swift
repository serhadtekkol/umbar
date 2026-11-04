//
//  HeadphoneConnectDefaults.swift
//  boringNotch
//
//  Defaults keys for the headphone connect glance.
//

import Defaults

extension Defaults.Keys {
    /// The closed island widens for a moment with the device glyph and its
    /// battery when Bluetooth headphones connect, and shows a short notice
    /// when they disconnect. Default on: it reads Core Audio's device list,
    /// which needs no permission.
    static let headphoneGlanceEnabled = Key<Bool>("headphoneGlanceEnabled", default: true)
    /// Seconds the connect glance stays; Settings offers 2–6, and
    /// HeadphoneGlancePolicy.clampedDuration guards a hand-edited value.
    static let headphoneGlanceDuration = Key<Double>("headphoneGlanceDuration", default: HeadphoneGlancePolicy.defaultDuration)
}
