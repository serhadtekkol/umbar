//
//  ShelfMoveUndoVolumeTests.swift
//  umbarTests
//
//  Undo of a cross-volume move (card #100) against a real second volume.
//  Disabled unless scripts/shelf-move-check.sh has attached its writable disk
//  image and passed the mount point in as UMBAR_SHELF_RW_VOLUME (see
//  ShelfDragOutVolumeTests for how the variable gets here).
//
//  FileManager.moveItem stands in for Finder: across volumes it copies, then
//  deletes the source, which is what Finder does on a move-only drop. What is
//  under test is umbar's side: the FSEvents recording sees the copy appear,
//  the locator recognises it, and Undo brings the file back and sends the
//  copy to the disk image's own Trash (gone when the image is detached).
//

import Foundation
import Testing

private let otherVolume = ProcessInfo.processInfo.environment["UMBAR_SHELF_RW_VOLUME"].map { URL(fileURLWithPath: $0, isDirectory: true) }

@Suite("ShelfMoveUndo across volumes", .enabled(if: otherVolume != nil, "run scripts/shelf-move-check.sh"))
struct ShelfMoveUndoVolumeTests {
    struct Moved {
        let original: URL
        let destination: URL
        let source: ShelfDragSource
        let sha: String
        let recorder: ShelfMoveDestinationRecorder
    }

