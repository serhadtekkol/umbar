@testable import QARunnerCore
import XCTest

final class ArmControllerTests: XCTestCase {
    private func armed(_ d: ArmDuration = .minutes60, at now: Date = t0) -> ArmController {
        var c = ArmController(launchedAt: now)
        XCTAssertNoThrow(try c.arm(d, click: physicalClick, session: goodSession, killFilePresent: false, now: now).get())
        return c
    }

    func testStartsDisarmed() {
        let c = ArmController(launchedAt: t0)
        XCTAssertEqual(c.state, .disarmed(since: t0, reason: .launch))
        XCTAssertNil(c.remainingMinutes(now: t0))
    }

    func testArmDurationsAreExactlyTheMenuOptions() {
        XCTAssertEqual(ArmDuration.allCases.map(\.rawValue), [30, 60, 120])
        XCTAssertEqual(ArmDuration.default, .minutes60)
        XCTAssertLessThanOrEqual(ArmDuration.allCases.map(\.seconds).max()!, 120 * 60)
    }

    func testExpiresAtTheChosenDuration() {
        for d in ArmDuration.allCases {
            var c = armed(d)
            let until = t0.addingTimeInterval(d.seconds)
            // Stay active every 10 minutes so idle never fires first.
            var t = t0
            while t.addingTimeInterval(600) < until {
                t = t.addingTimeInterval(600)
                c.recordActivity(now: t)
                XCTAssertNil(c.evaluate(now: t, session: goodSession, killFilePresent: false))
            }
            XCTAssertNil(c.evaluate(now: until.addingTimeInterval(-1), session: goodSession, killFilePresent: false))
            XCTAssertEqual(c.evaluate(now: until, session: goodSession, killFilePresent: false), .expired, "\(d)")
            XCTAssertFalse(c.state.isArmed)
        }
    }

    func testIdleDisarmAfterFifteenMinutes() {
        var c = armed()
        XCTAssertNil(c.evaluate(now: t0.addingTimeInterval(15 * 60 - 1), session: goodSession, killFilePresent: false))
        XCTAssertEqual(c.evaluate(now: t0.addingTimeInterval(15 * 60), session: goodSession, killFilePresent: false), .idle)
    }

    func testActivityResetsIdleButNotTheHardLimit() {
        var c = armed(.minutes30)
        c.recordActivity(now: t0.addingTimeInterval(14 * 60))
        XCTAssertNil(c.evaluate(now: t0.addingTimeInterval(28 * 60), session: goodSession, killFilePresent: false))
        c.recordActivity(now: t0.addingTimeInterval(28 * 60))
        XCTAssertEqual(c.evaluate(now: t0.addingTimeInterval(30 * 60), session: goodSession, killFilePresent: false), .expired)
    }

    func testRemainingMinutesRoundsUp() {
        let c = armed(.minutes60)
        XCTAssertEqual(c.remainingMinutes(now: t0), 60)
        XCTAssertEqual(c.remainingMinutes(now: t0.addingTimeInterval(17 * 60 + 1)), 43)
    }

    func testSessionChangesDisarmImmediately() {
        var c = armed()
        XCTAssertEqual(c.evaluate(now: t0, session: SessionSnapshot(onConsole: true, screenLocked: false, secureInput: true),
                                  killFilePresent: false), .secureInput)
        c = armed()
        XCTAssertEqual(c.evaluate(now: t0, session: SessionSnapshot(onConsole: true, screenLocked: true, secureInput: false),
                                  killFilePresent: false), .screenLocked)
        c = armed()
        XCTAssertEqual(c.evaluate(now: t0, session: SessionSnapshot(onConsole: false, screenLocked: false, secureInput: false),
                                  killFilePresent: false), .sessionInactive)
        c = armed()
        XCTAssertEqual(c.evaluate(now: t0, session: SessionSnapshot(onConsole: nil, screenLocked: false, secureInput: false),
                                  killFilePresent: false), .sessionInactive, "unreadable session dictionary fails closed")
    }

    func testKillFileDisarms() {
        var c = armed()
        XCTAssertEqual(c.evaluate(now: t0, session: goodSession, killFilePresent: true), .killFile)
    }

    func testExitTenMinutesAfterDisarmIncludingAfterLaunch() {
        var c = ArmController(launchedAt: t0)
        XCTAssertFalse(c.shouldExit(now: t0.addingTimeInterval(599)))
        XCTAssertTrue(c.shouldExit(now: t0.addingTimeInterval(600)))
        c = armed()
        XCTAssertFalse(c.shouldExit(now: t0.addingTimeInterval(3000)), "never exits while armed")
        c.disarm(.remote, now: t0.addingTimeInterval(60))
        XCTAssertFalse(c.shouldExit(now: t0.addingTimeInterval(659)))
        XCTAssertTrue(c.shouldExit(now: t0.addingTimeInterval(660)))
    }

    func testDisarmIsIdempotent() {
        var c = armed()
        XCTAssertTrue(c.disarm(.remote, now: t0))
        XCTAssertFalse(c.disarm(.remote, now: t0))
    }

