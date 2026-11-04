//
//  ArtworkSimilarity.swift
//  boringNotch
//
//  Tells whether two images are the same picture, coarsely: both are drawn
//  into a tiny RGBA grid over black and compared channel by channel. Used to
//  spot a browser publishing its own app icon as Now Playing artwork.
//

import CoreGraphics

enum ArtworkSimilarity {
    static let gridSize = 12
    /// Mean absolute channel difference (0…1) under which two images match.
    static let threshold = 0.07

    static func looksAlike(_ a: CGImage, _ b: CGImage) -> Bool {
        guard let pa = grid(a), let pb = grid(b) else { return false }
        var sum = 0.0
        for i in 0..<pa.count { sum += abs(Double(pa[i]) - Double(pb[i])) }
        return sum / Double(pa.count) / 255 < threshold
    }

    static func grid(_ image: CGImage) -> [UInt8]? {
        let n = gridSize
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        return ok ? px : nil
    }
}
