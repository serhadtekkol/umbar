//
//  EdgeGlowDefaults.swift
//  boringNotch
//
//  Defaults keys for the edge glow, kept out of Constants.swift like the
//  other feature keys.
//

import Defaults

extension EdgeGlowStyle: Defaults.Serializable {}

extension Defaults.Keys {
    /// On by default: the glow is quiet (music and short event flashes only).
    static let edgeGlowEnabled = Key<Bool>("edgeGlowEnabled", default: true)
    static let edgeGlowStyle = Key<EdgeGlowStyle>("edgeGlowStyle", default: .soft)
    /// Multiplies the glow's opacity; 0.3…1.
    static let edgeGlowIntensity = Key<Double>("edgeGlowIntensity", default: 0.7)
}
