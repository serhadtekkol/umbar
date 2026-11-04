//
//  EdgeGlowDefaults.swift
//  boringNotch
//
//  Defaults keys for the edge glow, kept out of Constants.swift like the
//  other feature keys.
//

import Defaults

extension EdgeGlowStyle: Defaults.Serializable {}
extension EdgeGlowColorMode: Defaults.Serializable {}

extension Defaults.Keys {
    /// On by default: the glow is quiet (music and short event flashes only).
    static let edgeGlowEnabled = Key<Bool>("edgeGlowEnabled", default: true)
    static let edgeGlowStyle = Key<EdgeGlowStyle>("edgeGlowStyle", default: .soft)
    /// Multiplies the glow's opacity; 0.3…1.
    static let edgeGlowIntensity = Key<Double>("edgeGlowIntensity", default: 0.7)
    /// Off by default: it needs the system's audio capture permission.
    static let edgeGlowAudioReactive = Key<Bool>("edgeGlowAudioReactive", default: false)
    static let edgeGlowColorMode = Key<EdgeGlowColorMode>("edgeGlowColorMode", default: .album)
    /// "#RRGGBB" for `.fixed`. systemPurple, dark appearance.
    static let edgeGlowFixedColor = Key<String>("edgeGlowFixedColor", default: "#BF5AF2")
    /// Event colours, "#RRGGBB"; nil is the default (EdgeGlowTokens), so a
    /// user who never changed one follows the token if it is retuned.
    static let edgeGlowTimerColor = Key<String?>("edgeGlowTimerColor", default: nil)
    static let edgeGlowEyeBreakColor = Key<String?>("edgeGlowEyeBreakColor", default: nil)
    static let edgeGlowCameraColor = Key<String?>("edgeGlowCameraColor", default: nil)
    static let edgeGlowMicrophoneColor = Key<String?>("edgeGlowMicrophoneColor", default: nil)
    static let edgeGlowHUDColor = Key<String?>("edgeGlowHUDColor", default: nil)
}
