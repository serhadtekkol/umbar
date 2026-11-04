//
//  PrivacyCopyTests.swift
//  umbarTests
//
//  Privacy promises in Settings are claims about behaviour; these keep the
//  ones that drifted once (Muhittin M3: "umbar never turns either on"
//  after the mirror came back) from drifting again. Reads the string
//  catalog from the repository, like BundledFontTests reads the fonts.
//

import Foundation
import Testing

@Suite("Privacy copy", .timeLimit(.minutes(1)))
struct PrivacyCopyTests {
    private static let catalog = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("boringNotch/Localizable.xcstrings")

    private static func value(_ key: String, _ language: String) throws -> String {
        let data = try Data(contentsOf: catalog)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        let entry = try #require(strings[key] as? [String: Any])
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let unit = try #require((localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any])
        return try #require(unit["value"] as? String)
    }

    @Test func indicatorDetailNoLongerSaysTheCameraIsNeverOn() throws {
        let en = try Self.value("privacy.settings.enabled.detail", "en")
        let tr = try Self.value("privacy.settings.enabled.detail", "tr")
        #expect(!en.contains("never turns either on"))
        #expect(!tr.contains("ikisini de hiçbir zaman açmaz"))
    }

    @Test func indicatorDetailSaysTheMirrorHidesTheCameraDot() throws {
        let en = try Self.value("privacy.settings.enabled.detail", "en")
        let tr = try Self.value("privacy.settings.enabled.detail", "tr")
        #expect(en.contains("While the mirror is on, the camera dot is hidden."))
        #expect(tr.contains("Ayna açıkken kamera noktası gösterilmez."))
    }
}