    /// Writes a file on the internal disk, starts the recording as a drag
    /// would, and moves the file onto the image under `destinationName`.
    ///
    /// The tests run in parallel and every recording sees the whole image,
    /// so each test needs a name of its own: two same-named, same-sized files
    /// arriving together are, correctly, ambiguous.
    static func moveAcross(_ dir: ScratchDir, name: String = "teklif-\(UUID().uuidString).pdf", destinationName: String? = nil, size: Int = 3 << 20) throws -> Moved {
        let volume = try #require(otherVolume)
        let original = dir.url.appendingPathComponent(name)
        try Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 131) }).write(to: original)
        let source = try #require(ShelfDragSource(url: original))
        let device = try #require(ShelfFileIdentity(path: volume.path)).device
        #expect(device != source.identity.device, "the image must be another device")

        // The live mount list must offer the image as a destination.
        #expect(ShelfMoveDestinationRecorder.watchPaths(volumes: ShelfVolume.mounted(), sourceDevices: [source.identity.device]).contains(volume.path))
        // Record the image only, so the test does not depend on other disks.
        let recorder = try #require(ShelfMoveDestinationRecorder.forDrag(of: [source], volumes: [ShelfVolume(path: volume.path, device: device, isReadOnly: false)]))

        let folder = volume.appendingPathComponent("Yedek-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(destinationName ?? name)
        let sha = try sha256(of: original)
        try FileManager.default.moveItem(at: original, to: destination)
        return Moved(original: original, destination: destination, source: source, sha: sha, recorder: recorder)
    }

    static func locate(_ moved: Moved, bookmark: Data? = nil) async -> ShelfMoveDestination {
        let recorder = moved.recorder
        return await ShelfMoveDestinationLocator.locate(source: moved.source, bookmark: bookmark, recordedPaths: { recorder.recordedPaths() })
    }

    /// Whether `name` is in this user's Trash on the image. macOS makes
    /// .Trashes unlistable (mode 1333), so the path is checked directly.
    static func isInImageTrash(_ name: String) -> Bool {
        guard let volume = otherVolume else { return false }
        let path = volume.appendingPathComponent(".Trashes/\(getuid())/\(name)").path
        return FileManager.default.fileExists(atPath: path)
    }

    @Test func moveIsFoundAndUndoneThroughTheTrash() async throws {
        let dir = try ScratchDir()
        let moved = try Self.moveAcross(dir)
        defer { moved.recorder.stop() }

        let found = await Self.locate(moved)
        guard case .found(let url, let identity) = found else {
            Issue.record("expected .found, got \(found)")
            return
        }
        #expect(url.resolvingSymlinksInPath().path == moved.destination.resolvingSymlinksInPath().path)

        let result = ShelfMoveUndoer().undo(from: url, expecting: identity, to: moved.original.path)

        #expect(result == .success(.restored))
        #expect(try sha256(of: moved.original) == moved.sha)
        #expect(!FileManager.default.fileExists(atPath: moved.destination.path))
        #expect(Self.isInImageTrash(moved.destination.lastPathComponent), "the copy went to the image's Trash, not unlinked")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.url.path).filter { $0.hasPrefix(".umbar-undo-") }
        #expect(leftovers.isEmpty)
    }

    /// The bookmark made before the move does not find a cross-volume move
    /// (it is a new file); the recording does.
    @Test func bookmarkDoesNotFollowAcrossVolumes() async throws {
        let dir = try ScratchDir()
        let name = "rapor-\(UUID().uuidString).key"
        let original = dir.url.appendingPathComponent(name)
        try Data(repeating: 9, count: 4096).write(to: original)
        let bookmark = try Bookmark(url: original).data
        try FileManager.default.removeItem(at: original) // recreated by moveAcross (test setup)
        let moved = try Self.moveAcross(dir, name: name, size: 4096)
        defer { moved.recorder.stop() }

        #expect(ShelfMoveDestinationLocator.locate(source: moved.source, bookmark: bookmark, recordedPaths: []) == .notFound)
        if case .found = await Self.locate(moved, bookmark: bookmark) {} else { Issue.record("recording should find it") }
    }

    /// Finder's "Keep Both" renames the arriving file.
    @Test func keepBothNameIsFound() async throws {
        let dir = try ScratchDir()
        let stem = "notlar-\(UUID().uuidString)"
        let moved = try Self.moveAcross(dir, name: "\(stem).txt", destinationName: "\(stem) 2.txt", size: 2048)
        defer { moved.recorder.stop() }
        guard case .found(let url, _) = await Self.locate(moved) else {
            Issue.record("expected .found")
            return
        }
        #expect(url.lastPathComponent == "\(stem) 2.txt")
    }

    /// Fail safe under a race: the original path is taken while the copy back
    /// is running. The newcomer is not replaced, the moved file stays where
    /// it is, and the staging copy is discarded through the (fake) Trash.
    @Test func originalTakenDuringTheCopyIsNotOverwritten() async throws {
        let dir = try ScratchDir()
        let moved = try Self.moveAcross(dir)
        defer { moved.recorder.stop() }
        guard case .found(let url, let identity) = await Self.locate(moved) else {
            Issue.record("expected .found")
            return
        }
        let trash = try FakeTrash(in: dir)
        let intruder = moved.original
        let undoer = ShelfMoveUndoer(trash: trash.closure) { from, to in
            try FileManager.default.copyItem(at: from, to: to)
            try Data("arrived meanwhile".utf8).write(to: intruder)
        }

        #expect(undoer.undo(from: url, expecting: identity, to: moved.original.path) == .failure(.originalOccupied))
        #expect(try String(contentsOf: moved.original, encoding: .utf8) == "arrived meanwhile")
        #expect(try sha256(of: moved.destination) == moved.sha)
        #expect(trash.items.count == 1 && trash.items[0].hasPrefix(".umbar-undo-"), "only the staging copy was discarded")
    }

    /// The copy back worked but the destination could not be trashed: the
    /// file is back, the copy stays, and the result says so.
    @Test func untrashableDestinationIsLeftAndReported() async throws {
        let dir = try ScratchDir()
        let moved = try Self.moveAcross(dir)
        defer { moved.recorder.stop() }
        guard case .found(let url, let identity) = await Self.locate(moved) else {
            Issue.record("expected .found")
            return
        }
        let trash = try FakeTrash(in: dir, fails: true)

        #expect(ShelfMoveUndoer(trash: trash.closure).undo(from: url, expecting: identity, to: moved.original.path) == .success(.restoredLeavingCopy(url)))
        #expect(try sha256(of: moved.original) == moved.sha)
        #expect(try sha256(of: moved.destination) == moved.sha)
    }

    /// A failed copy back (here: the copy step throws, as on a full or
    /// ejected disk) changes nothing.
    @Test func failedCopyChangesNothing() async throws {
        let dir = try ScratchDir()
        let moved = try Self.moveAcross(dir)
        defer { moved.recorder.stop() }
        guard case .found(let url, let identity) = await Self.locate(moved) else {
            Issue.record("expected .found")
            return
        }
        let trash = try FakeTrash(in: dir)
        let undoer = ShelfMoveUndoer(trash: trash.closure) { _, to in
            try Data("half".utf8).write(to: to)
            throw CocoaError(.fileWriteOutOfSpace)
        }

        #expect(undoer.undo(from: url, expecting: identity, to: moved.original.path) == .failure(.copyFailed))
        #expect(!FileManager.default.fileExists(atPath: moved.original.path))
        #expect(try sha256(of: moved.destination) == moved.sha)
        #expect(trash.items.count == 1, "the half-written staging copy was discarded")
    }
}
