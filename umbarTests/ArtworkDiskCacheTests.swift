//
//  ArtworkDiskCacheTests.swift
//  umbarTests
//
//  Card #79 (K15): 20 MB / 7 day policy, driven by a fake clock and a
//  throwaway directory per test.
//

import Foundation
import Testing

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    var date: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(days: Double) { lock.lock(); current += days * 86_400; lock.unlock() }
}

private func makeDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("umbar-artwork-test-\(UUID().uuidString)", isDirectory: true)
}

private func url(_ n: Int) -> URL { URL(string: "https://i.scdn.co/image/\(n)")! }

private func diskUsage(_ dir: URL) -> Int {
    let urls = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    return urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
}

@Suite("ArtworkDiskCache")
struct ArtworkDiskCacheTests {
    private let mb = 1024 * 1024

    @Test func roundTrip() {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ArtworkDiskCache(directory: dir)
        cache.store(Data([1, 2, 3]), for: url(1))
        #expect(cache.data(for: url(1)) == Data([1, 2, 3]))
        #expect(cache.data(for: url(2)) == nil)
    }

    @Test func entryOlderThanSevenDaysIsGone() {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = FakeClock()
        let cache = ArtworkDiskCache(directory: dir, now: { clock.date })
        cache.store(Data(count: 10), for: url(1))

        clock.advance(days: 6.9)
        #expect(cache.data(for: url(1)) != nil)

        clock.advance(days: 1.2)  // 8.1 days since the download
        cache.prune()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(left.isEmpty)
        #expect(cache.data(for: url(1)) == nil)
    }

    @Test func expiredEntryIsNotServedEvenBeforePrune() {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = FakeClock()
        let cache = ArtworkDiskCache(directory: dir, now: { clock.date })
        cache.store(Data(count: 10), for: url(1))
        clock.advance(days: 8)
        #expect(cache.data(for: url(1)) == nil)
    }

    @Test func exactlySevenDaysIsStillKept() {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = FakeClock()
        let cache = ArtworkDiskCache(directory: dir, now: { clock.date })
        cache.store(Data(count: 10), for: url(1))
        clock.advance(days: 7)
        #expect(cache.data(for: url(1)) != nil)
    }

    @Test func sizeCapEvictsOldestFirstAndHolds() {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = FakeClock()
        let cache = ArtworkDiskCache(directory: dir, now: { clock.date })
        // 25 MB of fake covers in 1 MB pieces, one hour apart.
        for n in 0..<25 {
            cache.store(Data(count: mb), for: url(n))
            clock.advance(days: 1.0 / 24)
        }
        #expect(diskUsage(dir) <= 20 * mb)
        #expect(cache.data(for: url(0)) == nil)   // oldest evicted
        #expect(cache.data(for: url(24)) != nil)  // newest kept
    }

    @Test func oversizedDataIsNotStoredAndEvictsNothing() {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ArtworkDiskCache(directory: dir, maxBytes: 100)
        cache.store(Data(count: 50), for: url(1))
        cache.store(Data(count: 101), for: url(2))
        #expect(cache.data(for: url(2)) == nil)
        #expect(cache.data(for: url(1)) != nil)
    }

    @Test func pruneOnLaunchHonoursBackdatedMtime() throws {
        // What the card's manual check does: a file whose mtime is 8 days back.
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("stale")
        try Data(count: 10).write(to: file)
        let now = Date()
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: file.path)
        ArtworkDiskCache(directory: dir, now: { now }).prune()
        #expect(!fm.fileExists(atPath: file.path))
    }

    @Test func clearAllRemovesEverythingAndCacheStillWorks() {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ArtworkDiskCache(directory: dir)
        cache.store(Data(count: 10), for: url(1))
        cache.clearAll()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        cache.store(Data(count: 10), for: url(2))
        #expect(cache.data(for: url(2)) != nil)
    }

    @Test func filesAreOwnerOnly() throws {
        let dir = makeDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ArtworkDiskCache(directory: dir)
        cache.store(Data(count: 10), for: url(1))
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
        let name = try #require(FileManager.default.contentsOfDirectory(atPath: dir.path).first)
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func legacyDirectoryIsRemovedOnceThenLeftAlone() throws {
        let legacy = makeDirectory(); defer { try? FileManager.default.removeItem(at: legacy) }
        let suite = "umbar-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data(count: 10).write(to: legacy.appendingPathComponent("Cache.db"))

        ArtworkCacheLocation.removeLegacyDirectoryOnce(defaults: defaults, legacy: legacy)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))

        // Second launch: flag set, so a recreated folder is not touched.
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        ArtworkCacheLocation.removeLegacyDirectoryOnce(defaults: defaults, legacy: legacy)
        #expect(FileManager.default.fileExists(atPath: legacy.path))
    }
}
