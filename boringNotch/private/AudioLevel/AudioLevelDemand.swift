//
//  AudioLevelDemand.swift
//  boringNotch
//
//  The bookkeeping half of AudioLevelMonitor's public API: whether a
//  permission request is still outstanding. A pure value, so the hostless
//  umbarTests cover it; the monitor owns one on the main actor.
//

import Foundation

/// At most one audio-capture permission request at a time, without the
/// risk of waiting forever.
///
/// TCCAccessRequest is private API; if its completion never fires (a TCC
/// daemon restart, a changed ABI) a plain "in flight" flag would stay set
/// and every later start would return without asking. So a request also
/// ends when the caller stops wanting capture (`cancel`) and when the
/// monitor's `timeout` timer gives up on it (`expire`). Requests carry an
/// ID so that a late answer, or a timer, for an old request cannot end a
/// newer one.
struct AudioPermissionRequestGate {
    /// Long enough for a user to read and answer the system prompt.
    static let timeout: TimeInterval = 60

    private var pending: UInt64?
    private var lastID: UInt64 = 0

    /// Starts a request and returns its ID, or nil while one is
    /// outstanding.
    mutating func begin() -> UInt64? {
        guard pending == nil else { return nil }
        lastID &+= 1
        pending = lastID
        return lastID
    }

    /// Marks request `id` answered.
    mutating func finish(_ id: UInt64) {
        if pending == id { pending = nil }
    }

    /// Gives up on request `id`. Returns true when it was still the
    /// outstanding one, i.e. its answer never came.
    mutating func expire(_ id: UInt64) -> Bool {
        guard pending == id else { return false }
        pending = nil
        return true
    }

    /// Forgets the outstanding request, so the next start asks again.
    mutating func cancel() {
        pending = nil
    }
}
