//
//  ArtworkDiskCache.swift
//  boringNotch
//
//  Card #79 (K15): album artwork on disk is capped at 20 MB and 7 days.
//
//  Foundation and CryptoKit only, so the unit test bundle can compile it
//  (it is in private/, which both targets share).
//

import CryptoKit
import Foundation

/// A small on-disk cache for downloaded artwork bytes with a hard size cap and
/// a hard maximum age.
///
/// Why a hand-rolled file cache instead of `URLCache`: `URLCache` has a byte
/// capacity but no maximum age (it honours the server's headers, and Spotify's
/// CDN sends long-lived ones), so "older than 7 days is removed" cannot be
/// stated to it. It also keeps its index in a SQLite file (`Cache.db`) whose
/// trimming we cannot observe or test. Here one file is one entry, the age is
/// the file's modification time, and the whole policy is a few lines that a
/// test can drive with a fake clock. Rejected: keeping `URLCache` and pruning
/// `Cache.db` rows ourselves (private schema).
///
/// Age is measured from when the bytes were downloaded, not from last use: the
/// retention limit exists for privacy (the cache is a listening history), so a
/// track played every day must not keep its entry alive forever.
///
/// Concurrency: every public method takes `lock`, so a prune triggered by the
/// periodic task and a store from a fetch cannot interleave. Calls are short
/// (a handful of small files) and are made off the main thread.
final class ArtworkDiskCache: @unchecked Sendable {
    /// K15: 20 MB on disk.
    static let defaultMaxBytes = 20 * 1024 * 1024
    /// K15: entries older than 7 days are removed.
    static let defaultMaxAge: TimeInterval = 7 * 24 * 60 * 60

    private let directory: URL
    private let maxBytes: Int
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private let fileManager = FileManager.default
    private let lock = NSLock()

    /// - Parameters:
    ///   - directory: Folder that holds the entries. Created on demand with
    ///     mode 0700; nothing else may live in it, because `clearAll()` and
    ///     pruning treat every file in it as an entry.
    ///   - maxBytes: Total size ceiling for all entries.
    ///   - maxAge: Entries whose download time is older than this are removed.
    ///   - now: Clock, injectable so tests need no sleeping.
    init(
        directory: URL,
        maxBytes: Int = ArtworkDiskCache.defaultMaxBytes,
        maxAge: TimeInterval = ArtworkDiskCache.defaultMaxAge,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.maxAge = maxAge
        self.now = now
    }

    /// Returns the cached bytes for `url`, or nil if absent or expired.
    /// An expired entry is deleted on the spot rather than served.
    func data(for url: URL) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let file = fileURL(for: url)
        guard let modified = modificationDate(of: file) else { return nil }
        if isExpired(modified) {
            try? fileManager.removeItem(at: file)
            return nil
        }
        return try? Data(contentsOf: file)
    }

    /// Stores `data` for `url`, then prunes so the cap holds on return.
    /// Data larger than the whole cache is not stored (it would evict
    /// everything and then itself).
    func store(_ data: Data, for url: URL) {
        guard data.count <= maxBytes else { return }
        lock.lock(); defer { lock.unlock() }
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let file = fileURL(for: url)
            try data.write(to: file, options: .atomic)
            // Atomic writes create the file with the process umask; the
            // artwork list is a listening history, so owner-only.
            try fileManager.setAttributes(
                [.posixPermissions: 0o600, .modificationDate: now()],
                ofItemAtPath: file.path)
        } catch {
            return  // A cache that cannot write is just a cache miss.
        }
        pruneLocked()
    }

    /// Removes expired entries, then the oldest ones until the total is within
    /// the cap. Run at launch and periodically (see `ImageService`).
    func prune() {
        lock.lock(); defer { lock.unlock() }
        pruneLocked()
    }

    /// Removes every entry. Called by "Delete all my data" (NFR-PRV-2, AC-D.17).
    func clearAll() {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - Private

    private struct Entry { let url: URL; let modified: Date; let size: Int }

    private func pruneLocked() {
        var entries = listEntries()
        for entry in entries where isExpired(entry.modified) {
            try? fileManager.removeItem(at: entry.url)
        }
        entries.removeAll { isExpired($0.modified) }

        var total = entries.reduce(0) { $0 + $1.size }
        // Oldest first; ties broken by name so the outcome is deterministic.
        entries.sort { ($0.modified, $0.url.lastPathComponent) < ($1.modified, $1.url.lastPathComponent) }
        for entry in entries where total > maxBytes {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private func listEntries() -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: []) else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate,
                  let size = values.fileSize else { return nil }
            return Entry(url: url, modified: modified, size: size)
        }
    }

    private func isExpired(_ modified: Date) -> Bool {
        now().timeIntervalSince(modified) > maxAge
    }

    private func modificationDate(of file: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// The URL is hashed so the file name leaks neither the album id nor
    /// path-unsafe characters.
    private func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name, isDirectory: false)
    }
}
