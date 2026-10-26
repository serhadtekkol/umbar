//
//  ShelfDragOutVolumeTests.swift
//  umbarTests
//
//  The volume-dependent half of BR-3.5, against real disks. Disabled unless
//  scripts/shelf-move-check.sh has attached its disk images and passed their
//  mount points in (xcodebuild hands TEST_RUNNER_<NAME> to the test process
//  as <NAME>):
//
//    UMBAR_SHELF_RW_VOLUME  a writable second volume (AC-3.12)
//    UMBAR_SHELF_RO_VOLUME  a read-only disk image holding `readonly.bin` (AC-3.20)
//
//  The move itself is done with FileManager here, standing in for Finder:
//  what is under test is umbar's side (the mask it offers for each source,
//  and how it confirms a move), not Finder's copy-then-delete, which a
//  script cannot trigger without a real drag.
//

import AppKit
import Foundation
import Testing

private enum Volumes {
    static let readWrite = ProcessInfo.processInfo.environment["UMBAR_SHELF_RW_VOLUME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    static let readOnly = ProcessInfo.processInfo.environment["UMBAR_SHELF_RO_VOLUME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
}

@MainActor
@Suite("ShelfDragOut on real volumes", .enabled(if: Volumes.readWrite != nil && Volumes.readOnly != nil, "run scripts/shelf-move-check.sh"))
struct ShelfDragOutVolumeTests {
    // AC-3.20: a file on a read-only image is not deletable, so Finder is
    // offered a copy.
    @Test func readOnlySourceGetsACopyMask() throws {
        let file = try #require(Volumes.readOnly).appendingPathComponent("readonly.bin")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.isDeletableFile(atPath: file.path))
        #expect(ShelfDragOutPolicy.operationMask(destination: .finder, optionKeyHeld: false, copyOnDrag: false, sourcesDeletable: false) == [.copy])
    }

    // AC-3.12: a file on the internal disk is deletable, so Finder is offered
    // a move; moving it to the second volume is confirmed only once the
    // source is gone, and the content arrives unchanged.
    @Test func crossVolumeMoveIsConfirmedAndIntact() async throws {
        let target = try #require(Volumes.readWrite)
        let dir = try ScratchDir()
        let src = dir.url.appendingPathComponent("move-me.bin")
        try Data((0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: src)
        let before = try sha256(of: src)
        let original = try #require(ShelfFileIdentity(path: src.path))
        let dest = target.appendingPathComponent("moved-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: dest) }

        #expect(FileManager.default.isDeletableFile(atPath: src.path))
        #expect(ShelfFileIdentity(path: target.path)?.device != original.device, "the second volume must be a different device")

        let watcher = ShelfMoveOutcomeWatcher(schedule: Array(repeating: .milliseconds(20), count: 100))
        var left = false
        let watch = watcher.watch(id: UUID(), path: src.path, original: original) { left = true }
        try FileManager.default.moveItem(at: src, to: dest)
        await watch.value

        #expect(left)
        #expect(!FileManager.default.fileExists(atPath: src.path))
        #expect(try sha256(of: dest) == before)
    }

    // AC-3.13/3.14 on a second volume: a copy leaves the source, so a watch
    // never confirms, and the item would stay.
    @Test func crossVolumeCopyNeverConfirms() async throws {
        let target = try #require(Volumes.readWrite)
        let dir = try ScratchDir()
        let src = dir.url.appendingPathComponent("copy-me.bin")
        try Data(repeating: 7, count: 64 << 10).write(to: src)
        let original = try #require(ShelfFileIdentity(path: src.path))
        let dest = target.appendingPathComponent("copied-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: dest) }

        try FileManager.default.copyItem(at: src, to: dest)
        let watcher = ShelfMoveOutcomeWatcher(schedule: Array(repeating: .milliseconds(5), count: 10))
        var left = false
        await watcher.watch(id: UUID(), path: src.path, original: original) { left = true }.value

        #expect(!left)
        #expect(try sha256(of: src) == sha256(of: dest))
    }
}
