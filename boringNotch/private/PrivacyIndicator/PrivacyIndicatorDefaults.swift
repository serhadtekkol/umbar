//
//  PrivacyIndicatorDefaults.swift
//  boringNotch
//
//  Defaults key for F23, kept out of Constants.swift like the other
//  feature keys.
//

import Defaults

extension Defaults.Keys {
    /// Shows a camera/microphone dot beside the closed notch and names the
    /// apps on the Şimdi page. Off removes every hardware listener.
    static let privacyIndicatorEnabled = Key<Bool>("privacyIndicatorEnabled", default: true)
}
