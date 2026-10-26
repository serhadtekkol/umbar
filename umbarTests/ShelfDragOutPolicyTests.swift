//
//  ShelfDragOutPolicyTests.swift
//  umbarTests
//
//  BR-3.5: what a drag out of the shelf offers, and when the item leaves the
//  shelf afterwards. AC ids refer to docs/spec.md §5 F3 (R1.1).
//
//  A real drag cannot be driven from a test; these cover the decisions the
//  drag source makes. The volume-dependent cases (second volume, read-only
//  disk image) are in ShelfDragOutVolumeTests and run from
//  scripts/shelf-move-check.sh.
//

import AppKit
import CryptoKit
import Foundation
import Testing

@Suite("ShelfDragOutPolicy.operationMask")
struct ShelfDragOutMaskTests {
    typealias Policy = ShelfDragOutPolicy

    // AC-3.3, AC-3.12: Finder gets a move and nothing else, so it cannot
    // pick a copy for another volume.
    @Test func finderIsOfferedOnlyAMove() {
        #expect(Policy.operationMask(destination: .finder, optionKeyHeld: false, copyOnDrag: false, sourcesDeletable: true) == [.move])
    }

    // AC-3.13: Mail, browsers, the Dock keep a copy to choose.
    @Test func otherAppsAreOfferedCopyAndMove() {
        let mask = Policy.operationMask(destination: .other, optionKeyHeld: false, copyOnDrag: false, sourcesDeletable: true)
        #expect(mask == [.copy, .move])
    }

    // AC-3.20: a source that cannot be removed is copied, also by Finder.
    @Test func undeletableSourceIsCopiedByFinder() {
        #expect(Policy.operationMask(destination: .finder, optionKeyHeld: false, copyOnDrag: false, sourcesDeletable: false) == [.copy])
    }

    // AC-3.14 and the copyOnDrag setting: copy everywhere.
    @Test(arguments: [ShelfDragDestination.finder, .other, .ownApp], [true, false])
    func optionOrCopyOnDragForcesCopy(_ destination: ShelfDragDestination, _ deletable: Bool) {
        #expect(Policy.operationMask(destination: destination, optionKeyHeld: true, copyOnDrag: false, sourcesDeletable: deletable) == [.copy])
        #expect(Policy.operationMask(destination: destination, optionKeyHeld: false, copyOnDrag: true, sourcesDeletable: deletable) == [.copy])
        #expect(Policy.operationMask(destination: destination, optionKeyHeld: true, copyOnDrag: true, sourcesDeletable: deletable) == [.copy])
    }

    /// AppKit intersects the mask with ⌥'s copy. An empty intersection would
    /// refuse the drop instead of copying.
    @Test(arguments: [ShelfDragDestination.finder, .other, .ownApp], [true, false])
    func optionDropIsNeverRefused(_ destination: ShelfDragDestination, _ deletable: Bool) {
        for copyOnDrag in [true, false] {
            let mask = Policy.operationMask(destination: destination, optionKeyHeld: true, copyOnDrag: copyOnDrag, sourcesDeletable: deletable)
            #expect(!mask.intersection(.copy).isEmpty)
        }
    }

    /// Without modifiers no destination is offered nothing.
    @Test(arguments: [ShelfDragDestination.finder, .other, .ownApp], [true, false])
    func maskIsNeverEmpty(_ destination: ShelfDragDestination, _ deletable: Bool) {
        #expect(!Policy.operationMask(destination: destination, optionKeyHeld: false, copyOnDrag: false, sourcesDeletable: deletable).isEmpty)
    }
}

@Suite("ShelfDragOutPolicy.endAction")
struct ShelfDragOutEndActionTests {
    typealias Policy = ShelfDragOutPolicy

    // AC-3.15: cancelled or refused drop.
    @Test(arguments: [ShelfDragDestination.finder, .other, .ownApp])
    func emptyOperationKeeps(_ destination: ShelfDragDestination) {
        #expect(Policy.endAction(operation: [], lastDestination: destination, autoRemove: true) == .keep)
    }

