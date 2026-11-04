//
//  UmbarTypography.swift
//  boringNotch
//
//  Pure (Foundation-only) rules for the user's typeface choice: which text
//  role takes the chosen face, and at what size, weight and tracking. The
//  SwiftUI side (UmbarFont.swift) only turns a spec into a Font, so the
//  rules can be tested without a font being installed.
//
//  Only short "display" text follows the choice: the song name, clocks,
//  percentages, titles. Body text (notes, calendar details, Settings) stays
//  in the system font whatever is chosen, for reading.
//

import CoreGraphics
import Foundation

/// Settings › Appearance › Typeface.
enum UmbarTypeface: String, CaseIterable, Identifiable {
    /// SF, the call site's own design (some already ask for rounded).
    case system
    case rounded
    case monospaced
    /// Doto, bundled (SIL OFL 1.1).
    case dotMatrix
    /// Pixelify Sans, bundled (SIL OFL 1.1).
    case pixel

    var id: String { rawValue }
}

/// What a piece of text is for; decides whether it follows the typeface.
enum UmbarTextRole {
    /// Song name, artist, page and card titles.
    case display
    /// Clocks and percentages: the face's digits, monospaced.
    case numeric
    /// Anything read rather than glanced at. Always the system font.
    case body
}

/// The SF design a call site uses when the typeface is `.system`, so the
/// default choice draws exactly what the view drew before typefaces existed.
enum UmbarSystemDesign: Equatable {
    case standard
    case rounded
    case monospaced
}

/// Fonts shipped in the app bundle (Typography/Fonts), each with its OFL.
enum UmbarBundledFont: String, CaseIterable {
    case doto
    case pixelifySans

    /// The family name inside the file, which is what CoreText looks up.
    var family: String {
        switch self {
        case .doto: return "Doto"
        case .pixelifySans: return "Pixelify Sans"
        }
    }

    /// Resource name (without extension) in the app bundle.
    var resource: String {
        switch self {
        case .doto: return "Doto"
        case .pixelifySans: return "PixelifySans"
        }
    }

    /// The file's `wght` axis. A requested weight outside it is clamped.
    var weightAxis: ClosedRange<Int> {
        switch self {
        case .doto: return 100...900
        case .pixelifySans: return 400...700
        }
    }
}

struct UmbarFontSpec: Equatable {
    enum Face: Equatable {
        case system(UmbarSystemDesign)
        case bundled(UmbarBundledFont)
    }

    let face: Face
    let size: CGFloat
    /// OpenType weight, 100 (thin) to 900 (black).
    let weight: Int
    /// Extra space between letters, in points.
    let tracking: CGFloat
    let monospacedDigits: Bool
}

enum UmbarTypography {
    /// Doto's dots are drawn on a 5×7 grid; at the island's 11–13 pt a
    /// light weight leaves dots too small to read, so it never goes below
    /// semibold, where the dots nearly touch.
    static let dotMatrixMinimumWeight = 600

    /// Display text in Doto runs this much larger than in SF. Cap heights
    /// match at the same size, but a dot glyph has less ink than a stroke.
    /// Numeric text is not scaled: it sits in fixed-width ears.
    static let dotMatrixDisplayScale: CGFloat = 1.15

    /// Letter spacing for Doto display text, as a share of the size, so
    /// neighbouring letters' dot columns do not read as one glyph.
    static let dotMatrixTracking: CGFloat = 0.04

    /// Below 11 pt Doto's dots fall under a Retina pixel and the digits
    /// smear; numeric text (the player's 10 pt times) is raised to this.
    static let dotMatrixMinimumSize: CGFloat = 11

    static func spec(
        _ role: UmbarTextRole,
        size: CGFloat,
        weight: Int,
        design: UmbarSystemDesign = .standard,
        typeface: UmbarTypeface
    ) -> UmbarFontSpec {
        let weight = min(max(weight, 100), 900)
        let digits = role == .numeric
        func system(_ design: UmbarSystemDesign) -> UmbarFontSpec {
            UmbarFontSpec(face: .system(design), size: size, weight: weight, tracking: 0, monospacedDigits: digits)
        }
        if role == .body { return system(design) }

        switch typeface {
        case .system:
            return system(design)
        case .rounded:
            return system(.rounded)
        case .monospaced:
            return system(.monospaced)
        case .dotMatrix:
            let font = UmbarBundledFont.doto
            let display = role == .display
            let scaled = display
                ? (size * dotMatrixDisplayScale * 2).rounded() / 2
                : max(size, dotMatrixMinimumSize)
            return UmbarFontSpec(
                face: .bundled(font),
                size: scaled,
                weight: clamp(max(weight, dotMatrixMinimumWeight), to: font.weightAxis),
                tracking: display ? (scaled * dotMatrixTracking * 10).rounded() / 10 : 0,
                monospacedDigits: digits)
        case .pixel:
            let font = UmbarBundledFont.pixelifySans
            return UmbarFontSpec(
                face: .bundled(font), size: size,
                weight: clamp(weight, to: font.weightAxis),
                tracking: 0, monospacedDigits: digits)
        }
    }

    private static func clamp(_ weight: Int, to axis: ClosedRange<Int>) -> Int {
        min(max(weight, axis.lowerBound), axis.upperBound)
    }
}
