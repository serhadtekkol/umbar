import CoreGraphics
@testable import QARunnerCore
import XCTest

/// MacBook Air M2 13": 1470 pt wide built-in display, notch ~185 pt.
let airDisplay = DisplayGeometry(bounds: CGRect(x: 0, y: 0, width: 1470, height: 956), notchWidth: 185)

final class RegionsTests: XCTestCase {
    func testNotchRegionMatchesTheDesign() throws {
        let r = try Regions.rect(.notch, on: airDisplay).get()
        XCTAssertEqual(r.width, 185 + 400)
        XCTAssertEqual(r.height, 360)
        XCTAssertEqual(r.midX, 735)
        XCTAssertEqual(r.minY, 0)
    }

    func testShelfAndHudStayInsideTheNotchRegion() throws {
        let notch = try Regions.rect(.notch, on: airDisplay).get()
        XCTAssertTrue(notch.contains(try Regions.rect(.shelf, on: airDisplay).get()))
        XCTAssertTrue(notch.contains(try Regions.rect(.hud, on: airDisplay).get()))
    }

    func testRegionsOnASecondaryDisplayUseItsOrigin() throws {
        let external = DisplayGeometry(bounds: CGRect(x: 1470, y: -200, width: 1000, height: 300), notchWidth: 100)
        let r = try Regions.rect(.notch, on: external).get()
        XCTAssertEqual(r.minY, -200)
        XCTAssertEqual(r.height, 300, "clamped to the display height")
        XCTAssertTrue(external.bounds.contains(r))
    }

    func testNoNotchNoRegion() {
        let plain = DisplayGeometry(bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), notchWidth: nil)
        XCTAssertEqual(Regions.rect(.notch, on: plain).failure?.code, .noNotchDisplay)
        XCTAssertEqual(Regions.notchHoverPoint(on: plain).failure?.code, .noNotchDisplay)
    }

    func testHoverPointIsInsideTheNotch() throws {
        let p = try Regions.notchHoverPoint(on: airDisplay).get()
        XCTAssertEqual(p.x, 735)
        XCTAssertLessThan(p.y, 32, "inside the camera housing band")
    }

    func testFinderDropIsAWindowCaptureNeverARect() throws {
        XCTAssertEqual(try CapturePlanner.plan(region: .finderDrop, display: airDisplay, finderDropWindowID: 42).get(), .window(id: 42))
        XCTAssertEqual(CapturePlanner.plan(region: .finderDrop, display: airDisplay, finderDropWindowID: nil).failure?.code,
                       .noFinderDropWindow)
        XCTAssertEqual(Regions.rect(.finderDrop, on: airDisplay).failure?.code, .regionRejected)
    }
}

final class AudioPolicyTests: XCTestCase {
    func testNonVolumeKeysHaveNoAudioPreconditions() {
        for k in [MediaKeyName.brightnessUp, .brightnessDown, .kbdLightUp, .kbdLightDown] {
            XCTAssertNil(AudioPolicy.check(k, beepFeedback: 1, silentAsserted: false, currentVolume: nil))
        }
    }

    func testVolumeNeedsEveryPrecondition() {
        XCTAssertNil(AudioPolicy.check(.volumeDown, beepFeedback: nil, silentAsserted: true, currentVolume: 0.5))
        XCTAssertNil(AudioPolicy.check(.volumeUp, beepFeedback: 0, silentAsserted: true, currentVolume: 0.2))
        XCTAssertEqual(AudioPolicy.check(.volumeDown, beepFeedback: 1, silentAsserted: true, currentVolume: 0.2)?.code, .beepFeedbackOn)
        XCTAssertEqual(AudioPolicy.check(.volumeUp, beepFeedback: 0, silentAsserted: false, currentVolume: 0.2)?.code, .silentNotAsserted)
        XCTAssertEqual(AudioPolicy.check(.volumeUp, beepFeedback: 0, silentAsserted: true, currentVolume: nil)?.code, .volumeUnreadable)
        XCTAssertEqual(AudioPolicy.check(.volumeUp, beepFeedback: 0, silentAsserted: true, currentVolume: .nan)?.code, .volumeUnreadable)
    }

    func testVolumeUpCeilingIsPointThirty() {
        // 0.25 + 1/16 = 0.3125 > 0.30: refused. 0.2375 + 1/16 = 0.30: allowed.
        XCTAssertEqual(AudioPolicy.check(.volumeUp, beepFeedback: 0, silentAsserted: true, currentVolume: 0.25)?.code, .volumeCeiling)
        XCTAssertNil(AudioPolicy.check(.volumeUp, beepFeedback: 0, silentAsserted: true, currentVolume: 0.2375))
        XCTAssertNil(AudioPolicy.check(.volumeDown, beepFeedback: 0, silentAsserted: true, currentVolume: 0.9), "down is always fine")
    }

    func testSilentAssertionMustBeFromThisSession() {
        let armed = t0
        XCTAssertTrue(AudioPolicy.isSilentAssertionValid(contents: "asserted-by habibe\n", modifiedAt: armed.addingTimeInterval(5), armedSince: armed))
        XCTAssertFalse(AudioPolicy.isSilentAssertionValid(contents: "asserted-by habibe", modifiedAt: armed.addingTimeInterval(-1), armedSince: armed))
        XCTAssertFalse(AudioPolicy.isSilentAssertionValid(contents: "yes", modifiedAt: armed, armedSince: armed))
        XCTAssertFalse(AudioPolicy.isSilentAssertionValid(contents: "asserted-by habibe", modifiedAt: armed, armedSince: nil))
        XCTAssertFalse(AudioPolicy.isSilentAssertionValid(contents: nil, modifiedAt: armed, armedSince: armed))
    }
}

final class LoggingTests: XCTestCase {
    func testJSONLineShape() throws {
        let rec = LogRecord(time: t0, event: .refused, command: "key", parameters: ["name": "esc"],
                            callerPID: 42, callerPath: "/Users/umbarqa/umbar-qa/bin/qa-cli",
                            refusal: Refusal(.focusNotInUmbar), armed: true)
        let line = rec.jsonLine()
        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.filter { $0 == 0x0A }.count, 1, "exactly one line")
        let obj = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        XCTAssertEqual(obj["event"] as? String, "refused")
        XCTAssertEqual(obj["refused"] as? String, "focus-not-in-umbar")
        XCTAssertEqual(obj["caller_pid"] as? Int, 42)
        XCTAssertEqual(obj["cmd"] as? String, "key")
        XCTAssertEqual((obj["params"] as? [String: String])?["name"], "esc")
        XCTAssertEqual(obj["armed"] as? Bool, true)
    }

    func testAcceptedEventIsNamedCommandOnTheWire() {
        XCTAssertEqual(LogRecord.Event.accepted.rawValue, "command")
    }

    func testSummaryIsSingleLine() {
        let rec = LogRecord(time: t0, event: .arm, armed: true, facts: ["minutes": "60"])
        XCTAssertFalse(rec.summary.contains("\n"))
        XCTAssertTrue(rec.summary.contains("minutes=60"))
    }
}
