//
//  ImageService.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-13.
//

import Foundation
import Defaults

public protocol ImageServiceProtocol {
    func fetchImageData(from url: URL) async throws -> Data
}

public final class ImageService: ImageServiceProtocol {
    public static let shared = ImageService()

    private let session: URLSession
    private let diskCache: ArtworkDiskCache
    private var pruneTask: Task<Void, Never>?

    /// How often the age limit is enforced while the app keeps running. K15
    /// asks for "at least daily"; 6 h keeps an entry from outliving its 7 days
    /// by more than a few hours. Also pruned at launch and after every store.
    private static let pruneInterval: Duration = .seconds(6 * 60 * 60)

    private init() {
        let config = URLSessionConfiguration.default
        // Artwork persistence is ArtworkDiskCache's job (20 MB, 7 days, K15).
        // URLSession's own cache is off: URLCache cannot enforce a maximum
        // age and would write a second, unbounded-by-age copy to Cache.db.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)
        self.diskCache = ArtworkDiskCache(directory: ArtworkCacheLocation.directory())

        performLegacyCacheCleanupIfNeeded()
        ArtworkCacheLocation.removeLegacyDirectoryOnce()
        startPruning()
    }

    /// Deletes every cached artwork file. This is the hook for "Delete all my
    /// data" (NFR-PRV-2, AC-D.17, card #8); that action does not exist yet.
    public func clearAll() {
        diskCache.clearAll()
    }

    private func startPruning() {
        let cache = diskCache
        let interval = Self.pruneInterval
        pruneTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                cache.prune()
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func performLegacyCacheCleanupIfNeeded() {

        if !Defaults[.didClearLegacyURLCacheV1] {
            URLCache.shared.removeAllCachedResponses()
            Defaults[.didClearLegacyURLCacheV1] = true
        }
    }

    /// Downloads artwork bytes.
    ///
    /// Only `https` URLs on `ArtworkHostPolicy`'s allowlist are fetched, and a
    /// redirect off the allowlist is refused. Anything else throws
    /// `URLError(.unsupportedURL)` before any network I/O.
    ///
    /// The bytes are decoded by ImageIO in this (unsandboxed) process, so the
    /// allowlist is what limits which servers can feed that parser (card #41).
    public func fetchImageData(from url: URL) async throws -> Data {
        guard ArtworkHostPolicy.allows(url) else {
            throw URLError(.unsupportedURL)
        }
        if let cached = diskCache.data(for: url) { return cached }
        let (data, response) = try await session.data(from: url, delegate: RedirectGuard.shared)
        // Only successful responses are cached; an error page must not be
        // served as a cover for the next 7 days.
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
            diskCache.store(data, for: url)
        }
        return data
    }
}

/// Cancels redirects that would leave `ArtworkHostPolicy`.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RedirectGuard()

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, ArtworkHostPolicy.allows(url) else { return nil }
        return request
    }
}
