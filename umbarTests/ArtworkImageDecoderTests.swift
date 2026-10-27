//
//  ArtworkImageDecoderTests.swift
//  umbarTests
//
//  Card #70: untrusted Now Playing artwork reaches ImageIO only as PNG, JPEG
//  or HEIC, within a byte and pixel budget, and is decoded as a bounded
//  thumbnail. Ported from the media-hardening scratch harness (h70).
//
//  The decoder asserts it runs off the main thread, so every call goes
//  through `offMain`.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

private typealias Decoder = ArtworkImageDecoder

private func offMain<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await Task.detached { body() }.value
}

/// Encodes a solid-colour image of the given size and type.
private func encodedImage(width: Int, height: Int, type: UTType) throws -> Data {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return output as Data
}

/// A black 1-bit grayscale PNG of `width` x `height`, built by hand.
///
/// This is the shape of a decompression bomb: a 9000x9000 image is ~10 KB
/// on disk but would be a 324 MB RGBA bitmap once decoded. Building it from
/// zero rows needs ~10 MB of scratch and never allocates the bitmap, unlike
/// drawing it through CGContext. (Patching the IHDR of a small PNG is not
/// enough: ImageIO reports no dimensions when IDAT is too short for them.)
private func oneBitPNG(width: UInt32, height: UInt32) throws -> Data {
    let rowBytes = 1 + (Int(width) + 7) / 8          // filter byte + packed pixels
    let raw = Data(count: rowBytes * Int(height))     // filter 0, all pixels 0
    let deflated = try (raw as NSData).compressed(using: .zlib) as Data

    // NSData's .zlib is raw DEFLATE (RFC 1951); PNG wants the zlib wrapper
    // (RFC 1950): a 2-byte header and an Adler-32 trailer.
    var zlibStream = Data([0x78, 0x9C])
    zlibStream.append(deflated)
    zlibStream.append(bigEndian: adler32(raw))

    var ihdr = Data()
    ihdr.append(bigEndian: width)
    ihdr.append(bigEndian: height)
    ihdr.append(contentsOf: [1, 0, 0, 0, 0])          // depth 1, grayscale, deflate, no filter/interlace

    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    png.appendChunk("IHDR", ihdr)
    png.appendChunk("IDAT", zlibStream)
    png.appendChunk("IEND", Data())
    return png
}

private extension Data {
    mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendChunk(_ type: String, _ body: Data) {
        let typeAndBody = Data(type.utf8) + body
        append(bigEndian: UInt32(body.count))
        append(typeAndBody)
        append(bigEndian: crc32(typeAndBody))
    }
}

/// CRC-32 (ISO 3309), as PNG chunks use it.
private func crc32(_ bytes: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
    }
    return ~crc
}

/// Adler-32 (RFC 1950).
private func adler32(_ bytes: Data) -> UInt32 {
    var a: UInt32 = 1, b: UInt32 = 0
    bytes.withUnsafeBytes { buffer in
        for byte in buffer {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
    }
    return b << 16 | a
}

private func isUnsupportedType<T>(_ result: Result<T, Decoder.Rejection>) -> Bool {
    if case .failure(.unsupportedType) = result { return true }
    return false
}

@Suite("ArtworkImageDecoder", .timeLimit(.minutes(1)))
struct ArtworkImageDecoderTests {
    @Test(arguments: [UTType.png, .jpeg, .heic])
    func allowedTypesAreAcceptedWithTheirBytesUnchanged(_ type: UTType) async throws {
        let data = try encodedImage(width: 64, height: 48, type: type)
        let base64 = data.base64EncodedString()
        let result = await offMain { Decoder.validatedArtwork(base64: base64) }
        #expect(result == .success(.init(data: data, typeIdentifier: type.identifier)))
    }

    @Test(arguments: [UTType.gif, .tiff, .bmp])
    func otherImageTypesAreRejected(_ type: UTType) async throws {
        let data = try encodedImage(width: 8, height: 8, type: type)
        let base64 = data.base64EncodedString()
        let validated = await offMain { Decoder.validatedArtwork(base64: base64) }
        #expect(isUnsupportedType(validated))
        let thumbnailRejected = await offMain { isUnsupportedType(Decoder.thumbnail(from: data)) }
        #expect(thumbnailRejected, "the thumbnail path repeats the type check for AppleScript artwork")
    }

    @Test func textPretendingToBeAnImageIsRejected() async {
        let svg = Data("<svg xmlns='http://www.w3.org/2000/svg'/>".utf8).base64EncodedString()
        #expect(isUnsupportedType(await offMain { Decoder.validatedArtwork(base64: svg) }))
    }

    @Test func invalidBase64IsRejected() async {
        #expect(await offMain { Decoder.validatedArtwork(base64: "!!!not base64!!!") } == .failure(.notBase64))
    }

    /// The size cap is inclusive: exactly `maxEncodedBytes` passes the size
    /// check (and then fails on type, being 0xFF filler); one more byte is
    /// rejected as too large without being sniffed.
    @Test func encodedSizeCapIsInclusive() async {
        let atLimit = Data(repeating: 0xFF, count: Decoder.maxEncodedBytes)
        let overLimit = Data(repeating: 0xFF, count: Decoder.maxEncodedBytes + 1)
        #expect(isUnsupportedType(await offMain { Decoder.validated(atLimit) }))
        #expect(await offMain { Decoder.validated(overLimit) } == .failure(.tooLarge(bytes: Decoder.maxEncodedBytes + 1)))
    }

    @Test func oversizedBase64IsRejectedBeforeDecoding() async {
        let base64 = Data(repeating: 0xFF, count: Decoder.maxEncodedBytes + 1).base64EncodedString()
        let result = await offMain { Decoder.validatedArtwork(base64: base64) }
        guard case .failure(.tooLarge) = result else {
            Issue.record("expected tooLarge, got \(result)")
            return
        }
    }

    @Test func pixelBombIsRejectedFromItsHeader() async throws {
        let bomb = try oneBitPNG(width: 9000, height: 9000)
        #expect(bomb.count < 64 * 1024, "a small file that decodes to 81 Mpx")
        #expect(await offMain { Decoder.validated(bomb) } == .failure(.tooManyPixels(width: 9000, height: 9000)))
        let thumbnail = await offMain { Decoder.thumbnail(from: bomb).map { _ in true } }
        #expect(thumbnail == .failure(.tooManyPixels(width: 9000, height: 9000)))
    }

    /// `maxSourcePixels` is 8192 x 8192: exactly that passes, one column more does not.
    @Test func pixelCapIsInclusive() async throws {
        let atCap = try oneBitPNG(width: 8192, height: 8192)
        let overCap = try oneBitPNG(width: 8193, height: 8192)
        #expect(await offMain { Decoder.validated(atCap) } == .success(UTType.png.identifier))
        #expect(await offMain { Decoder.validated(overCap) } == .failure(.tooManyPixels(width: 8193, height: 8192)))
    }

    @Test func thumbnailIsBoundedOnTheLongSide() async throws {
        let data = try encodedImage(width: 2048, height: 1536, type: .jpeg)
        let size = await offMain { () -> [Int]? in
            guard case .success(let image) = Decoder.thumbnail(from: data) else { return nil }
            return [image.width, image.height]
        }
        #expect(size == [Decoder.maxPixelSize, 768])
    }
}
