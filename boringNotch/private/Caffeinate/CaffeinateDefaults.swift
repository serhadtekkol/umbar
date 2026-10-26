//
//  CaffeinateDefaults.swift
//  boringNotch
//
//  Defaults key for F11 caffeinate. Kept out of Constants.swift like
//  EyeBreakDefaults.swift.
//

import Defaults

extension Defaults.Keys {
    /// Shows the caffeinate control in the notch header (AC-1.13). On by
    /// default: the control was always there before the switch existed.
    /// Turning it off also ends a running session.
    static let caffeinateEnabled = Key<Bool>("caffeinateEnabled", default: true)
}