    // AC-3.15: dropped back onto umbar's own panel, which accepts it.
    @Test(arguments: [NSDragOperation.copy, .move, .generic])
    func dropOntoOwnPanelKeeps(_ operation: NSDragOperation) {
        #expect(Policy.endAction(operation: operation, lastDestination: .ownApp, autoRemove: true) == .keep)
    }

    // AC-3.16: setting off keeps everything.
    @Test(arguments: [NSDragOperation.copy, .move, .delete, .generic])
    func autoRemoveOffKeeps(_ operation: NSDragOperation) {
        #expect(Policy.endAction(operation: operation, lastDestination: .finder, autoRemove: false) == .keep)
    }

    // AC-3.3, AC-3.12, AC-3.17, AC-3.18 (Q-3a), AC-3.21: a move or a trash
    // drop is confirmed on disk before the item leaves.
    @Test(arguments: [NSDragOperation.move, .delete, [.move, .copy]])
    func moveIsConfirmedFirst(_ operation: NSDragOperation) {
        #expect(Policy.endAction(operation: operation, lastDestination: .finder, autoRemove: true) == .removeOnceSourceLeaves)
        #expect(Policy.endAction(operation: operation, lastDestination: .other, autoRemove: true) == .removeOnceSourceLeaves)
    }

    // AC-3.13, AC-3.14, AC-3.20: a copy leaves the original in place; the
    // item goes at once.
    @Test(arguments: [NSDragOperation.copy, .generic, .link])
    func copyRemovesNow(_ operation: NSDragOperation) {
        #expect(Policy.endAction(operation: operation, lastDestination: .other, autoRemove: true) == .remove)
        #expect(Policy.endAction(operation: operation, lastDestination: .finder, autoRemove: true) == .remove)
    }
}

@Suite("ShelfDragOutPolicy.destination")
struct ShelfDragDestinationTests {
    typealias Policy = ShelfDragOutPolicy
    static let ownPID: pid_t = 4242
    static let screen = CGRect(x: 0, y: 0, width: 2560, height: 1080)
    static let point = CGPoint(x: 1300, y: 400)

    static func window(_ bundle: String?, pid: pid_t = 100, layer: Int = 0, bounds: CGRect = screen, alpha: Double = 1) -> ShelfDragWindow {
        ShelfDragWindow(ownerPID: pid, ownerBundleID: bundle, layer: layer, bounds: bounds, alpha: alpha)
    }

    @Test func finderWindowInFront() {
        let windows = [Self.window("com.apple.finder"), Self.window("com.apple.mail")]
        #expect(Policy.destination(at: Self.point, windows: windows, ownPID: Self.ownPID) == .finder)
    }

    @Test func otherAppInFrontOfFinder() {
        let windows = [Self.window("com.apple.mail"), Self.window("com.apple.finder")]
        #expect(Policy.destination(at: Self.point, windows: windows, ownPID: Self.ownPID) == .other)
    }

    /// The window list measured on macOS 27.0.1 starts with full-screen
    /// login-window and Window Server layers far above the drag image level.
    /// They must not hide Finder's desktop.
    @Test func shieldsAndDragImageAreSkipped() {
        let windows = [
            Self.window(nil, layer: 2_147_483_630, bounds: CGRect(x: 1290, y: 390, width: 28, height: 40)),
            Self.window("com.apple.loginwindow", layer: 2001, bounds: CGRect(x: -15000, y: -15000, width: 30000, height: 30000)),
            Self.window(nil, pid: Self.ownPID, layer: 500),
            Self.window("com.apple.finder", layer: -2_147_483_603),
        ]
        #expect(Policy.destination(at: Self.point, windows: windows, ownPID: Self.ownPID) == .finder)
    }

    @Test func ownWindowsAndInvisibleWindowsAreSkipped() {
        let windows = [
            Self.window("com.serhadbahadir.umbar", pid: Self.ownPID, layer: 25),
            Self.window("com.apple.notificationcenterui", layer: 8, alpha: 0),
            Self.window("com.apple.finder"),
        ]
        #expect(Policy.destination(at: Self.point, windows: windows, ownPID: Self.ownPID) == .finder)
    }

