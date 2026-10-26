//
//  ArtworkImageDecoder.swift
//  boringNotch
//
//  Kept apart from ImageService so the unit test bundle can compile it
//  without ImageService's Defaults dependency (card #56).
//

import Foundation
import ImageIO

/// Decodes untrusted artwork bytes with bounded cost (card #70).
///
/// Now Playing artwork is whatever the app that owns the session publishes;
/// for a browser that is the page's `navigator.mediaSession` artwork, i.e.
/// internet-controlled bytes parsed by ImageIO in this unsandboxed process.
/// So: only PNG, JPEG and HEIC reach a decoder (type sniffed from the bytes,
/// not trusted from any label), the encoded size and the source dimensions
/// are capped, and the decoded bitmap is a thumbnail of at most
/// `maxPixelSize` on its long side, whatever the source claims.
///
/// All functions are synchronous and must be called off the main thread
/// (asserted in Debug builds).
enum ArtworkImageDecoder {
    /// Largest encoded artwork accepted from the Now Playing adapter.
    static let maxEncodedBytes = 4 * 1024 * 1024
    /// Long side of the decoded image. The notch shows artwork at well under
    /// 200 pt, so 1024 px leaves room for Retina and the blurred background.
    static let maxPixelSize = 1024
    /// Sources claiming more pixels than this are not decoded at all, so a
    /// tiny compressed "decompression bomb" never gets a full-size bitmap.
    static let maxSourcePixels = 8192 * 8192
    static let allowedTypeIdentifiers: Set<String> = ["public.png", "public.jpeg", "public.heic"]

    enum Rejection: Error, Equatable, CustomStringConvertible {
        case notBase64
        case tooLarge(bytes: Int)
        case unsupportedType(String?)
        case tooManyPixels(width: Int, height: Int)
        case undecodable

        var description: String {
            switch self {
            case .notBase64: return "not valid base64"
            case .tooLarge(let bytes): return "\(bytes) bytes exceeds \(ArtworkImageDecoder.maxEncodedBytes)"
            case .unsupportedType(let type): return "type \(type ?? "unknown") not allowed"
            case .tooManyPixels(let width, let height): return "\(width)x\(height) px exceeds limit"
            case .undecodable: return "image could not be decoded"
            }
        }
    }

    /// Image bytes that passed `validatedArtwork(base64:)`.
    struct ValidatedArtwork: Equatable {
        let data: Data
        let typeIdentifier: String
    }

    /// Decodes the adapter's base64 artwork field and checks size, type and
    /// dimensions without decoding pixels.
    static func validatedArtwork(base64: String) -> Result<ValidatedArtwork, Rejection> {
        assert(!Thread.isMainThread, "artwork decoding must stay off the main thread")
        // Reject on the encoded length first so an oversized field is never
        // materialised a second time as Data.
        let encodedLimit = (maxEncodedBytes + 2) / 3 * 4
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= encodedLimit else {
            return .failure(.tooLarge(bytes: trimmed.utf8.count / 4 * 3))
        }
        guard let data = Data(base64Encoded: trimmed) else { return .failure(.notBase64) }
        return validated(data).map { ValidatedArtwork(data: data, typeIdentifier: $0) }
    }

    /// Checks the encoded size, the sniffed type and the source dimensions.
    /// Returns the type identifier on success.
    static func validated(_ data: Data) -> Result<String, Rejection> {
        guard data.count <= maxEncodedBytes else { return .failure(.tooLarge(bytes: data.count)) }
        return source(for: data).map(\.typeIdentifier)
    }

    /// Decodes `data` into a bounded thumbnail, or nil when it is rejected.
    /// Used for artwork from every source (Now Playing and the AppleScript
    /// fallback), which is why the type and pixel checks are repeated here.
    static func thumbnail(from data: Data, maxPixelSize: Int = maxPixelSize) -> Result<CGImage, Rejection> {
        assert(!Thread.isMainThread, "artwork decoding must stay off the main thread")
        switch source(for: data) {
        case .failure(let rejection):
            return .failure(rejection)
        case .success(let checked):
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(checked.source, 0, options as CFDictionary) else {
                return .failure(.undecodable)
            }
            return .success(image)
        }
    }

    private struct CheckedSource {
        let source: CGImageSource
        let typeIdentifier: String
    }

    private static func source(for data: Data) -> Result<CheckedSource, Rejection> {
        let noCache = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, noCache) else {
            return .failure(.unsupportedType(nil))
        }
        let type = CGImageSourceGetType(source) as String?
        guard let type, allowedTypeIdentifiers.contains(type) else {
            return .failure(.unsupportedType(type))
        }
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, noCache) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else {
            return .failure(.undecodable)
        }
        // Division instead of width * height: no overflow on absurd headers.
        guard width <= maxSourcePixels / height else {
            return .failure(.tooManyPixels(width: width, height: height))
        }
        return .success(CheckedSource(source: source, typeIdentifier: type))
    }
}
