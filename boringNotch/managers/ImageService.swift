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

    private init() {
        let config = URLSessionConfiguration.default
        let cache = URLCache(memoryCapacity: 50 * 1024 * 1024, // 50MB
                             diskCapacity: 100 * 1024 * 1024, // 100MB
                             diskPath: "artwork_cache")
        config.urlCache = cache
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config)

        performLegacyCacheCleanupIfNeeded()
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
        let (data, _) = try await session.data(from: url, delegate: RedirectGuard.shared)
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
