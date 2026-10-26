import CoreGraphics
@testable import QARunnerCore
import XCTest

/// One rejection test per "never" in docs/qa-gui-runner.md (§3.2, §3.3,
/// §3.4, §3.5 "Hiçbir zaman", §3.8). Test names cite the clause. Rules that
/// are about what the binary *contains* rather than what it accepts are in
/// `ForbiddenAPITests` (source scan) and in build.sh (`nm` on the binary).
final class NeverListTests: XCTestCase {

    // MARK: §3.5 never: free text / Unicode typing

    func testNever_freeTextTyping() {
        assertRefused(#"{"cmd":"type","text":"hello"}"#, .unknownCommand)
        assertRefused(#"{"cmd":"key","name":"a"}"#, .invalidName)
        assertRefused(#"{"cmd":"key","name":"A"}"#, .invalidName)
        assertRefused(#"{"cmd":"key","name":"1"}"#, .invalidName)
        assertRefused(#"{"cmd":"key","name":"esc","text":"x"}"#, .unknownField)
        assertRefused("{\"cmd\":\"key\",\"name\":\"ş\"}", .unsupportedValue)
        assertRefused(#"{"cmd":"key","keycode":0}"#, .missingField)
        assertRefused(#"{"cmd":"key","name":"esc","keycode":0}"#, .unknownField)
        assertRefused(#"{"cmd":"key.raw","code":53}"#, .unknownCommand)
    }

    // MARK: §3.5 never: Cmd/Ctrl/Opt/Shift combinations

    func testNever_modifierCombinations() {
        assertRefused(#"{"cmd":"key","name":"esc","mods":"cmd"}"#, .unknownField)
        assertRefused(#"{"cmd":"key","name":"space","shift":true}"#, .unknownField)
        assertRefused(#"{"cmd":"key","name":"cmd+c"}"#, .invalidName)
        assertRefused(#"{"cmd":"key","name":"cmd"}"#, .invalidName)
        assertRefused(#"{"cmd":"key","name":"fn"}"#, .invalidName)
        assertRefused(#"{"cmd":"pointer.click","target":"umbar:x","mods":"opt"}"#, .unknownField)
        assertRefused(#"{"cmd":"media-key","name":"volume-up","mods":"shift"}"#, .unknownField)
    }

    func testNever_keyCodesAreOnlyTheEightAllowedKeys() {
        // kVK_ codes for esc space return tab and the four arrows; none is a
        // modifier (0x37..0x3E) or a letter/number key.
        XCTAssertEqual(Set(KeyName.allCases.map(\.virtualKeyCode)), [0x35, 0x31, 0x24, 0x30, 0x7B, 0x7C, 0x7D, 0x7E])
    }

    // MARK: §3.5 never: click/hover/drag outside umbar and the test Finder window

    func testNever_pointerToCoordinatesOrForeignTargets() {
        assertRefused(#"{"cmd":"pointer.hover","target":"notch","x":10,"y":10}"#, .unknownField)
        assertRefused(#"{"cmd":"pointer.hover","target":"finder:Desktop"}"#, .invalidName)
        assertRefused(#"{"cmd":"pointer.hover","target":"com.apple.Safari:button"}"#, .invalidName)
        assertRefused(#"{"cmd":"pointer.hover","target":"10,10"}"#, .invalidName)
        assertRefused(#"{"cmd":"pointer.click","target":"notch"}"#, .invalidName)
        assertRefused(#"{"cmd":"pointer.click","target":"finder-drop:a"}"#, .invalidName)
        assertRefused(#"{"cmd":"pointer.click","target":"umbar:x","pid":123}"#, .unknownField)
        assertRefused(#"{"cmd":"pointer.click","target":"umbar:x","button":"right"}"#, .unknownField)
        assertRefused(#"{"cmd":"pointer.doubleclick","target":"umbar:x"}"#, .unknownCommand)
    }

    func testNever_dragOutsideTheTwoSanctionedDirections() {
        assertRefused(#"{"cmd":"drag","from":"umbar-shelf:0","to":"finder-drop:../../Documents"}"#, .invalidName)
        assertRefused(#"{"cmd":"drag","from":"umbar-shelf:0","to":"desktop"}"#, .invalidName)
        assertRefused(#"{"cmd":"drag","from":"umbar-shelf:0","to":"umbar-shelf"}"#, .invalidName)
        assertRefused(#"{"cmd":"drag","from":"finder-drop:a.png","to":"finder-drop:b"}"#, .invalidName)
        assertRefused(#"{"cmd":"drag","from":"finder-drop:../x","to":"umbar-shelf"}"#, .invalidName)
        assertRefused(#"{"cmd":"drag","from":"10,10","to":"20,20"}"#, .invalidName)
        assertRefused(#"{"cmd":"drag","from":"umbar-shelf:0","to":"finder-drop:a","x":1}"#, .unknownField)
    }

    func testNever_hitOnAnotherAppIsRefused() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.mkdir("umbar-qa/drop/a")
        let area = DropArea(realHome: home.path, uid: getuid())
        let folder = try area.resolveFolder("a").get()
        // Something else (Safari, a notification, Dock) is under the point.
        XCTAssertEqual(HitTestPolicy.verify(HitResult(pid: 999), expect: .umbar(pid: 200), runnerPID: 100, dropArea: area)?.code,
                       .hitTestNotOwned)
        // umbar is not Finder, and a Finder window of another location is
        // not the test window.
        XCTAssertEqual(HitTestPolicy.verify(HitResult(pid: 200), expect: .finderDrop(finderPID: 300, folderRealPath: folder),
                                            runnerPID: 100, dropArea: area)?.code, .hitTestNotOwned)
        XCTAssertEqual(HitTestPolicy.verify(HitResult(pid: 300, windowDocument: URL(fileURLWithPath: home.path).absoluteString),
                                            expect: .finderDrop(finderPID: 300, folderRealPath: folder),
                                            runnerPID: 100, dropArea: area)?.code, .hitTestNotOwned)
    }

    func testNever_keysWithoutFocusInUmbar() {
        XCTAssertNil(HitTestPolicy.verifyFocus(focusedPID: 200, umbarPID: 200, runnerPID: 100))
        XCTAssertEqual(HitTestPolicy.verifyFocus(focusedPID: 999, umbarPID: 200, runnerPID: 100)?.code, .focusNotInUmbar)
        XCTAssertEqual(HitTestPolicy.verifyFocus(focusedPID: nil, umbarPID: 200, runnerPID: 100)?.code, .focusNotInUmbar)
        XCTAssertEqual(HitTestPolicy.verifyFocus(focusedPID: 100, umbarPID: 100, runnerPID: 100)?.code, .focusNotInUmbar)
    }

    // MARK: §3.5 never: another app's AX tree or window content

    func testNever_axTreeOfAnotherApp() {
        assertRefused(#"{"cmd":"ax.tree","target":"finder"}"#, .invalidName)
        assertRefused(#"{"cmd":"ax.tree","target":"com.apple.Safari"}"#, .invalidName)
        assertRefused(#"{"cmd":"ax.tree","target":"umbar","pid":1}"#, .unknownField)
        assertRefused(#"{"cmd":"ax.tree","target":"system"}"#, .invalidName)
        XCTAssertEqual(Set(AXTreeTarget.allCases), [.umbar, .finderDrop])
    }

    func testNever_secureTextFieldValue() {
        let n = AXNode(role: "AXSecureTextField", subrole: nil, identifier: nil, title: "Password", value: "hunter2",
                       frame: nil, enabled: true)
        XCTAssertNil(n.value)
        let n2 = AXNode(role: "AXTextField", subrole: "AXSecureTextField", identifier: nil, title: nil, value: "hunter2",
                        frame: nil, enabled: true)
        XCTAssertNil(n2.value)
        XCTAssertFalse(AXValuePolicy.shouldReadValue(role: "AXSecureTextField", subrole: nil))
        XCTAssertFalse(AXValuePolicy.shouldReadValue(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertTrue(AXValuePolicy.shouldReadValue(role: "AXStaticText", subrole: nil))
    }

    func testNever_pointerOnASecureField() throws {
        let home = try TempHome()
        defer { home.remove() }
        let area = DropArea(realHome: home.path, uid: getuid())
        XCTAssertEqual(HitTestPolicy.verify(HitResult(pid: 200, role: "AXSecureTextField"), expect: .umbar(pid: 200),
                                            runnerPID: 100, dropArea: area)?.detail, "secure-field")
    }

    // MARK: §3.5 never: full-screen capture, free rectangles

    func testNever_fullScreenOrFreeRectangleCapture() {
        assertRefused(#"{"cmd":"capture.region","name":"full"}"#, .invalidName)
        assertRefused(#"{"cmd":"capture.region","name":"screen"}"#, .invalidName)
        assertRefused(#"{"cmd":"capture.region","name":"notch","x":0,"y":0,"w":1470,"h":956}"#, .unknownField)
        assertRefused(#"{"cmd":"capture.display"}"#, .unknownCommand)
        assertRefused(#"{"cmd":"capture.window","id":1}"#, .unknownCommand)
        assertRefused(#"{"cmd":"record.start","target":"screen"}"#, .invalidName)
    }

    func testNever_capturePlanCoveringTheDisplay() {
        XCTAssertEqual(CapturePlanner.validate(.displayRect(airDisplay.bounds), display: airDisplay)?.code, .regionRejected)
        XCTAssertEqual(CapturePlanner.validate(.displayRect(CGRect(x: 0, y: 0, width: 1470, height: 360)), display: airDisplay)?.detail,
                       "too-large")
        XCTAssertEqual(CapturePlanner.validate(.displayRect(CGRect(x: 0, y: 0, width: 585, height: 361)), display: airDisplay)?.detail,
                       "too-large")
        XCTAssertEqual(CapturePlanner.validate(.displayRect(CGRect(x: -10, y: 0, width: 100, height: 100)), display: airDisplay)?.detail,
                       "outside-display")
        XCTAssertEqual(CapturePlanner.validate(.displayRect(.zero), display: airDisplay)?.detail, "empty")
        // A display so small that the notch region would be all of it.
        let tiny = DisplayGeometry(bounds: CGRect(x: 0, y: 0, width: 400, height: 300), notchWidth: 100)
        XCTAssertEqual(CapturePlanner.plan(region: .notch, display: tiny, finderDropWindowID: nil).failure?.detail, "full-screen")
    }

    func testNever_alertCaptureBeforeT6FillsTheOwnerList() {
        for name in AlertName.allCases {
            XCTAssertEqual(AlertAllowlist.owners(for: name).failure?.code, .alertAllowlistEmpty)
        }
    }

    func testNever_recordingWithAudioOrLongerThan30s() {
        assertRefused(#"{"cmd":"record.start","target":"app","max_s":31}"#, .outOfRange)
        assertRefused(#"{"cmd":"record.start","target":"app","max_s":3600}"#, .outOfRange)
        assertRefused(#"{"cmd":"record.start","target":"app","audio":true}"#, .unknownField)
        assertRefused(#"{"cmd":"record.start","target":"app","microphone":true}"#, .unknownField)
    }

    // MARK: §3.5 never: pasteboard read/write

    func testNever_pasteboard() {
        assertRefused(#"{"cmd":"pasteboard.read"}"#, .unknownCommand)
        assertRefused(#"{"cmd":"pasteboard.write","text":"x"}"#, .unknownCommand)
        assertRefused(#"{"cmd":"clipboard"}"#, .unknownCommand)
    }

    // MARK: §3.5 never: events to the lock screen, login window, password prompts

    func testNever_eventsWhileLockedOrSecureInputOrBackground() {
        let locked = SessionSnapshot(onConsole: true, screenLocked: true, secureInput: false)
        let secure = SessionSnapshot(onConsole: true, screenLocked: false, secureInput: true)
        let background = SessionSnapshot(onConsole: false, screenLocked: false, secureInput: false)
        let unknown = SessionSnapshot(onConsole: nil, screenLocked: false, secureInput: false)
        for command in [Command.key(.return), .pointerClick(umbarIdentifier: "x"), .pointerHover(.notch, dwellMs: 0),
                        .mediaKey(.brightnessUp), .measureHoverExpand(runs: 1), .captureApp] {
            XCTAssertEqual(CommandGate.evaluate(command, isArmed: true, session: locked, killFilePresent: false)?.code, .screenLocked)
            XCTAssertEqual(CommandGate.evaluate(command, isArmed: true, session: secure, killFilePresent: false)?.code, .secureInput)
            XCTAssertEqual(CommandGate.evaluate(command, isArmed: true, session: background, killFilePresent: false)?.code, .notOnConsole)
            XCTAssertEqual(CommandGate.evaluate(command, isArmed: true, session: unknown, killFilePresent: false)?.code, .notOnConsole)
        }
    }

    func testNever_secureInputKeepsTheRunnerArmed() {
        var c = ArmController(launchedAt: t0)
        _ = c.arm(.minutes60, click: physicalClick, session: goodSession, killFilePresent: false, now: t0)
        c.evaluate(now: t0.addingTimeInterval(1), session: SessionSnapshot(onConsole: true, screenLocked: false, secureInput: true),
                   killFilePresent: false)
        XCTAssertFalse(c.state.isArmed, "§3.2 rule 6: secure input disarms")
    }

    // MARK: §3.5 never: launching applications (except the Finder test folder)

    func testNever_launchingApplications() throws {
        assertRefused(#"{"cmd":"app.launch","bundle":"com.apple.Terminal"}"#, .unknownCommand)
        assertRefused(#"{"cmd":"open","path":"/Applications/Safari.app"}"#, .unknownCommand)
        assertRefused(#"{"cmd":"finder.open-drop","folder":"x.app"}"#, .invalidName)
        assertRefused(#"{"cmd":"finder.open-drop","folder":"/Applications"}"#, .invalidName)
        assertRefused(#"{"cmd":"finder.open-drop","folder":"a","app":"Terminal"}"#, .unknownField)
        // A dot-free name that is a symlink to a bundle is refused by the
        // file-system check.
        let home = try TempHome()
        defer { home.remove() }
        try home.mkdir("umbar-qa/drop")
        try home.mkdir("Applications/Calculator.app/Contents")
        try home.symlink("umbar-qa/drop/calc", to: home.abs("Applications/Calculator.app"))
        XCTAssertEqual(DropArea(realHome: home.path, uid: getuid()).resolveFolder("calc").failure?.code, .dropPathRejected)
    }

    func testNever_openDropEscapeViaSymlink() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.mkdir("umbar-qa/drop")
        try home.mkdir("Documents")
        try home.symlink("umbar-qa/drop/docs", to: home.abs("Documents"))
        assertRefused(#"{"cmd":"finder.open-drop","folder":"../../Documents"}"#, .invalidName)
        XCTAssertEqual(DropArea(realHome: home.path, uid: getuid()).resolveFolder("docs").failure?.code, .dropPathRejected)
    }

    // MARK: §3.5 never: changing system settings, touching TCC

    func testNever_settingsOrTCCCommands() {
        assertRefused(#"{"cmd":"defaults.write","key":"x"}"#, .unknownCommand)
        assertRefused(#"{"cmd":"tcc.reset"}"#, .unknownCommand)
        assertRefused(#"{"cmd":"volume.set","level":100}"#, .unknownCommand)
        assertRefused(#"{"cmd":"media-key","name":"mute"}"#, .invalidName)
    }

    // MARK: §3.5 never: events to the runner's own window

    func testNever_eventsToTheRunnersOwnWindow() throws {
        let home = try TempHome()
        defer { home.remove() }
        let area = DropArea(realHome: home.path, uid: getuid())
        XCTAssertEqual(HitTestPolicy.verify(HitResult(pid: 100), expect: .umbar(pid: 200), runnerPID: 100, dropArea: area)?.code,
                       .targetIsRunner)
        // Even if the locator were fooled into thinking the runner is umbar.
        XCTAssertEqual(HitTestPolicy.verify(HitResult(pid: 100), expect: .umbar(pid: 100), runnerPID: 100, dropArea: area)?.code,
                       .targetIsRunner)
        XCTAssertFalse(UmbarLocatorPolicy.isUmbarBundleID(RunnerIdentity.bundleID))
    }

    // MARK: §3.4 never: arming over SSH; only a physical click arms

    func testNever_armOverTheSocket() {
        assertRefused(#"{"cmd":"arm"}"#, .unknownCommand)
        assertRefused(#"{"cmd":"arm","minutes":60}"#, .unknownCommand)
        assertRefused(#"{"cmd":"status","arm":true}"#, .unknownField)
        assertRefused(#"{"cmd":"disarm","minutes":60}"#, .unknownField)
    }

    func testNever_armBySyntheticClick() {
        XCTAssertEqual(ArmTriggerPolicy.validate(ClickEvidence(kind: .leftMouseUp, sourceUnixPID: 4242, age: 0.01))?.detail, "synthetic")
        XCTAssertEqual(ArmTriggerPolicy.validate(ClickEvidence(kind: .leftMouseUp, sourceUnixPID: -1, age: 0.01))?.detail, "synthetic")
    }

    func testNever_armByAXPressOrStaleEvent() {
        XCTAssertEqual(ArmTriggerPolicy.validate(nil)?.detail, "no-event")
        XCTAssertEqual(ArmTriggerPolicy.validate(ClickEvidence(kind: .leftMouseUp, sourceUnixPID: 0, age: 30))?.detail, "stale")
        XCTAssertEqual(ArmTriggerPolicy.validate(ClickEvidence(kind: .leftMouseUp, sourceUnixPID: 0, age: -1))?.detail, "stale")
    }

    func testNever_armByKeyboard() {
        XCTAssertEqual(ArmTriggerPolicy.validate(ClickEvidence(kind: .other, sourceUnixPID: 0, age: 0.01))?.detail, "not-mouse")
    }

    func testNever_armWhileKillFileOrBadSession() {
        var c = ArmController(launchedAt: t0)
        XCTAssertEqual(c.arm(.minutes60, click: physicalClick, session: goodSession, killFilePresent: true, now: t0).failure?.code,
                       .killFilePresent)
        XCTAssertEqual(c.arm(.minutes60, click: physicalClick,
                             session: SessionSnapshot(onConsole: true, screenLocked: false, secureInput: true),
                             killFilePresent: false, now: t0).failure?.code, .secureInput)
        XCTAssertEqual(c.arm(.minutes60, click: physicalClick,
                             session: SessionSnapshot(onConsole: false, screenLocked: false, secureInput: false),
                             killFilePresent: false, now: t0).failure?.code, .notOnConsole)
        XCTAssertFalse(c.state.isArmed)
    }

    func testNever_armLongerThan120Minutes() {
        XCTAssertNil(ArmDuration(rawValue: 180))
        XCTAssertNil(ArmDuration(rawValue: 121))
        XCTAssertNil(ArmDuration(rawValue: 0))
    }

    func testNever_commandsWhileDisarmed() {
        for command in [Command.captureApp, .key(.esc), .pointerHover(.notch, dwellMs: 0), .axTree(.umbar, depth: 1),
                        .finderOpenDrop(folder: "a"), .status(windows: true), .recordStart(.app, maxSeconds: 1)] {
            XCTAssertEqual(CommandGate.evaluate(command, isArmed: false, session: goodSession, killFilePresent: false)?.code,
                           .disarmed, "\(command)")
        }
        XCTAssertNil(CommandGate.evaluate(.status(windows: false), isArmed: false, session: goodSession, killFilePresent: false))
        XCTAssertNil(CommandGate.evaluate(.version, isArmed: false, session: goodSession, killFilePresent: false))
    }

    func testNever_commandsWhileKillFilePresent() {
        XCTAssertEqual(CommandGate.evaluate(.captureApp, isArmed: true, session: goodSession, killFilePresent: true)?.code,
                       .killFilePresent)
        // ... but disarm always goes through, whatever the state.
        XCTAssertNil(CommandGate.evaluate(.disarm, isArmed: true, session: goodSession, killFilePresent: true))
        XCTAssertNil(CommandGate.evaluate(.disarm, isArmed: false,
                                          session: SessionSnapshot(onConsole: false, screenLocked: true, secureInput: true),
                                          killFilePresent: true))
    }

    // MARK: §3.3 never: a "temporarily allow everything" debug flag

    func testNever_debugOrOverrideFlags() {
        for flag in ["debug", "force", "allow_all", "unsafe", "override", "bypass"] {
            assertRefused(#"{"cmd":"capture.app","\#(flag)":true}"#, .unknownField)
            assertRefused(#"{"cmd":"status","\#(flag)":true}"#, .unknownField)
        }
    }

    func testNever_oversizeOrNonStrictLines() {
        assertRefused(#"{"cmd":"status","pad":"\#(String(repeating: "x", count: 5000))"}"#, .lineTooLong)
        assertRefused(#"{"cmd":"status","cmd":"key","name":"esc"}"#, .duplicateField)
        assertRefused(#"{"cmd":"key","name":"esc\u0000"}"#, .unsupportedValue)
    }

    func testNever_peerOfAnotherUID() {
        XCTAssertEqual(PeerPolicy.check(peerUID: 501, expectedUID: 502)?.code, .peerUIDMismatch)
    }

    // MARK: §3.2 rules 4 and 5: other account, expired build

    func testNever_runInAnotherAccountOrAfterExpiry() {
        let stamp = BuildStampValues(targetUID: 502, targetUserName: "umbarqa", builtAt: 1_800_000_000,
                                     expiresAt: 1_800_000_000 + 14 * 86400)
        let now = Date(timeIntervalSince1970: 1_800_000_100)
        XCTAssertEqual(LaunchGate.check(stamp: stamp, uid: 501, userName: "serhadbahadirtekkol", now: now)?.code, .wrongAccount)
        XCTAssertEqual(LaunchGate.check(stamp: stamp, uid: 502, userName: "umbarqa",
                                        now: Date(timeIntervalSince1970: 1_800_000_000 + 15 * 86400))?.code, .expired)
    }

    // MARK: §3.2 rule 7: writes only under the allowed roots

    func testNever_writeOutsideAllowedRoots() throws {
        let home = try TempHome()
        defer { home.remove() }
        try home.mkdir("umbar-qa/evidence")
        try home.mkdir("Desktop")
        let policy = WritePolicy(realHome: home.path)
        XCTAssertFalse(policy.isAllowed(home.abs("Desktop/x.png")))
        XCTAssertFalse(policy.isAllowed(home.abs("umbar-qa/drop/x.png")))
        XCTAssertFalse(policy.isAllowed(home.abs(".ssh/authorized_keys")))
        XCTAssertFalse(policy.isAllowed("/Library/LaunchAgents/x.plist"))
        XCTAssertTrue(policy.isAllowed(home.abs("umbar-qa/evidence/x.png")))
    }

    // MARK: §3.8 never: AX values in the logs

    func testNever_axValuesInLogs() {
        let secret = "NOTE-CONTENT-7f3a"
        let tree = AXNode(role: "AXWindow", subrole: nil, identifier: "panel", title: "umbar", value: nil, frame: nil, enabled: true,
                          children: [AXNode(role: "AXStaticText", subrole: nil, identifier: nil, title: nil, value: secret,
                                            frame: nil, enabled: true)])
        // The value does travel on the socket...
        let wire = String(decoding: Response.success(["tree": tree.json]).line(), as: UTF8.self)
        XCTAssertTrue(wire.contains(secret))
        // ...but what the executor logs for ax.tree is a node count.
        let record = LogRecord(time: t0, event: .accepted, command: Command.axTree(.umbar, depth: 12).wireName,
                               parameters: Command.axTree(.umbar, depth: 12).logParameters, armed: true,
                               detail: LogDetail(nodeCount: tree.nodeCount))
        XCTAssertFalse(String(decoding: record.jsonLine(), as: UTF8.self).contains(secret))
        XCTAssertFalse(record.summary.contains(secret))
        XCTAssertEqual(tree.nodeCount, 2)
    }

    func testNever_axValueLongerThanTheCap() {
        let long = String(repeating: "x", count: 10_000)
        let n = AXNode(role: "AXStaticText", subrole: nil, identifier: nil, title: nil, value: long, frame: nil, enabled: nil)
        XCTAssertEqual(n.value?.count, CommandLimits.axMaxValueLength)
    }
}
