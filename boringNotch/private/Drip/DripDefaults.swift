//
//  DripDefaults.swift
//  boringNotch
//
//  Defaults key for the liquid drip under the closed island, kept out of
//  Constants.swift like the other feature keys.
//

import Defaults

extension Defaults.Keys {
    /// On by default (the user asked for it). Settings > Appearance.
    static let dripEffectEnabled = Key<Bool>("dripEffectEnabled", default: true)
}
