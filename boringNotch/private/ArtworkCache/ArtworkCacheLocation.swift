//
//  ArtworkCacheLocation.swift
//  boringNotch
//
//  Card #79 (K15). Where the artwork cache lives and how the pre-K15 cache
//  is retired. Foundation only so tests can compile it.
//

import Foundation

enum ArtworkCacheLocation {
    /// `~/Library/Caches/<bundle id>/Artwork`. Documented in the README
    /// privacy section; change both together.
    static func directory(fileManager: FileManager = .default) -> URL {
        cachesRoot(fileManager).appendingPathComponent("Artwork", isDirectory: true)
    }

    /// Upstream stored artwork through `URLCache(diskPath: "artwork_cache")`
    /// with a 100 MB cap and no age limit. That folder is never read again.
    static func legacyDirectory(fileManager: FileManager = .default) -> URL {
        cachesRoot(fileManager).appendingPathComponent("artwork_cache", isDirectory: true)
    }

    private static func cachesRoot(_ fileManager: FileManager) -> URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "com.serhadbahadir.umbar", isDirectory: true)
    }

    private static let migrationKey = "didRemoveLegacyArtworkCacheV2"

    /// Deletes the old 100 MB cache directory once. Idempotent on its own
    /// (removing a missing folder is a no-op); the flag only avoids a
    /// filesystem call on every launch.
    static func removeLegacyDirectoryOnce(
        defaults: UserDefaults = .standard,
        legacy: URL = legacyDirectory(),
        fileManager: FileManager = .default
    ) {
        guard !defaults.bool(forKey: migrationKey) else { return }
        try? fileManager.removeItem(at: legacy)
        defaults.set(true, forKey: migrationKey)
    }
}
