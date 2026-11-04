//
//  TypographyTests.swift
//  umbarTests
//
//  The typeface choice (UmbarTypography): which role follows it and at
//  what size and weight; the bundled fonts' Turkish coverage and licences;
//  and the sneak peek duration's bounds (SongPeekTiming).
//

import CoreText
import Foundation
import Testing

@Suite("UmbarTypography", .timeLimit(.minutes(1)))
struct UmbarTypographyTests {
    @Test func systemKeepsTheCallSitesOwnDesign() {
        // The default choice must draw what the views drew before typefaces.
        let ear = UmbarTypography.spec(.numeric, size: 11, weight: 600, design: .rounded, typeface: .system)
        #expect(ear == UmbarFontSpec(face: .system(.rounded), size: 11, weight: 600, tracking: 0, monospacedDigits: true))
        let title = UmbarTypography.spec(.display, size: 13, weight: 700, typeface: .system)
        #expect(title == UmbarFontSpec(face: .system(.standard), size: 13, weight: 700, tracking: 0, monospacedDigits: false))
    }

    @Test func bodyTextNeverFollowsTheTypeface() {
        for face in UmbarTypeface.allCases {
            let body = UmbarTypography.spec(.body, size: 12, weight: 400, typeface: face)
            #expect(body.face == .system(.standard), "\(face)")
            #expect(body.size == 12 && body.tracking == 0 && !body.monospacedDigits, "\(face)")
        }
    }

    @Test func systemFacesReplaceTheDesignOnly() {
        let rounded = UmbarTypography.spec(.display, size: 13, weight: 500, typeface: .rounded)
        #expect(rounded.face == .system(.rounded) && rounded.size == 13 && rounded.weight == 500)
        let mono = UmbarTypography.spec(.numeric, size: 11, weight: 600, design: .rounded, typeface: .monospaced)
        #expect(mono.face == .system(.monospaced) && mono.monospacedDigits)
    }

    @Test func dotMatrixDisplayIsLargerHeavierAndTracked() {
        let title = UmbarTypography.spec(.display, size: 13, weight: 400, typeface: .dotMatrix)
        #expect(title.face == .bundled(.doto))
        #expect(title.size == 15)        // 13 × 1.15 = 14.95, to the half point
        #expect(title.weight == 600)     // never lighter than semibold
        #expect(title.tracking == 0.6)   // 4 % of 15, to a tenth
        let bold = UmbarTypography.spec(.display, size: 13, weight: 800, typeface: .dotMatrix)
        #expect(bold.weight == 800)
    }

    @Test func dotMatrixNumbersKeepTheirWidthButNotBelowEleven() {
        // Ears are fixed width: the clock keeps its size.
        let ear = UmbarTypography.spec(.numeric, size: 11, weight: 600, design: .rounded, typeface: .dotMatrix)
        #expect(ear.size == 11 && ear.tracking == 0 && ear.monospacedDigits)
        // The player's 10 pt times are raised, where the dots still read.
        let times = UmbarTypography.spec(.numeric, size: 10, weight: 500, typeface: .dotMatrix)
        #expect(times.size == 11 && times.weight == 600)
    }

    @Test func pixelClampsToItsWeightAxis() {
        let light = UmbarTypography.spec(.display, size: 13, weight: 300, typeface: .pixel)
        #expect(light.face == .bundled(.pixelifySans) && light.weight == 400 && light.size == 13)
        let black = UmbarTypography.spec(.display, size: 13, weight: 900, typeface: .pixel)
        #expect(black.weight == 700)
    }

    @Test func weightsOutsideOpenTypeRangeAreClamped() {
        #expect(UmbarTypography.spec(.display, size: 13, weight: 0, typeface: .system).weight == 100)
        #expect(UmbarTypography.spec(.display, size: 13, weight: 2000, typeface: .system).weight == 900)
    }

    @Test func storedRawValuesStayStable() {
        // Defaults stores the raw value; renaming a case would reset users.
        #expect(UmbarTypeface.allCases.map(\.rawValue) == ["system", "rounded", "monospaced", "dotMatrix", "pixel"])
    }
}

@Suite("Bundled fonts", .timeLimit(.minutes(1)))
struct BundledFontTests {
    private static let fontsDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("boringNotch/private/Typography/Fonts", isDirectory: true)

    @Test(arguments: UmbarBundledFont.allCases)
    func fileHasTheFamilyAndEveryTurkishLetter(_ font: UmbarBundledFont) throws {
        let url = Self.fontsDir.appendingPathComponent("\(font.resource).ttf")
        let descriptors = try #require(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
        let ct = CTFontCreateWithFontDescriptor(try #require(descriptors.first), 12, nil)
        #expect(CTFontCopyFamilyName(ct) as String == font.family)
        var missing = ""
        for letter in "ğĞşŞıİçÇöÖüÜ0123456789:%" {
            var units = Array(String(letter).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            if !CTFontGetGlyphsForCharacters(ct, &units, &glyphs, units.count) { missing.append(letter) }
        }
        #expect(missing.isEmpty, "\(font.family) lacks \(missing)")
    }

    @Test(arguments: UmbarBundledFont.allCases)
    func shipsWithItsOpenFontLicense(_ font: UmbarBundledFont) throws {
        let url = Self.fontsDir.appendingPathComponent("\(font.resource)-OFL.txt")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("SIL OPEN FONT LICENSE Version 1.1"))
    }
}

@Suite("SongPeekTiming", .timeLimit(.minutes(1)))
struct SongPeekTimingTests {
    @Test func defaultIsInsideTheRangeAndOnAStep() {
        #expect(SongPeekTiming.range.contains(SongPeekTiming.defaultSeconds))
        #expect(SongPeekTiming.seconds(SongPeekTiming.defaultSeconds) == SongPeekTiming.defaultSeconds)
    }

    @Test func clampsToOneThroughTen() {
        #expect(SongPeekTiming.seconds(0) == 1)
        #expect(SongPeekTiming.seconds(-4) == 1)
        #expect(SongPeekTiming.seconds(10) == 10)
        #expect(SongPeekTiming.seconds(42) == 10)
    }

    @Test func snapsToHalfSeconds() {
        #expect(SongPeekTiming.seconds(1.5) == 1.5)
        #expect(SongPeekTiming.seconds(2.2) == 2)
        #expect(SongPeekTiming.seconds(2.3) == 2.5)
        #expect(SongPeekTiming.seconds(7.74) == 7.5)
    }

    @Test func unreadableValuesFallBackToTheDefault() {
        #expect(SongPeekTiming.seconds(.nan) == SongPeekTiming.defaultSeconds)
        #expect(SongPeekTiming.seconds(.infinity) == SongPeekTiming.defaultSeconds)
    }
}
