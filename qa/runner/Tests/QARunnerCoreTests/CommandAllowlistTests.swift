@testable import QARunnerCore
import XCTest

/// The §3.5 allowlist: every command parses with its documented parameters
/// and bounds, and nothing else does.
final class CommandAllowlistTests: XCTestCase {
    func testStatusAndVersionAndDisarm() {
        assertAccepted(#"{"cmd":"status"}"#, .status(windows: false))
        assertAccepted(#"{"cmd":"status","windows":true}"#, .status(windows: true))
        assertAccepted(#"{"cmd":"version"}"#, .version)
        assertAccepted(#"{"cmd":"disarm"}"#, .disarm)
        assertRefused(#"{"cmd":"status","windows":"yes"}"#, .wrongType)
    }

    func testCaptureCommands() {
        assertAccepted(#"{"cmd":"capture.app"}"#, .captureApp)
        assertAccepted(#"{"cmd":"capture.app","format":"png"}"#, .captureApp)
        assertRefused(#"{"cmd":"capture.app","format":"jpeg"}"#, .invalidName)
        for r in RegionName.allCases {
            assertAccepted(#"{"cmd":"capture.region","name":"\#(r.rawValue)"}"#, .captureRegion(r))
        }
        for a in AlertName.allCases {
            assertAccepted(#"{"cmd":"capture.alert","name":"\#(a.rawValue)"}"#, .captureAlert(a))
        }
        assertRefused(#"{"cmd":"capture.region"}"#, .missingField)
        assertRefused(#"{"cmd":"capture.alert","name":"keychain"}"#, .invalidName)
    }

    func testRecordBounds() {
        assertAccepted(#"{"cmd":"record.start","target":"app"}"#, .recordStart(.app, maxSeconds: 30))
        assertAccepted(#"{"cmd":"record.start","target":"notch","max_s":1}"#, .recordStart(.notch, maxSeconds: 1))
        assertAccepted(#"{"cmd":"record.start","target":"notch","max_s":30}"#, .recordStart(.notch, maxSeconds: 30))
        assertRefused(#"{"cmd":"record.start","target":"notch","max_s":31}"#, .outOfRange)
        assertRefused(#"{"cmd":"record.start","target":"notch","max_s":0}"#, .outOfRange)
        assertRefused(#"{"cmd":"record.start","target":"screen"}"#, .invalidName)
        assertRefused(#"{"cmd":"record.start","target":"app","audio":true}"#, .unknownField)
        assertAccepted(#"{"cmd":"record.stop"}"#, .recordStop)
    }

    func testAXTreeBounds() {
        assertAccepted(#"{"cmd":"ax.tree","target":"umbar"}"#, .axTree(.umbar, depth: 12))
        assertAccepted(#"{"cmd":"ax.tree","target":"finder-drop","depth":1}"#, .axTree(.finderDrop, depth: 1))
        assertRefused(#"{"cmd":"ax.tree","target":"umbar","depth":13}"#, .outOfRange)
        assertRefused(#"{"cmd":"ax.tree","target":"umbar","depth":0}"#, .outOfRange)
    }

    func testPointerCommands() {
        assertAccepted(#"{"cmd":"pointer.hover","target":"notch"}"#, .pointerHover(.notch, dwellMs: 500))
        assertAccepted(#"{"cmd":"pointer.hover","target":"umbar:shelf.item-0","dwell_ms":5000}"#,
                       .pointerHover(.umbar(identifier: "shelf.item-0"), dwellMs: 5000))
        assertRefused(#"{"cmd":"pointer.hover","target":"notch","dwell_ms":5001}"#, .outOfRange)
        assertRefused(#"{"cmd":"pointer.hover","target":"notch","dwell_ms":-1}"#, .outOfRange)
        assertAccepted(#"{"cmd":"pointer.click","target":"umbar:closeButton"}"#, .pointerClick(umbarIdentifier: "closeButton"))
        assertRefused(#"{"cmd":"pointer.click","target":"umbar:"}"#, .invalidName)
        assertRefused(#"{"cmd":"pointer.click","target":"umbar:.hidden"}"#, .invalidName)
    }

    func testDragBothDirections() {
        assertAccepted(#"{"cmd":"drag","from":"umbar-shelf:0","to":"finder-drop:case-1"}"#,
                       .dragShelfToFinder(shelfIndex: 0, folder: "case-1"))
        assertAccepted(#"{"cmd":"drag","from":"umbar-shelf:99","to":"finder-drop:a"}"#,
                       .dragShelfToFinder(shelfIndex: 99, folder: "a"))
        assertAccepted(#"{"cmd":"drag","from":"finder-drop:photo_1.png","to":"umbar-shelf"}"#,
                       .dragFinderToShelf(file: "photo_1.png"))
        assertRefused(#"{"cmd":"drag","from":"umbar-shelf:100","to":"finder-drop:a"}"#, .outOfRange)
        assertRefused(#"{"cmd":"drag","from":"umbar-shelf:01","to":"finder-drop:a"}"#, .outOfRange)
        assertRefused(#"{"cmd":"drag","from":"umbar-shelf:-1","to":"finder-drop:a"}"#, .outOfRange)
    }

    func testFinderOpenDropFolderGrammar() {
        assertAccepted(#"{"cmd":"finder.open-drop","folder":"case-01"}"#, .finderOpenDrop(folder: "case-01"))
        assertAccepted(#"{"cmd":"finder.open-drop","folder":"\#(String(repeating: "a", count: 32))"}"#,
                       .finderOpenDrop(folder: String(repeating: "a", count: 32)))
        assertRefused(#"{"cmd":"finder.open-drop","folder":"\#(String(repeating: "a", count: 33))"}"#, .invalidName)
        assertRefused(#"{"cmd":"finder.open-drop","folder":"Case"}"#, .invalidName)
        assertRefused(#"{"cmd":"finder.open-drop","folder":""}"#, .invalidName)
    }

    func testKeysAndMediaKeys() {
        for k in KeyName.allCases {
            assertAccepted(#"{"cmd":"key","name":"\#(k.rawValue)"}"#, .key(k))
        }
        for m in MediaKeyName.allCases {
            assertAccepted(#"{"cmd":"media-key","name":"\#(m.rawValue)"}"#, .mediaKey(m))
        }
        XCTAssertEqual(KeyName.allCases.count, 8, "esc space return tab up down left right, nothing more")
        XCTAssertEqual(MediaKeyName.allCases.count, 6)
    }

    func testMeasureBounds() {
        assertAccepted(#"{"cmd":"measure.hover-expand","target":"notch"}"#, .measureHoverExpand(runs: 5))
        assertAccepted(#"{"cmd":"measure.hover-expand","target":"notch","runs":20}"#, .measureHoverExpand(runs: 20))
        assertRefused(#"{"cmd":"measure.hover-expand","target":"notch","runs":21}"#, .outOfRange)
        assertRefused(#"{"cmd":"measure.hover-expand","target":"umbar:x"}"#, .invalidName)
    }

    func testUnknownAndMissingCommand() {
        assertRefused(#"{"name":"esc"}"#, .missingCommand)
        assertRefused(#"{"cmd":5}"#, .wrongType)
        assertRefused(#"{"cmd":"STATUS"}"#, .unknownCommand)
        assertRefused(#"{"cmd":"status "}"#, .unknownCommand)
    }

    /// §3.3: unknown fields are refused on every command, including the
    /// ones that are allowed while disarmed.
    func testUnknownFieldRefusedOnEveryCommand() {
        let valid = [
            #""cmd":"status""#, #""cmd":"version""#, #""cmd":"disarm""#, #""cmd":"capture.app""#,
            #""cmd":"capture.region","name":"notch""#, #""cmd":"record.stop""#,
            #""cmd":"key","name":"esc""#, #""cmd":"media-key","name":"brightness-up""#,
            #""cmd":"pointer.hover","target":"notch""#, #""cmd":"finder.open-drop","folder":"a""#,
            #""cmd":"measure.hover-expand","target":"notch""#, #""cmd":"ax.tree","target":"umbar""#,
        ]
        for body in valid {
            assertRefused("{\(body),\"extra\":1}", .unknownField)
        }
    }

    func testGateCommandClasses() {
        XCTAssertTrue(Command.status(windows: false).allowedWhileDisarmed)
        XCTAssertFalse(Command.status(windows: true).allowedWhileDisarmed)
        XCTAssertTrue(Command.version.allowedWhileDisarmed)
        XCTAssertTrue(Command.disarm.allowedWhileDisarmed)
        XCTAssertFalse(Command.captureApp.allowedWhileDisarmed)
        XCTAssertFalse(Command.status(windows: false).countsAsActivity, "polling status must not hold the arm")
        XCTAssertTrue(Command.key(.esc).postsInput)
        XCTAssertFalse(Command.captureApp.postsInput)
    }

    func testLogParametersAreClosedVocabulary() {
        XCTAssertEqual(Command.dragShelfToFinder(shelfIndex: 2, folder: "a").logParameters,
                       ["from": "umbar-shelf:2", "to": "finder-drop:a"])
        XCTAssertEqual(Command.pointerHover(.umbar(identifier: "x"), dwellMs: 10).logParameters,
                       ["target": "umbar:x", "dwell_ms": "10"])
    }
}