    @Test func windowNotUnderThePointerIsSkipped() {
        let windows = [
            Self.window("com.apple.finder", bounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
            Self.window("com.google.Chrome"),
        ]
        #expect(Policy.destination(at: Self.point, windows: windows, ownPID: Self.ownPID) == .other)
    }

    @Test func menuBarOrNothingIsOther() {
        #expect(Policy.destination(at: CGPoint(x: 10, y: 10), windows: [Self.window(nil, layer: 24, bounds: CGRect(x: 0, y: 0, width: 2560, height: 30))], ownPID: Self.ownPID) == .other)
        #expect(Policy.destination(at: Self.point, windows: [], ownPID: Self.ownPID) == .other)
    }

    @Test func appKitToQuartzFlipsAroundThePrimaryScreen() {
        #expect(Policy.quartzPoint(fromAppKit: CGPoint(x: 5, y: 1080), primaryScreenHeight: 1080) == CGPoint(x: 5, y: 0))
        #expect(Policy.quartzPoint(fromAppKit: CGPoint(x: 5, y: 0), primaryScreenHeight: 1080) == CGPoint(x: 5, y: 1080))
        // A screen above the primary one has negative Quartz y.
        #expect(Policy.quartzPoint(fromAppKit: CGPoint(x: 5, y: 1500), primaryScreenHeight: 1080) == CGPoint(x: 5, y: -420))
    }
}

@Suite("ShelfFileIdentity")
struct ShelfFileIdentityTests {
    @Test func renameCopyAndRecreate() throws {
        let dir = try ScratchDir()
        let a = dir.url.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: a)
        let original = try #require(ShelfFileIdentity(path: a.path))

        // A copy elsewhere leaves the source where it is (AC-3.13, AC-3.14).
        try FileManager.default.copyItem(at: a, to: dir.url.appendingPathComponent("copy.txt"))
        #expect(!ShelfDragOutPolicy.sourceHasLeft(original: original, now: ShelfFileIdentity(path: a.path)))

        // A same-volume move is a rename: the path is empty afterwards (AC-3.3).
        let moved = dir.url.appendingPathComponent("moved.txt")
        try FileManager.default.moveItem(at: a, to: moved)
        #expect(ShelfDragOutPolicy.sourceHasLeft(original: original, now: ShelfFileIdentity(path: a.path)))
        #expect(ShelfFileIdentity(path: moved.path) == original)

        // A different file under the old name is not the file that was dragged.
        try Data("y".utf8).write(to: a)
        #expect(ShelfDragOutPolicy.sourceHasLeft(original: original, now: ShelfFileIdentity(path: a.path)))
    }

    @Test func missingPathHasNoIdentity() {
        #expect(ShelfFileIdentity(path: "/nonexistent-\(UUID().uuidString)") == nil)
    }
}

/// Counts probes and answers from a script, so the watcher runs without time.
final class ScriptedProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let answer: @Sendable (Int) -> ShelfFileIdentity?

    init(_ answer: @escaping @Sendable (Int) -> ShelfFileIdentity?) { self.answer = answer }

    var count: Int { lock.withLock { calls } }

    func probe(_ path: String) -> ShelfFileIdentity? {
        let n = lock.withLock { calls += 1; return calls }
        return answer(n)
    }
}

@MainActor
@Suite("ShelfMoveOutcomeWatcher")
struct ShelfMoveOutcomeWatcherTests {
    nonisolated static let original = ShelfFileIdentity(device: 1, inode: 7)
    static let noSleep: ShelfMoveOutcomeWatcher.Sleep = { _ in }

    static func watcher(_ probe: ScriptedProbe, polls: Int = 20) -> ShelfMoveOutcomeWatcher {
        ShelfMoveOutcomeWatcher(
            schedule: Array(repeating: .milliseconds(1), count: polls),
            probe: { probe.probe($0) },
            sleep: noSleep
        )
    }

