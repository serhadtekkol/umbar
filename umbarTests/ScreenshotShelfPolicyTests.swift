import XCTest

final class ScreenshotShelfPolicyTests: XCTestCase {
    private func verdict(_ name: String, attr: Bool? = nil, rec: Bool = false) -> ScreenshotShelfPolicy.Verdict {
        ScreenshotShelfPolicy.classify(name: name, hasCaptureAttribute: attr, includeRecordings: rec)
    }

    func testLocalizedPrefixesAreAcceptedByName() {
        XCTAssertEqual(verdict("Screenshot 2026-10-27 at 10.00.00.png"), .accept)
        XCTAssertEqual(verdict("Screen Shot 2019-01-01 at 1.00.00 PM.png"), .accept)
        XCTAssertEqual(verdict("Ekran Resmi 2026-10-27 10.00.00.png"), .accept)
        XCTAssertEqual(verdict("Ekran Görüntüsü 2026-10-27 10.00.00.png"), .accept)
    }

    func testDecomposedUmlautStillMatches() {
        let decomposed = "Ekran Go\u{0308}ru\u{0308}ntu\u{0308}su\u{0308} 1.png"
        XCTAssertNotEqual(Array(decomposed.unicodeScalars), Array("Ekran Görüntüsü 1.png".precomposedStringWithCanonicalMapping.unicodeScalars))
        XCTAssertEqual(verdict(decomposed), .accept)
    }

    func testCaptureAttributeBeatsName() {
        XCTAssertEqual(verdict("Bildschirmfoto 2026.png", attr: true), .accept)
        XCTAssertEqual(verdict("holiday.png"), .ignore)
    }

    func testTemporaryNamesAreIgnoredEvenWithAttribute() {
        XCTAssertEqual(verdict(".Screenshot 2026.png", attr: true), .ignore)
    }

    func testRecordingsNeedTheToggle() {
        XCTAssertEqual(verdict("Screen Recording 2026.mov", rec: false), .ignore)
        XCTAssertEqual(verdict("Screen Recording 2026.mov", rec: true), .accept)
        XCTAssertEqual(verdict("Ekran Kaydı 2026.mov", rec: true), .accept)
        XCTAssertEqual(verdict("clip.mov", attr: true, rec: true), .accept)
    }

    func testWrongExtensionIgnored() {
        XCTAssertEqual(verdict("Screenshot notes.txt"), .ignore)
        XCTAssertEqual(verdict("Screenshot.zip", attr: true), .ignore)
    }

    func testLocationResolution() {
        let home = URL(fileURLWithPath: "/Users/x")
        XCTAssertEqual(ScreenshotShelfPolicy.resolveLocation(configured: nil, home: home).path, "/Users/x/Desktop")
        XCTAssertEqual(ScreenshotShelfPolicy.resolveLocation(configured: "  ", home: home).path, "/Users/x/Desktop")
        XCTAssertEqual(ScreenshotShelfPolicy.resolveLocation(configured: "~/Pictures/Shots", home: home).path, "/Users/x/Pictures/Shots")
        XCTAssertEqual(ScreenshotShelfPolicy.resolveLocation(configured: "/Volumes/D/s/", home: home).path, "/Volumes/D/s")
        XCTAssertEqual(ScreenshotShelfPolicy.resolveLocation(configured: "relative/dir", home: home).path, "/Users/x/Desktop")
    }

    func testStabilityNeedsTwoEqualNonEmptyObservations() {
        var t = ScreenshotStabilityTracker(maxAttempts: 3)
        let d = Date(timeIntervalSince1970: 0)
        typealias S = ScreenshotStabilityTracker.Snapshot
        XCTAssertEqual(t.observe("a", snapshot: S(size: 0, modified: d)), .pending)
        XCTAssertEqual(t.observe("a", snapshot: S(size: 0, modified: d)), .pending, "empty file is not complete")
        XCTAssertEqual(t.observe("a", snapshot: S(size: 10, modified: d)), .giveUp, "attempt cap reached while still growing")
        XCTAssertEqual(t.observe("b", snapshot: S(size: 5, modified: d)), .pending)
        XCTAssertEqual(t.observe("b", snapshot: S(size: 5, modified: d)), .stable)
        XCTAssertEqual(t.observe("c", snapshot: nil), .giveUp)
    }
}
