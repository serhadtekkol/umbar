//
//  AdapterLineBufferTests.swift
//  umbarTests
//
//  Card #70: the adapter's stdout is split into lines with a hard memory
//  bound. Ported from the media-hardening scratch harness (h70).
//

import Foundation
import Testing

private func bytes(_ string: String) -> Data { Data(string.utf8) }

@Suite("AdapterLineBuffer", .timeLimit(.minutes(1)))
struct AdapterLineBufferTests {
    @Test func defaultLimitIsEightMegabytes() {
        #expect(AdapterLineBuffer.defaultLimit == 8 * 1024 * 1024)
        #expect(AdapterLineBuffer().limit == AdapterLineBuffer.defaultLimit)
    }

    @Test func splitsLinesAcrossChunksAndSkipsEmptyOnes() {
        var buffer = AdapterLineBuffer(limit: 10)
        #expect(buffer.append(bytes("ab")).isEmpty, "a partial line is held")
        #expect(buffer.append(bytes("c\nde\n\nf")) == [bytes("abc"), bytes("de")])
        #expect(buffer.pendingCount == 1, "the unterminated tail is kept")
        #expect(buffer.append(bytes("\n")) == [bytes("f")])
        #expect(buffer.pendingCount == 0)
    }

    @Test func manyShortLinesInOneChunk() {
        var buffer = AdapterLineBuffer()
        let lines = buffer.append(bytes(String(repeating: "x\n", count: 1000)))
        #expect(lines.count == 1000)
        #expect(lines.allSatisfy { $0 == bytes("x") })
    }

    @Test func exactlyAtTheLimitIsKeptAndDelivered() {
        var buffer = AdapterLineBuffer(limit: 10)
        #expect(buffer.append(bytes("0123456789")).isEmpty)
        #expect(!buffer.hasOverflowed)
        #expect(buffer.append(bytes("\n")) == [bytes("0123456789")])
    }

    @Test func oneByteOverTheLimitDropsAndLatches() {
        var buffer = AdapterLineBuffer(limit: 10)
        #expect(buffer.append(bytes("01234567890")).isEmpty)
        #expect(buffer.hasOverflowed)
        #expect(buffer.pendingCount == 0, "the oversized tail is released")
        #expect(buffer.append(bytes("x\nvalid\n")).isEmpty, "later lines are discarded: the stream is no longer line-aligned")
    }

    /// An over-limit tail that arrives together with a newline is still an
    /// overflow once the newline has been consumed.
    @Test func overflowAfterACompletedLineStillLatches() {
        var buffer = AdapterLineBuffer(limit: 4)
        #expect(buffer.append(bytes("ok\n123456")) == [bytes("ok")])
        #expect(buffer.hasOverflowed)
        #expect(buffer.pendingCount == 0)
    }

    /// The h70 scenario at the real limit: a child writes 20 MB without a
    /// newline. The buffer must never hold more than `defaultLimit`.
    @Test func twentyMegabytesWithoutNewlineStayBounded() {
        var buffer = AdapterLineBuffer()
        let chunk = Data(repeating: UInt8(ascii: "A"), count: 64 * 1024)
        var peak = 0
        for _ in 0..<320 {
            #expect(buffer.append(chunk).isEmpty)
            peak = max(peak, buffer.pendingCount)
        }
        #expect(buffer.hasOverflowed)
        #expect(peak <= AdapterLineBuffer.defaultLimit)
    }
}
