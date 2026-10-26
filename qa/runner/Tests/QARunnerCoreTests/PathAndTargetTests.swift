@testable import QARunnerCore
import XCTest

final class DropAreaTests: XCTestCase {
    private var home: TempHome!
    private var area: DropArea!

    override func setUpWithError() throws {
        home = try TempHome()
        try home.mkdir("umbar-qa/drop/case-1")
        try home.mkdir("Documents/secret")
        home.touch("umbar-qa/drop/case-1/a.png")
        area = DropArea(realHome: home.path, uid: getuid())
    }

    override func tearDown() { home.remove() }

    func testResolvesARealFolderAndFile() throws {
        let folder = try area.resolveFolder("case-1").get()
        XCTAssertEqual(folder, home.abs("umbar-qa/drop/case-1"))
        XCTAssertEqual(try area.resolveFile("a.png", inFolder: folder).get(), home.abs("umbar-qa/drop/case-1/a.png"))
    }

    func testMissingFolderOrFileRefused() {
        XCTAssertEqual(area.resolveFolder("nope").failure?.detail, "missing")
        XCTAssertEqual(area.resolveFile("b.png", inFolder: home.abs("umbar-qa/drop/case-1")).failure?.detail, "missing")
    }

    func testFolderSymlinkEscapeRefused() throws {
        try home.symlink("umbar-qa/drop/evil", to: home.abs("Documents/secret"))
        XCTAssertEqual(area.resolveFolder("evil").failure?.code, .dropPathRejected)
    }

    func testFolderSymlinkInsideDropAlsoRefused() throws {
        // Even a link that stays inside drop/ is refused: a link to
        // `drop/thing.app` would let a dot-free name open a bundle.
        try home.mkdir("umbar-qa/drop/thing.app")
        try home.symlink("umbar-qa/drop/innocent", to: home.abs("umbar-qa/drop/thing.app"))
        XCTAssertEqual(area.resolveFolder("innocent").failure?.code, .dropPathRejected)
    }

    func testDropRootSymlinkRefused() throws {
        let h2 = try TempHome()
        defer { h2.remove() }
        try h2.mkdir("umbar-qa")
        try h2.mkdir("Documents/case-1")
        try h2.symlink("umbar-qa/drop", to: h2.abs("Documents"))
        let a2 = DropArea(realHome: h2.path, uid: getuid())
        XCTAssertEqual(a2.validateRoot()?.code, .dropPathRejected)
        XCTAssertEqual(a2.resolveFolder("case-1").failure?.code, .dropPathRejected)
    }

    func testWritableDropRootRefused() throws {
        chmod(home.abs("umbar-qa/drop"), 0o777)
        XCTAssertEqual(area.validateRoot()?.detail, "root-writable")
    }

    func testTraversalNamesRefusedBeforeTheFileSystem() {
        for bad in ["..", "../../Documents", ".", "a/b", "A", "x.app", "", String(repeating: "a", count: 33)] {
            XCTAssertEqual(area.resolveFolder(bad).failure?.code, .invalidName, bad)
        }
        for bad in ["..", ".hidden", "../a.png", "a/b.png", ""] {
            XCTAssertEqual(area.resolveFile(bad, inFolder: home.abs("umbar-qa/drop/case-1")).failure?.code, .invalidName, bad)
        }
    }

    func testFileSymlinkRefused() throws {
        home.touch("Documents/secret/passwords.txt")
        try home.symlink("umbar-qa/drop/case-1/link.txt", to: home.abs("Documents/secret/passwords.txt"))
        XCTAssertEqual(area.resolveFile("link.txt", inFolder: home.abs("umbar-qa/drop/case-1")).failure?.code, .dropPathRejected)
    }

    func testFolderPathOutsideDropRefusedForFiles() {
        home.touch("Documents/secret/x.txt")
        XCTAssertEqual(area.resolveFile("x.txt", inFolder: home.abs("Documents/secret")).failure?.detail, "folder")
    }

