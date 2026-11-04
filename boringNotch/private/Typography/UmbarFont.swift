//
//  UmbarFont.swift
//  boringNotch
//
//  The SwiftUI side of the typeface choice. ContentView puts the chosen
//  typeface in the environment; a view says what its text is for with
//  `.umbarFont(.display, size: 13, weight: 600)` and gets the font the rules
//  in UmbarTypography.swift pick. No view names a bundled font itself.
//
//  The bundled fonts are registered for this process only, the first time
//  one is asked for, with CTFontManagerRegisterFontsForURL: nothing is
//  installed for other apps and Info.plist needs no ATSApplicationFontsPath.
//

import AppKit
import CoreText
import Defaults
import SwiftUI

extension EnvironmentValues {
    @Entry var umbarTypeface: UmbarTypeface = .system
}

extension View {
    /// The font (and letter spacing) for this text role under the user's
    /// typeface. `design` is the SF design used while the typeface is System.
    func umbarFont(
        _ role: UmbarTextRole,
        size: CGFloat,
        weight: Int = 400,
        design: UmbarSystemDesign = .standard
    ) -> some View {
        modifier(UmbarFontModifier(role: role, size: size, weight: weight, design: design))
    }

    /// Reads the stored typeface into the environment. Applied once at the
    /// root of each window that draws the island or the panel.
    func umbarTypefaceFromDefaults() -> some View {
        modifier(UmbarTypefaceRoot())
    }
}

private struct UmbarTypefaceRoot: ViewModifier {
    @Default(.umbarTypeface) private var typeface

    func body(content: Content) -> some View {
        content.environment(\.umbarTypeface, typeface)
    }
}

private struct UmbarFontModifier: ViewModifier {
    let role: UmbarTextRole
    let size: CGFloat
    let weight: Int
    let design: UmbarSystemDesign
    @Environment(\.umbarTypeface) private var typeface

    func body(content: Content) -> some View {
        let spec = UmbarTypography.spec(role, size: size, weight: weight, design: design, typeface: typeface)
        content
            .font(UmbarFont.font(spec))
            .tracking(spec.tracking)
    }
}

@MainActor
enum UmbarFont {
    /// The `font` for a spec. A bundled face that cannot be loaded falls
    /// back to SF at the same size, so text never disappears.
    static func font(_ spec: UmbarFontSpec) -> Font {
        let base: Font
        switch spec.face {
        case .system(let design):
            base = .system(size: spec.size, weight: weight(spec.weight), design: swiftUI(design))
        case .bundled(let bundled):
            if let nsFont = nsFont(bundled, size: spec.size, weight: spec.weight) {
                base = Font(nsFont as CTFont)
            } else {
                base = .system(size: spec.size, weight: weight(spec.weight))
            }
        }
        return spec.monospacedDigits ? base.monospacedDigit() : base
    }

    // MARK: Bundled fonts

    private static let registered: Void = {
        for font in UmbarBundledFont.allCases {
            guard let url = Bundle.main.url(forResource: font.resource, withExtension: "ttf") else {
                NSLog("umbar: bundled font %@ is missing from the app", font.resource)
                continue
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                // Already registered (a second call in the same process) is fine.
                NSLog("umbar: could not register %@: %@", font.resource,
                      String(describing: error?.takeRetainedValue()))
            }
        }
    }()

    private struct CacheKey: Hashable {
        let font: UmbarBundledFont
        let size: CGFloat
        let weight: Int
    }

    private static var cache: [CacheKey: NSFont] = [:]

    /// Doto's ROND axis, 0 (square dots) to 100 (round). Round reads as the
    /// LED dot matrix the option is named for, and stays crisper when small.
    private static let dotoRoundness: CGFloat = 100

    private static let weightTag = NSNumber(value: 0x7767_6874)     // 'wght'
    private static let roundnessTag = NSNumber(value: 0x524F_4E44)  // 'ROND'

    private static func nsFont(_ font: UmbarBundledFont, size: CGFloat, weight: Int) -> NSFont? {
        let key = CacheKey(font: font, size: size, weight: weight)
        if let cached = cache[key] { return cached }
        _ = registered
        var variation: [NSNumber: CGFloat] = [weightTag: CGFloat(weight)]
        if font == .doto { variation[roundnessTag] = dotoRoundness }
        // Glyphs the face lacks (CJK titles, symbols) come from SF, not
        // from whatever font CoreText would otherwise pick.
        let fallback = NSFont.systemFont(ofSize: size, weight: nsWeight(weight)).fontDescriptor
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: font.family,
            .variation: variation,
            .cascadeList: [fallback],
        ])
        guard let made = NSFont(descriptor: descriptor, size: size),
              made.familyName == font.family else { return nil }
        cache[key] = made
        return made
    }

    // MARK: Weight and design

    private static func weight(_ value: Int) -> Font.Weight {
        switch value {
        case ..<150: return .ultraLight
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        case ..<850: return .heavy
        default: return .black
        }
    }

    private static func nsWeight(_ value: Int) -> NSFont.Weight {
        switch weight(value) {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }

    private static func swiftUI(_ design: UmbarSystemDesign) -> Font.Design {
        switch design {
        case .standard: return .default
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        }
    }
}
