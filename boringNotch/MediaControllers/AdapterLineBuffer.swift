//
//  AdapterLineBuffer.swift
//  boringNotch
//
//  Kept apart from NowPlayingAdapterProcess so the unit test bundle can
//  compile it without the process and AppKit plumbing (card #56).
//

import Foundation

/// Splits the adapter's stdout into lines while bounding memory (card #70).
///
/// Without a bound, a child that never writes `\n` grows the app's memory
/// until it dies. When the unterminated tail exceeds `limit`, the buffer is
/// dropped and the buffer *latches*: every later byte is discarded, because
/// the stream is no longer line-aligned and the owner is expected to end the
/// child. `limit` is far above the largest legitimate line (a few MB of
/// base64 artwork).
///
/// Pure value type; no I/O.
struct AdapterLineBuffer {
    static let defaultLimit = 8 * 1024 * 1024

    let limit: Int
    private(set) var hasOverflowed = false
    private var pending = Data()
    /// Bytes of `pending` already known to contain no newline, so each byte
    /// is scanned once even for a multi-megabyte line.
    private var scannedCount = 0

    init(limit: Int = AdapterLineBuffer.defaultLimit) {
        self.limit = limit
    }

    /// Number of buffered bytes without a newline yet.
    var pendingCount: Int { pending.count }

    /// Appends a chunk and returns the complete, non-empty lines it finished,
    /// without their trailing newline. Returns `[]` once overflowed.
    mutating func append(_ chunk: Data) -> [Data] {
        guard !hasOverflowed else { return [] }
        // A chunk that cannot finish the pending line and would push it past
        // the limit is refused before it is copied, so the buffer itself
        // never holds more than `limit` bytes.
        if pending.count + chunk.count > limit, !chunk.contains(UInt8(ascii: "\n")) {
            overflow()
            return []
        }
        pending.append(chunk)
        var lines: [Data] = []
        var lineStart = pending.startIndex
        var cursor = pending.startIndex + scannedCount
        while let newline = pending[cursor...].firstIndex(of: UInt8(ascii: "\n")) {
            if newline > lineStart {
                lines.append(Data(pending[lineStart..<newline]))
            }
            lineStart = newline + 1
            cursor = lineStart
        }
        pending.removeSubrange(pending.startIndex..<lineStart)
        scannedCount = pending.count
        if pending.count > limit {
            overflow()
        }
        return lines
    }

    private mutating func overflow() {
        hasOverflowed = true
        pending = Data()
        scannedCount = 0
    }
}
