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
    /// The same glow along the screen's top edge beside the notch (ScreenEdgeGlow), under the
    /// notch glow's switch, style, colours and triggers. On by default.
    static let screenEdgeGlowEnabled = Key<Bool>("screenEdgeGlowEnabled", default: true)
    /// The band's width on screen in points; ScreenEdgeGlowPolicy.thicknessRange.
    static let screenEdgeGlowThickness = Key<Double>("screenEdgeGlowThickness", default: 5)
    /// Its own opacity, apart from the notch's: a whole screen's rim at the
    /// notch's strength is a lot. ScreenEdgeGlowPolicy.intensityRange.
    static let screenEdgeGlowIntensity = Key<Double>("screenEdgeGlowIntensity", default: 0.7)
    /// How far each side's band runs out from the notch, in notch widths;
    /// ScreenEdgeGlowPolicy.spreadRange.
    static let screenEdgeGlowSpread = Key<Double>("screenEdgeGlowSpread", default: 1.25)
}