    func testDocumentMatchesOnlyTheExactFolder() throws {
        let folder = try area.resolveFolder("case-1").get()
        XCTAssertTrue(area.documentMatches(URL(fileURLWithPath: folder).absoluteString, folderRealPath: folder))
        XCTAssertFalse(area.documentMatches(URL(fileURLWithPath: home.abs("umbar-qa/drop")).absoluteString, folderRealPath: folder))
        XCTAssertFalse(area.documentMatches(URL(fileURLWithPath: home.abs("Documents/secret")).absoluteString, folderRealPath: folder))
        XCTAssertFalse(area.documentMatches("https://example.com/", folderRealPath: folder))
        XCTAssertFalse(area.documentMatches(nil, folderRealPath: folder))
    }

    func testRootItselfIsNotInside() {
        XCTAssertFalse(area.contains(home.abs("umbar-qa/drop")))
        XCTAssertTrue(area.contains(home.abs("umbar-qa/drop/case-1")))
    }
}

final class WritePolicyTests: XCTestCase {
    private var home: TempHome!
    private var policy: WritePolicy!

    override func setUpWithError() throws {
        home = try TempHome()
        try home.mkdir("umbar-qa/evidence/run1")
        try home.mkdir("Library/Application Support/com.serhadbahadir.qarunner")
        try home.mkdir("Library/Logs/UmbarQARunner")
        try home.mkdir("Documents")
        policy = WritePolicy(realHome: home.path)
    }

    override func tearDown() { home.remove() }

    func testAllowsOnlyTheThreeRoots() {
        XCTAssertTrue(policy.isAllowed(home.abs("umbar-qa/evidence/run1/001-capture-app.png")))
        XCTAssertTrue(policy.isAllowed(home.abs("Library/Application Support/com.serhadbahadir.qarunner/x")))
        XCTAssertTrue(policy.isAllowed(home.abs("Library/Logs/UmbarQARunner/runner.jsonl")))
        XCTAssertFalse(policy.isAllowed(home.abs("Documents/x.png")))
        XCTAssertFalse(policy.isAllowed(home.abs("umbar-qa/drop.png")))
        XCTAssertFalse(policy.isAllowed("/tmp/x.png"))
    }

    func testRefusesTraversalAndSymlinkedParents() throws {
        XCTAssertFalse(policy.isAllowed(home.abs("umbar-qa/evidence/../../Documents/x.png")))
        try home.symlink("umbar-qa/evidence/out", to: home.abs("Documents"))
        XCTAssertFalse(policy.isAllowed(home.abs("umbar-qa/evidence/out/x.png")))
        XCTAssertFalse(policy.isAllowed(home.abs("umbar-qa/evidence/run1/..")))
    }

    func testRefusesASymlinkedRoot() throws {
        let h2 = try TempHome()
        defer { h2.remove() }
        try h2.mkdir("umbar-qa")
        try h2.mkdir("Documents")
        try h2.symlink("umbar-qa/evidence", to: h2.abs("Documents"))
        XCTAssertFalse(WritePolicy(realHome: h2.path).isAllowed(h2.abs("umbar-qa/evidence/x.png")))
    }
}

final class UmbarLocatorTests: XCTestCase {
    private let home = "/Users/umbarqa"

    func testBundleIDs() {
        XCTAssertTrue(UmbarLocatorPolicy.isUmbarBundleID("com.serhadbahadir.umbar"))
        XCTAssertTrue(UmbarLocatorPolicy.isUmbarBundleID("com.serhadbahadir.umbar.qa.a"))
        XCTAssertFalse(UmbarLocatorPolicy.isUmbarBundleID("com.serhadbahadir.umbar.qa."))
        XCTAssertFalse(UmbarLocatorPolicy.isUmbarBundleID("com.serhadbahadir.umbar.XPCHelper"))
        XCTAssertFalse(UmbarLocatorPolicy.isUmbarBundleID("com.serhadbahadir.umbarx"))
        XCTAssertFalse(UmbarLocatorPolicy.isUmbarBundleID("com.serhadbahadir.qarunner"))
        XCTAssertFalse(UmbarLocatorPolicy.isUmbarBundleID(nil))
    }