    func testRearmRestartsFromNowAndNeverExceedsDuration() {
        var c = armed(.minutes120)
        XCTAssertNoThrow(try c.arm(.minutes30, click: physicalClick, session: goodSession, killFilePresent: false,
                                   now: t0.addingTimeInterval(60)).get())
        XCTAssertEqual(c.remainingMinutes(now: t0.addingTimeInterval(60)), 30)
    }
}

final class LaunchGateTests: XCTestCase {
    private let built: Int64 = 1_800_000_000
    private func stamp(uid: UInt32? = 502, built: Int64? = 1_800_000_000, lifetime: Int64 = 14 * 86400,
                       name: String = "umbarqa") -> BuildStampValues {
        BuildStampValues(targetUID: uid, targetUserName: name, builtAt: built, expiresAt: built.map { $0 + lifetime })
    }
    private func at(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: TimeInterval(built) + offset) }

    func testStartsInTheTargetAccountBeforeExpiry() {
        XCTAssertNil(LaunchGate.check(stamp: stamp(), uid: 502, userName: "umbarqa", now: at(0)))
        XCTAssertNil(LaunchGate.check(stamp: stamp(), uid: 502, userName: "umbarqa", now: at(14 * 86400 - 1)))
    }

    func testRefusesUnstampedBuild() {
        XCTAssertEqual(LaunchGate.check(stamp: stamp(uid: nil), uid: 502, userName: "umbarqa", now: at(0))?.code, .unstampedBuild)
        XCTAssertEqual(LaunchGate.check(stamp: stamp(built: nil), uid: 502, userName: "umbarqa", now: at(0))?.code, .unstampedBuild)
    }

    func testCommittedStampIsUnstamped() {
        // The package's own BuildStamp is not importable here (it is a
        // separate module the tests do not depend on), so this mirrors its
        // shape: a binary built without build.sh must not start.
        let committed = BuildStampValues(targetUID: nil, targetUserName: "umbarqa", builtAt: nil, expiresAt: nil)
        XCTAssertEqual(LaunchGate.check(stamp: committed, uid: 502, userName: "umbarqa", now: at(0))?.code, .unstampedBuild)
    }

    func testRefusesOtherAccountsByUIDAndByName() {
        XCTAssertEqual(LaunchGate.check(stamp: stamp(), uid: 501, userName: "umbarqa", now: at(0))?.code, .wrongAccount)
        XCTAssertEqual(LaunchGate.check(stamp: stamp(), uid: 502, userName: "serhadbahadirtekkol", now: at(0))?.code, .wrongAccount)
        XCTAssertEqual(LaunchGate.check(stamp: stamp(), uid: 0, userName: "root", now: at(0))?.code, .wrongAccount)
    }

    func testRefusesAStampTargetingTheOwnerOrRoot() {
        XCTAssertEqual(LaunchGate.check(stamp: stamp(uid: 501), uid: 501, userName: "umbarqa", now: at(0))?.detail, "reserved-uid")
        XCTAssertEqual(LaunchGate.check(stamp: stamp(uid: 0), uid: 0, userName: "umbarqa", now: at(0))?.detail, "reserved-uid")
    }

    func testRefusesAStampForAnotherAccountName() {
        XCTAssertEqual(LaunchGate.check(stamp: stamp(name: "umbarqb"), uid: 502, userName: "umbarqb", now: at(0))?.code, .badStamp)
    }

    func testRefusesAfterExpiry() {
        XCTAssertEqual(LaunchGate.check(stamp: stamp(), uid: 502, userName: "umbarqa", now: at(14 * 86400))?.code, .expired)
        XCTAssertEqual(LaunchGate.check(stamp: stamp(), uid: 502, userName: "umbarqa", now: at(400 * 86400))?.code, .expired)
    }

    func testRefusesAStampLongerThanFourteenDays() {
        XCTAssertEqual(LaunchGate.check(stamp: stamp(lifetime: 14 * 86400 + 1), uid: 502, userName: "umbarqa", now: at(0))?.code, .badStamp)
        XCTAssertEqual(LaunchGate.check(stamp: stamp(lifetime: 0), uid: 502, userName: "umbarqa", now: at(0))?.code, .badStamp)
        XCTAssertEqual(LaunchGate.check(stamp: stamp(lifetime: -1), uid: 502, userName: "umbarqa", now: at(0))?.code, .badStamp)
    }

    func testRefusesAClockSetFarBeforeTheBuild() {
        // Winding the clock back is the obvious way around an expiry.
        XCTAssertNil(LaunchGate.check(stamp: stamp(), uid: 502, userName: "umbarqa", now: at(-3600)))
        XCTAssertEqual(LaunchGate.check(stamp: stamp(), uid: 502, userName: "umbarqa", now: at(-2 * 86400))?.code, .expired)
    }
}

final class PeerPolicyTests: XCTestCase {
    func testOnlyTheTestAccountMayConnect() {
        XCTAssertNil(PeerPolicy.check(peerUID: 502, expectedUID: 502))
        XCTAssertEqual(PeerPolicy.check(peerUID: 501, expectedUID: 502)?.code, .peerUIDMismatch)
        XCTAssertEqual(PeerPolicy.check(peerUID: 0, expectedUID: 502)?.code, .peerUIDMismatch, "not even root")
        XCTAssertEqual(PeerPolicy.check(peerUID: nil, expectedUID: 502)?.code, .peerUIDMismatch)
    }
}
