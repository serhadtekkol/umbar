//
//  ArtworkSimilarityTests.swift
//  umbarTests
//

import CoreGraphics
import Testing

@Suite("ArtworkSimilarity", .timeLimit(.minutes(1)))
struct ArtworkSimilarityTests {
    private func image(size: Int, draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx)
        return ctx.makeImage()!
    }

    private func logo(_ size: Int) -> CGImage {
        image(size: size) { ctx in
            let s = CGFloat(size)
            ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8))
            ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: s * 0.35, y: s * 0.35, width: s * 0.3, height: s * 0.3))
        }
    }

    @Test func sameLogoAtDifferentSizesMatches() {
        #expect(ArtworkSimilarity.looksAlike(logo(256), logo(120)))
    }

    @Test func albumCoverDoesNotMatchLogo() {
        let cover = image(size: 120) { ctx in
            ctx.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 120))
        }
        #expect(!ArtworkSimilarity.looksAlike(cover, logo(256)))
    }
}