    func testLocations() {
        XCTAssertTrue(UmbarLocatorPolicy.isAllowedLocation("/Applications/umbar.app", realHome: home))
        XCTAssertTrue(UmbarLocatorPolicy.isAllowedLocation("/Users/umbarqa/umbar-qa/builds/abc/Debug/umbar.app", realHome: home))
        XCTAssertFalse(UmbarLocatorPolicy.isAllowedLocation("/Users/umbarqa/Downloads/umbar.app", realHome: home))
        XCTAssertFalse(UmbarLocatorPolicy.isAllowedLocation("/Users/umbarqa/umbar-qa/builds/umbar2.app", realHome: home))
        XCTAssertFalse(UmbarLocatorPolicy.isAllowedLocation("/Applications/umbar.app/Contents/x.app", realHome: home))
        XCTAssertFalse(UmbarLocatorPolicy.isAllowedLocation(nil, realHome: home))
    }

    func testSelectsExactlyOne() throws {
        let good = AppCandidate(pid: 10, bundleID: "com.serhadbahadir.umbar", bundleRealPath: "/Applications/umbar.app")
        let impostor = AppCandidate(pid: 11, bundleID: "com.serhadbahadir.umbar", bundleRealPath: "/tmp/umbar.app")
        let other = AppCandidate(pid: 12, bundleID: "com.apple.Safari", bundleRealPath: "/Applications/Safari.app")
        XCTAssertEqual(try UmbarLocatorPolicy.select([good, impostor, other], realHome: home).get(), good)
        XCTAssertEqual(UmbarLocatorPolicy.select([impostor, other], realHome: home).failure?.code, .umbarNotRunning)
        let second = AppCandidate(pid: 13, bundleID: "com.serhadbahadir.umbar.qa.b",
                                  bundleRealPath: "/Users/umbarqa/umbar-qa/builds/b/umbar.app")
        XCTAssertEqual(UmbarLocatorPolicy.select([good, second], realHome: home).failure?.code, .umbarMultipleInstances)
    }

    func testSignatureRule() {
        XCTAssertNil(UmbarLocatorPolicy.checkSignature(teamID: nil, satisfiesTeamRequirement: false), "ad-hoc A-Debug: R-5")
        XCTAssertNil(UmbarLocatorPolicy.checkSignature(teamID: "264H2ARX4K", satisfiesTeamRequirement: true))
        XCTAssertEqual(UmbarLocatorPolicy.checkSignature(teamID: "264H2ARX4K", satisfiesTeamRequirement: false)?.code, .umbarSignature)
        XCTAssertEqual(UmbarLocatorPolicy.checkSignature(teamID: "OTHERTEAM1", satisfiesTeamRequirement: true)?.code, .umbarSignature)
    }
}

final class HitTestPolicyTests: XCTestCase {
    private var home: TempHome!
    private var area: DropArea!
    private var folder: String!
    private let runner: Int32 = 100, umbar: Int32 = 200, finder: Int32 = 300

    override func setUpWithError() throws {
        home = try TempHome()
        try home.mkdir("umbar-qa/drop/case-1")
        try home.mkdir("umbar-qa/drop/case-2")
        area = DropArea(realHome: home.path, uid: getuid())
        folder = try area.resolveFolder("case-1").get()
    }

    override func tearDown() { home.remove() }

    private func verify(_ hit: HitResult, _ e: HitExpectation) -> Refusal? {
        HitTestPolicy.verify(hit, expect: e, runnerPID: runner, dropArea: area)
    }

    func testUmbarOwnedPointAccepted() {
        XCTAssertNil(verify(HitResult(pid: umbar, role: "AXButton"), .umbar(pid: umbar)))
    }

    func testFinderDropWindowAccepted() {
        let doc = URL(fileURLWithPath: folder).absoluteString
        XCTAssertNil(verify(HitResult(pid: finder, windowDocument: doc), .finderDrop(finderPID: finder, folderRealPath: folder)))
    }

    func testFinderWindowOfAnotherFolderRefused() {
        let other = URL(fileURLWithPath: home.abs("umbar-qa/drop/case-2")).absoluteString
        XCTAssertEqual(verify(HitResult(pid: finder, windowDocument: other),
                              .finderDrop(finderPID: finder, folderRealPath: folder))?.detail, "finder-window")
    }

    func testEmptyHitRefused() {
        XCTAssertEqual(verify(HitResult(pid: nil), .umbar(pid: umbar))?.code, .hitTestEmpty)
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let f) = self { return f }
        return nil
    }
}