    // AC-3.3/3.12: the item leaves once the move is visible on disk, not before.
    @Test func removesOnceTheSourceIsGone() async {
        let probe = ScriptedProbe { $0 < 5 ? Self.original : nil }
        let watcher = Self.watcher(probe)
        var left = 0
        await watcher.watch(id: UUID(), path: "/p", original: Self.original) { left += 1 }.value
        #expect(left == 1)
        #expect(probe.count == 5)
        #expect(watcher.watchedIDs.isEmpty)
    }

    // MV-4c / AC-3.18 "Stop", MV-5 / AC-3.17 disk full: Finder accepted the
    // move, then did not do it. The source never leaves, the item stays.
    @Test func keepsTheItemWhenTheMoveNeverHappens() async {
        let probe = ScriptedProbe { _ in Self.original }
        let watcher = Self.watcher(probe, polls: 30)
        var left = 0
        await watcher.watch(id: UUID(), path: "/p", original: Self.original) { left += 1 }.value
        #expect(left == 0)
        #expect(probe.count == 30, "polls the whole budget, then gives up")
        #expect(watcher.watchedIDs.isEmpty)
    }

    /// Both watches below are started and cancelled synchronously on the main
    /// actor, before their tasks get to run, so a sleep that only checks
    /// cancellation is enough to see the effect without any timing.
    static let cancellableSleep: ShelfMoveOutcomeWatcher.Sleep = { _ in try Task.checkCancellation() }

    @Test func cancelStopsTheWatch() async {
        let probe = ScriptedProbe { _ in nil }
        let watcher = ShelfMoveOutcomeWatcher(schedule: [.seconds(1)], probe: { probe.probe($0) }, sleep: Self.cancellableSleep)
        let id = UUID()
        var left = 0
        let task = watcher.watch(id: id, path: "/p", original: Self.original) { left += 1 }
        watcher.cancel(id)
        await task.value
        #expect(left == 0)
        #expect(probe.count == 0)
        #expect(watcher.watchedIDs.isEmpty)
    }

    /// A second drag of the same item replaces the first watch; the first
    /// must neither fire nor unregister the second.
    @Test func newerWatchReplacesOlder() async {
        let probe = ScriptedProbe { _ in nil }
        let watcher = ShelfMoveOutcomeWatcher(schedule: [.seconds(1)], probe: { probe.probe($0) }, sleep: Self.cancellableSleep)
        let id = UUID()
        var fired: [String] = []
        let first = watcher.watch(id: id, path: "/p", original: Self.original) { fired.append("first") }
        let second = watcher.watch(id: id, path: "/p", original: Self.original) { fired.append("second") }
        #expect(watcher.watchedIDs == [id])
        await first.value
        await second.value
        #expect(fired == ["second"])
        #expect(watcher.watchedIDs.isEmpty)
    }

    /// AC-3.3 wants the item gone within 1 s, AC-3.18 back within 2 s; a long
    /// cross-volume copy gets ten minutes before the item is kept.
    @Test func defaultScheduleShape() {
        let schedule = ShelfMoveOutcomeWatcher.defaultSchedule
        let firstSecond = schedule.prefix(5).reduce(Duration.zero, +)
        #expect(firstSecond == .seconds(1))
        #expect(schedule.reduce(Duration.zero, +) == .seconds(600))
    }

    /// The default probe against a real file moved with FileManager.
    @Test func defaultProbeSeesARealMove() async throws {
        let dir = try ScratchDir()
        let src = dir.url.appendingPathComponent("f.bin")
        try Data(repeating: 1, count: 1024).write(to: src)
        let original = try #require(ShelfFileIdentity(path: src.path))
        let watcher = ShelfMoveOutcomeWatcher(schedule: Array(repeating: .milliseconds(1), count: 3), sleep: Self.noSleep)
        try FileManager.default.moveItem(at: src, to: dir.url.appendingPathComponent("g.bin"))
        var left = false
        await watcher.watch(id: UUID(), path: src.path, original: original) { left = true }.value
        #expect(left)
    }
}

/// A temporary directory removed when the value goes away.
final class ScratchDir {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbarTests-shelfdrag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

func sha256(of url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
