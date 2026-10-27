//
//  ShelfMoveUndoTests.swift
//  umbarTests
//
//  Undo for a move out of the shelf (Can B2, card #100): finding where the
//  file went, putting it back without overwriting anything, the ghost's
//  window, and the rule that umbar takes files away only through the Trash.
//
//  Everything here runs on one volume, in a scratch directory. The
//  cross-volume half is ShelfMoveUndoVolumeTests, run by
//  scripts/shelf-move-check.sh against a disk image.
//
//  Nothing in this file calls the real FileManager.trashItem: on the boot
//  volume that would put test files in the user's own Trash. Tests that can
//  reach the Trash pass `FakeTrash`, which moves into the scratch directory.
//

import Foundation
import Testing

// MARK: - Helpers

/// A clock that moves only when told to. Sleepers wake in `advance`.
final class ManualClock: ShelfUndoClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Duration = .zero
    private var sleepers: [Sleeper] = []
    private var cancelled: Set<UUID> = []

    var now: Duration { lock.withLock { current } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumeNow: Result<Void, Error>? = lock.withLock {
                    if cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    let deadline = current + duration
                    if deadline <= current { return .success(()) }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return nil
                }
                if let resumeNow { continuation.resume(with: resumeNow) }
            }
        } onCancel: {
            let sleeper: Sleeper? = lock.withLock {
                if let i = sleepers.firstIndex(where: { $0.id == id }) { return sleepers.remove(at: i) }
                cancelled.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due: [Sleeper] = lock.withLock {
            current += duration
            let due = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }
}

/// Stands in for the Trash: moves into a folder of the scratch directory and
/// records what it got.
final class FakeTrash: @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var trashed: [String] = []
    private let fails: Bool

    init(in dir: ScratchDir, fails: Bool = false) throws {
        folder = dir.url.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.fails = fails
    }

    var items: [String] { lock.withLock { trashed } }

    var closure: ShelfMoveUndoer.Trash {
        { [self] url in
            if fails { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
            lock.withLock { trashed.append(url.lastPathComponent) }
        }
    }
}

/// A Trash that must not be reached.
let trashMustNotBeCalled: ShelfMoveUndoer.Trash = { url in
    Issue.record("trash called for \(url.lastPathComponent)")
    throw CocoaError(.featureUnsupported)
}

private func write(_ text: String, to url: URL) throws {
    try Data(text.utf8).write(to: url)
}

private func setModificationTime(_ seconds: TimeInterval, of url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
}

private func realPath(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

// MARK: - Names

@Suite("ShelfMoveDestinationNames", .timeLimit(.minutes(1)))
struct ShelfMoveDestinationNamesTests {
    typealias Names = ShelfMoveDestinationNames

    @Test(arguments: ["report.pdf", "report 2.pdf", "report 13.pdf"])
    func acceptsTheNameAndFindersKeepBothForms(_ name: String) {
        #expect(Names.isCandidate(name, for: "report.pdf"))
    }

    @Test(arguments: ["report 1.pdf", "report copy.pdf", "report 2.txt", "report2.pdf", "report .pdf", "report 2 .pdf", "other.pdf", "report 2.pdf.zip", "report ２.pdf"])
    func rejectsEverythingElse(_ name: String) {
        #expect(!Names.isCandidate(name, for: "report.pdf"))
    }

    @Test func foldersAndNamesWithoutExtension() {
        #expect(Names.isCandidate("Photos", for: "Photos"))
        #expect(Names.isCandidate("Photos 2", for: "Photos"))
        #expect(!Names.isCandidate("Photos 2.jpg", for: "Photos"))
        #expect(Names.isCandidate("archive.tar 2.gz", for: "archive.tar.gz"))
    }

    /// A name written in NFD by one volume and NFC by another is one name.
    @Test func unicodeNormalisationDoesNotMatter() {
        let nfc = "teklif-\u{00F6}zet.pdf"
        let nfd = "teklif-o\u{0308}zet.pdf"
        #expect(Names.isCandidate(nfd, for: nfc))
        #expect(Names.isCandidate("teklif-o\u{0308}zet 2.pdf", for: nfc))
    }
}

// MARK: - Which volumes are watched

@Suite("ShelfMoveDestinationRecorder.watchPaths", .timeLimit(.minutes(1)))
struct ShelfMoveWatchPathsTests {
    static let volumes = [
        ShelfVolume(path: "/", device: 1, isReadOnly: false),
        ShelfVolume(path: "/System/Volumes/VM", device: 2, isReadOnly: false),
        ShelfVolume(path: "/Volumes/USB", device: 3, isReadOnly: false),
        ShelfVolume(path: "/Volumes/App", device: 4, isReadOnly: true),
    ]

    /// A move within the source's volume is a rename the bookmark follows;
    /// read-only and system volumes cannot receive a drop.
    @Test func watchesOtherWritableVolumesOnly() {
        #expect(ShelfMoveDestinationRecorder.watchPaths(volumes: Self.volumes, sourceDevices: [1]) == ["/Volumes/USB"])
        #expect(ShelfMoveDestinationRecorder.watchPaths(volumes: Self.volumes, sourceDevices: [3]) == ["/"])
    }

    /// Sources on two volumes: either could receive the other's file.
    @Test func sourcesOnSeveralVolumesWatchThemAll() {
        #expect(ShelfMoveDestinationRecorder.watchPaths(volumes: Self.volumes, sourceDevices: [1, 3]) == ["/", "/Volumes/USB"])
    }

    /// No other writable volume: no stream at all.
    @Test func nothingToWatchStartsNothing() {
        let only = [ShelfVolume(path: "/", device: 1, isReadOnly: false)]
        let source = ShelfDragSource(path: "/Users/u/a.txt", identity: ShelfFileIdentity(device: 1, inode: 9))
        #expect(ShelfMoveDestinationRecorder.forDrag(of: [source], volumes: only) == nil)
    }
}

// MARK: - Locating the destination

@MainActor
@Suite("ShelfMoveDestinationLocator", .timeLimit(.minutes(1)))
struct ShelfMoveDestinationLocatorTests {
    /// Same volume: Finder renames, the bookmark follows, the inode is the
    /// dragged one.
    @Test func sameVolumeMoveIsFoundThroughTheBookmark() throws {
        let dir = try ScratchDir()
        let src = dir.url.appendingPathComponent("teklif.pdf")
        try write("pdf", to: src)
        let source = try #require(ShelfDragSource(url: src))
        let bookmark = try Bookmark(url: src).data
        let folder = dir.url.appendingPathComponent("Yedek", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: src, to: folder.appendingPathComponent("teklif.pdf"))

        let found = ShelfMoveDestinationLocator.locate(source: source, bookmark: bookmark, recordedPaths: [])
        guard case .found(let url, let identity) = found else {
            Issue.record("expected .found, got \(found)")
            return
        }
        #expect(identity == source.identity)
        #expect(realPath(url) == realPath(folder.appendingPathComponent("teklif.pdf")))
    }

    /// A bookmark that resolves to a different file (the name was reused) is
    /// not the moved file.
    @Test func bookmarkToAnotherFileIsNotTrusted() throws {
        let dir = try ScratchDir()
        let src = dir.url.appendingPathComponent("a.txt")
        try write("one", to: src)
        let source = try #require(ShelfDragSource(url: src))
        let bookmark = try Bookmark(url: src).data
        try FileManager.default.moveItem(at: src, to: dir.url.appendingPathComponent("b.txt"))
        try FileManager.default.moveItem(at: dir.url.appendingPathComponent("b.txt"), to: dir.url.appendingPathComponent("c.txt"))
        let lookalike = ShelfDragSource(path: source.path, identity: ShelfFileIdentity(device: source.identity.device, inode: source.identity.inode &+ 1))
        #expect(ShelfMoveDestinationLocator.locate(source: lookalike, bookmark: bookmark, recordedPaths: []) == .notFound)
    }

    /// Cross-volume candidates. The source claims a device no scratch file
    /// has, so the scratch files play "the copy on the other disk".
    static func gone(_ name: String, size: UInt64, mtime: TimeInterval, isDirectory: Bool = false) -> ShelfDragSource {
        ShelfDragSource(path: "/nonexistent-\(UUID().uuidString)/\(name)", identity: ShelfFileIdentity(device: 0xDEAD_BEEF, inode: 1), isDirectory: isDirectory, size: size, modificationTime: mtime)
    }

    @Test func singleMatchingCandidateIsFound() throws {
        let dir = try ScratchDir()
        let copy = dir.url.appendingPathComponent("teklif 2.pdf")
        try write("12345", to: copy)
        try setModificationTime(1_000_000, of: copy)
        let unrelated = dir.url.appendingPathComponent("teklif.pdf")
        try write("1234567", to: unrelated) // same name, other size
        let source = Self.gone("teklif.pdf", size: 5, mtime: 1_000_000.5)

        let found = ShelfMoveDestinationLocator.locate(source: source, bookmark: nil, recordedPaths: [copy.path, unrelated.path, copy.path])
        guard case .found(let url, _) = found else {
            Issue.record("expected .found, got \(found)")
            return
        }
        #expect(url.lastPathComponent == "teklif 2.pdf")
    }

    @Test func twoLookAlikesAreAmbiguous() throws {
        let dir = try ScratchDir()
        let a = dir.url.appendingPathComponent("x.bin"), b = dir.url.appendingPathComponent("x 2.bin")
        for url in [a, b] {
            try write("same", to: url)
            try setModificationTime(2_000_000, of: url)
        }
        let found = ShelfMoveDestinationLocator.locate(source: Self.gone("x.bin", size: 4, mtime: 2_000_000), bookmark: nil, recordedPaths: [a.path, b.path])
        #expect(found == .ambiguous(count: 2))
    }

    @Test func fingerprintMismatchesAreNotFound() throws {
        let dir = try ScratchDir()
        let file = dir.url.appendingPathComponent("x.bin")
        try write("same", to: file)
        try setModificationTime(2_000_000, of: file)
        let locate = { (source: ShelfDragSource) in ShelfMoveDestinationLocator.locate(source: source, bookmark: nil, recordedPaths: [file.path]) }
        #expect(locate(Self.gone("x.bin", size: 5, mtime: 2_000_000)) == .notFound, "size")
        #expect(locate(Self.gone("x.bin", size: 4, mtime: 2_000_003)) == .notFound, "time beyond the 2 s tolerance")
        #expect(locate(Self.gone("x.bin", size: 0, mtime: 2_000_000, isDirectory: true)) == .notFound, "folder vs file")
        #expect(locate(Self.gone("y.bin", size: 4, mtime: 2_000_000)) == .notFound, "name")
        if case .found = locate(Self.gone("x.bin", size: 4, mtime: 2_000_002)) {} else { Issue.record("2 s is inside the tolerance") }
    }

    /// A candidate on the source's own device would have been found through
    /// the bookmark; the name alone is not trusted there.
    @Test func candidateOnTheSourceDeviceIsIgnored() throws {
        let dir = try ScratchDir()
        let file = dir.url.appendingPathComponent("x.bin")
        try write("same", to: file)
        let real = try #require(ShelfDragSource(url: file))
        let source = ShelfDragSource(path: "/nonexistent/x.bin", identity: ShelfFileIdentity(device: real.identity.device, inode: 1), size: real.size, modificationTime: real.modificationTime)
        #expect(ShelfMoveDestinationLocator.locate(source: source, bookmark: nil, recordedPaths: [file.path]) == .notFound)
    }

    @Test func folderIsMatchedByNameAndKind() throws {
        let dir = try ScratchDir()
        let folder = dir.url.appendingPathComponent("Photos 2", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let found = ShelfMoveDestinationLocator.locate(source: Self.gone("Photos", size: 0, mtime: 0, isDirectory: true), bookmark: nil, recordedPaths: [folder.path])
        if case .found = found {} else { Issue.record("expected .found, got \(found)") }
    }

    /// FSEvents lags; the lookup retries before it gives up.
    @Test func retriesWhileEventsAreLate() async throws {
        let dir = try ScratchDir()
        let file = dir.url.appendingPathComponent("late.bin")
        try write("late", to: file)
        try setModificationTime(3_000_000, of: file)
        let calls = Counter()
        let path = file.path
        let found = await ShelfMoveDestinationLocator.locate(
            source: Self.gone("late.bin", size: 4, mtime: 3_000_000),
            bookmark: nil,
            recordedPaths: { calls.increment() < 3 ? [] : [path] },
            sleep: { _ in }
        )
        if case .found = found {} else { Issue.record("expected .found, got \(found)") }
        #expect(calls.value == 3)
    }

    @Test func givesUpAfterTheRetries() async {
        let calls = Counter()
        let found = await ShelfMoveDestinationLocator.locate(
            source: Self.gone("never.bin", size: 1, mtime: 0),
            bookmark: nil,
            recordedPaths: { calls.increment(); return [] },
            retries: Array(repeating: .milliseconds(1), count: 4),
            sleep: { _ in }
        )
        #expect(found == .notFound)
        #expect(calls.value == 5)
    }
}

extension Task where Success == Void, Failure == Never {
    /// Awaits the task, cancelling it if the waiting test is cancelled.
    ///
    /// A plain `await task.value` ignores the waiter's cancellation, so when
    /// the suite's time limit cancels a test stuck on an expiry that never
    /// comes, the wait goes on and the run hangs instead of failing. Passing
    /// the cancellation on wakes the task's clock sleep, the task returns,
    /// and the test's expectations report what went wrong.
    var cancellableValue: Void {
        get async { await withTaskCancellationHandler { await value } onCancel: { cancel() } }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    /// Increments and returns the new value.
    @discardableResult func increment() -> Int { lock.withLock { n += 1; return n } }
}

// MARK: - Putting the file back (same volume)

@Suite("ShelfMoveUndoer on one volume", .timeLimit(.minutes(1)))
struct ShelfMoveUndoerTests {
    /// Moves `name` from the scratch root into "Yedek", as Finder would on
    /// the same disk, and returns (original, destination, identity).
    static func moved(_ dir: ScratchDir, _ name: String = "teklif.pdf", content: String = "teklif") throws -> (URL, URL, ShelfFileIdentity) {
        let original = dir.url.appendingPathComponent(name)
        try write(content, to: original)
        let folder = dir.url.appendingPathComponent("Yedek", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: original, to: destination)
        return (original, destination, try #require(ShelfFileIdentity(path: destination.path)))
    }

    @Test func undoMovesTheFileBack() throws {
        let dir = try ScratchDir()
        let (original, destination, identity) = try Self.moved(dir)
        let before = try sha256(of: destination)

        let result = ShelfMoveUndoer(trash: trashMustNotBeCalled).undo(from: destination, expecting: identity, to: original.path)

        #expect(result == .success(.restored))
        #expect(try sha256(of: original) == before)
        #expect(ShelfFileIdentity(path: original.path) == identity, "a rename, not a copy")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func undoMovesAFolderBack() throws {
        let dir = try ScratchDir()
        let original = dir.url.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try write("jpg", to: original.appendingPathComponent("1.jpg"))
        let destination = dir.url.appendingPathComponent("Photos moved", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: destination)
        let identity = try #require(ShelfFileIdentity(path: destination.path))

        #expect(ShelfMoveUndoer(trash: trashMustNotBeCalled).undo(from: destination, expecting: identity, to: original.path) == .success(.restored))
        #expect(FileManager.default.fileExists(atPath: original.appendingPathComponent("1.jpg").path))
    }

    /// Fail safe: something new at the original path is never replaced.
    @Test func occupiedOriginalPathIsNotOverwritten() throws {
        let dir = try ScratchDir()
        let (original, destination, identity) = try Self.moved(dir)
        try write("new file under the old name", to: original)
        let occupant = try sha256(of: original), moved = try sha256(of: destination)

        let result = ShelfMoveUndoer(trash: trashMustNotBeCalled).undo(from: destination, expecting: identity, to: original.path)

        #expect(result == .failure(.originalOccupied))
        #expect(try sha256(of: original) == occupant)
        #expect(try sha256(of: destination) == moved)
    }

    /// A symlink or an empty folder at the original path counts as occupied.
    @Test func anythingAtTheOriginalPathCountsAsOccupied() throws {
        let dir = try ScratchDir()
        let (original, destination, identity) = try Self.moved(dir)
        try FileManager.default.createSymbolicLink(atPath: original.path, withDestinationPath: "/nonexistent")
        #expect(ShelfMoveUndoer(trash: trashMustNotBeCalled).undo(from: destination, expecting: identity, to: original.path) == .failure(.originalOccupied))
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    /// Fail safe: the destination was deleted; nothing appears at the
    /// original path.
    @Test func deletedDestinationIsReported() throws {
        let dir = try ScratchDir()
        let (original, destination, identity) = try Self.moved(dir)
        try FileManager.default.removeItem(at: destination) // the user deleted it (test setup)

        #expect(ShelfMoveUndoer(trash: trashMustNotBeCalled).undo(from: destination, expecting: identity, to: original.path) == .failure(.destinationMissing))
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    /// The destination now holds a different file: it is not ours to move.
    @Test func replacedDestinationIsNotTouched() throws {
        let dir = try ScratchDir()
        let (original, destination, identity) = try Self.moved(dir)
        try FileManager.default.moveItem(at: destination, to: dir.url.appendingPathComponent("elsewhere.pdf"))
        try write("someone else's file", to: destination)
        let other = try sha256(of: destination)

        #expect(ShelfMoveUndoer(trash: trashMustNotBeCalled).undo(from: destination, expecting: identity, to: original.path) == .failure(.destinationChanged))
        #expect(try sha256(of: destination) == other)
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test func missingOriginalFolderIsReported() throws {
        let dir = try ScratchDir()
        let folder = dir.url.appendingPathComponent("Old", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("a.txt")
        try write("a", to: original)
        let destination = dir.url.appendingPathComponent("a.txt")
        try FileManager.default.moveItem(at: original, to: destination)
        try FileManager.default.removeItem(at: folder) // the user deleted the folder (test setup)
        let identity = try #require(ShelfFileIdentity(path: destination.path))

        #expect(ShelfMoveUndoer(trash: trashMustNotBeCalled).undo(from: destination, expecting: identity, to: original.path) == .failure(.originalFolderMissing))
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    /// No write permission on the original folder: reported, nothing moved.
    @Test func readOnlyOriginalFolderIsPermissionDenied() throws {
        let dir = try ScratchDir()
        let folder = dir.url.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("a.txt")
        try write("a", to: original)
        let destination = dir.url.appendingPathComponent("a.txt")
        try FileManager.default.moveItem(at: original, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let identity = try #require(ShelfFileIdentity(path: destination.path))

        #expect(ShelfMoveUndoer(trash: trashMustNotBeCalled).undo(from: destination, expecting: identity, to: original.path) == .failure(.permissionDenied))
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func failureCodesAreStable() {
        let all: [ShelfUndoFailure] = [.destinationMissing, .destinationChanged, .originalOccupied, .originalFolderMissing, .permissionDenied, .copyFailed, .fileSystem(errno: EIO)]
        #expect(all.map(\.code) == ["destination_missing", "destination_changed", "original_occupied", "original_folder_missing", "permission_denied", "copy_failed", "file_system_error"])
    }
}

// MARK: - The ghost and its window

@MainActor
@Suite("ShelfMoveUndoModel", .timeLimit(.minutes(1)))
struct ShelfMoveUndoModelTests {
    @MainActor
    struct Fixture {
        let dir: ScratchDir
        let clock = ManualClock()
        let model: ShelfMoveUndoModel
        let item: ShelfItem
        let source: ShelfDragSource
        let original: URL
        let destination: URL
        let identity: ShelfFileIdentity
        var restored: [(ShelfItem, Int)] { restoredBox.items }
        let restoredBox = RestoredBox()

        /// A file moved within the scratch volume, its shelf item, and a
        /// model with the manual clock.
        init(trash: @escaping ShelfMoveUndoer.Trash = trashMustNotBeCalled) throws {
            dir = try ScratchDir()
            original = dir.url.appendingPathComponent("teklif.pdf")
            try Data("teklif".utf8).write(to: original)
            source = try #require(ShelfDragSource(url: original))
            item = ShelfItem(kind: .file(bookmark: try Bookmark(url: original).data))
            let folder = dir.url.appendingPathComponent("Yedek", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            destination = folder.appendingPathComponent("teklif.pdf")
            try FileManager.default.moveItem(at: original, to: destination)
            identity = try #require(ShelfFileIdentity(path: destination.path))
            model = ShelfMoveUndoModel(clock: clock, undoer: ShelfMoveUndoer(trash: trash))
            let box = restoredBox
            model.onRestore = { box.items.append(($0, $1)) }
        }

        func record(_ result: ShelfMoveDestination? = nil, index: Int = 3) async {
            let found = result ?? .found(destination, identity: identity)
            await model.recordMove(of: item, at: index, source: source) { found }.cancellableValue
        }
    }

    @MainActor final class RestoredBox { var items: [(ShelfItem, Int)] = [] }

    @Test func ghostBecomesReadyOnceTheDestinationIsKnown() async throws {
        let f = try Fixture()
        await f.record()
        let ghost = try #require(f.model.ghost(f.item.id))
        #expect(ghost.status == .ready)
        #expect(ghost.canUndo)
        #expect(ghost.name == "teklif.pdf")
        #expect(ghost.index == 3)
        #expect(ghost.originalPath == f.original.path)
        #expect(ghost.destination == f.destination)
        #expect(!ghost.wentToTrash)
    }

    /// The approved window is 6–8 s; the default is 8.
    @Test func expiresAfterEightSecondsAndNotBefore() async throws {
        #expect(ShelfMoveUndoModel.defaultWindow == .seconds(8))
        let f = try Fixture()
        await f.record()
        let expiry = try #require(f.model.expiryTask(for: f.item.id))

        f.clock.advance(by: .milliseconds(7_999))
        await Task.yield()
        #expect(f.model.ghost(f.item.id) != nil)

        f.clock.advance(by: .milliseconds(1))
        await expiry.cancellableValue
        #expect(f.model.ghosts.isEmpty)
        #expect(f.restored.isEmpty, "expiry does not bring the item back")
        #expect(FileManager.default.fileExists(atPath: f.destination.path), "expiry does not touch the file")
    }

    @Test func undoPutsTheFileAndTheItemBack() async throws {
        let f = try Fixture()
        await f.record()

        let result = await f.model.undo(f.item.id)

        #expect(result == .success(.restored))
        #expect(f.model.ghosts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.original.path))
        #expect(!FileManager.default.fileExists(atPath: f.destination.path))
        let (item, index) = try #require(f.restored.first)
        #expect(f.restored.count == 1)
        #expect(item.id == f.item.id)
        #expect(index == 3)
        guard case .file(let data) = item.kind, let url = Bookmark(data: data).resolveURL() else {
            Issue.record("restored item has no resolvable bookmark")
            return
        }
        #expect(realPath(url) == realPath(f.original))
    }

    /// Fail safe: the original path is taken. Nothing is overwritten, the
    /// ghost stays (past its window) until the user dismisses it.
    @Test func failedUndoKeepsTheGhostUntilDismissed() async throws {
        let f = try Fixture()
        await f.record()
        try Data("new".utf8).write(to: f.original)

        let result = await f.model.undo(f.item.id)

        #expect(result == .failure(.originalOccupied))
        #expect(f.model.ghost(f.item.id)?.status == .failed(.originalOccupied))
        #expect(f.model.ghost(f.item.id)?.destination == f.destination, "kept for 'Show in Finder'")
        #expect(try String(contentsOf: f.original, encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: f.destination.path))
        #expect(f.model.expiryTask(for: f.item.id) == nil)
        f.clock.advance(by: .seconds(600))
        await Task.yield()
        #expect(f.model.ghost(f.item.id) != nil)
        #expect(await f.model.undo(f.item.id) == nil, "no second attempt from a failed ghost")

        f.model.dismiss(f.item.id)
        #expect(f.model.ghosts.isEmpty)
        #expect(f.restored.isEmpty)
    }

    /// Fail safe: the moved file was deleted before Undo.
    @Test func undoAfterTheDestinationWasDeletedFails() async throws {
        let f = try Fixture()
        await f.record()
        try FileManager.default.removeItem(at: f.destination) // the user deleted it (test setup)

        #expect(await f.model.undo(f.item.id) == .failure(.destinationMissing))
        #expect(f.model.ghost(f.item.id)?.status == .failed(.destinationMissing))
        #expect(!FileManager.default.fileExists(atPath: f.original.path))
    }

    @Test(arguments: [ShelfMoveDestination.notFound, .ambiguous(count: 2)])
    func unknownDestinationHasNoUndo(_ result: ShelfMoveDestination) async throws {
        let f = try Fixture()
        await f.record(result)
        let ghost = try #require(f.model.ghost(f.item.id))
        #expect(ghost.status == .undoUnavailable)
        #expect(!ghost.canUndo)
        #expect(await f.model.undo(f.item.id) == nil)
        #expect(FileManager.default.fileExists(atPath: f.destination.path))

        let expiry = try #require(f.model.expiryTask(for: f.item.id))
        f.clock.advance(by: .seconds(8))
        await expiry.cancellableValue
        #expect(f.model.ghosts.isEmpty)
    }

    /// WCAG 2.2.1: holding the chip stops the clock; letting go gives back
    /// the time that was left.
    @Test func pausedWindowDoesNotRunOut() async throws {
        let f = try Fixture()
        await f.record()
        f.clock.advance(by: .seconds(5))
        f.model.setExpiryPaused(true, for: f.item.id)
        #expect(f.model.expiryTask(for: f.item.id) == nil)
        f.clock.advance(by: .seconds(100))
        await Task.yield()
        #expect(f.model.ghost(f.item.id) != nil)

        f.model.setExpiryPaused(false, for: f.item.id)
        let expiry = try #require(f.model.expiryTask(for: f.item.id))
        f.clock.advance(by: .milliseconds(2_999))
        await Task.yield()
        #expect(f.model.ghost(f.item.id) != nil)
        f.clock.advance(by: .milliseconds(1))
        await expiry.cancellableValue
        #expect(f.model.ghosts.isEmpty)
    }

    @Test func dismissEndsTheGhostWithoutTouchingTheFile() async throws {
        let f = try Fixture()
        await f.record()
        f.model.dismiss(f.item.id)
        #expect(f.model.ghosts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.destination.path))
        #expect(await f.model.undo(f.item.id) == nil)
    }

    @Test func trashDestinationIsFlagged() {
        let ghost = ShelfMoveGhost(id: UUID(), name: "a", index: 0, originalPath: "/a", destination: URL(fileURLWithPath: "/Users/u/.Trash/a"), status: .ready)
        #expect(ghost.wentToTrash)
        let external = ShelfMoveGhost(id: UUID(), name: "a", index: 0, originalPath: "/a", destination: URL(fileURLWithPath: "/Volumes/USB/.Trashes/501/a"), status: .ready)
        #expect(external.wentToTrash)
    }
}

// MARK: - umbar takes files away only through the Trash

/// Can B2 fix 1 / card #100 AC 1, checked on the source text, because no
/// single test can drive every path that might delete something.
///
/// `removeItem` is allowed only where umbar deletes files it created itself
/// in its temporary directory (text/data drops, zip working copies, SwiftUI
/// file-promise leftovers), never a file the user put on the shelf. A new
/// call anywhere, or another call in those files, fails this test and needs
/// a decision; it is not a matter of updating the numbers.
@Suite("Deletion rule", .timeLimit(.minutes(1)))
struct ShelfDeletionRuleTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static let allowedRemoveItem: [String: Int] = [
        "boringNotch/components/Shelf/Services/TemporaryFileStorageService.swift": 3,
        "boringNotch/extensions/NSItemProvider+LoadHelpers.swift": 2,
        // umbar's own artwork cache under ~/Library/Caches/<bundle id>/Artwork (#79)
        "boringNotch/private/ArtworkCache/ArtworkDiskCache.swift": 4,
        "boringNotch/private/ArtworkCache/ArtworkCacheLocation.swift": 1,
    ]

    static func appSources() throws -> [String: String] {
        var sources: [String: String] = [:]
        for root in ["boringNotch", "BoringNotchXPCHelper"] {
            let base = repo.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                let relative = String(url.path.dropFirst(repo.path.count + 1))
                sources[relative] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return sources
    }

    static func count(_ needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    @Test func removeItemOnlyForUmbarsOwnTemporaryFiles() throws {
        let sources = try Self.appSources()
        #expect(sources.count > 50, "found the app sources at \(Self.repo.path)")
        var found: [String: Int] = [:]
        for (path, text) in sources {
            let n = Self.count("removeItem(", in: text)
            if n > 0 { found[path] = n }
        }
        #expect(found == Self.allowedRemoveItem)
    }

    @Test func shelfDragCodeDeletesNothingDirectly() throws {
        let sources = try Self.appSources()
        for path in [
            "boringNotch/components/Shelf/Services/ShelfDropService.swift",
            "boringNotch/components/Shelf/ViewModels/ShelfStateViewModel.swift",
            "boringNotch/components/Shelf/Views/ShelfItemView.swift",
        ] {
            let text = try #require(sources[path], "\(path) exists")
            for call in ["removeItem(", "unlink(", "rmdir(", "remove(at: URL", "Darwin.remove("] {
                #expect(Self.count(call, in: text) == 0, "\(call) in \(path)")
            }
        }
        let undo = try #require(sources["boringNotch/components/Shelf/Services/ShelfDropService.swift"])
        #expect(Self.count("trashItem(", in: undo) == 1, "the one way umbar takes a file away")
    }
}
