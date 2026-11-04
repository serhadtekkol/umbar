//
//  AudioLevelDemand.swift
//  boringNotch
//
//  The bookkeeping half of AudioLevelMonitor's public API: who wants the
//  capture on, and whether a permission request is still outstanding. Pure
//  values, so the hostless umbarTests cover them; the monitor owns one of
//  each on the main actor.
//

import Foundation

/// The set of callers that currently want capture. Capture is wanted while
/// at least one owner holds it, so one screen's glow going away cannot
/// switch off another screen's.
struct AudioLevelOwners {
    private var owners: Set<AnyHashable> = []

    var isActive: Bool { !owners.isEmpty }

    /// Adds `owner`; holding twice with the same owner is one hold.
    mutating func acquire(_ owner: AnyHashable) {
        owners.insert(owner)
    }

    /// Removes `owner`; releasing an owner that holds nothing is a no-op.
    mutating func release(_ owner: AnyHashable) {
        owners.remove(owner)
    }
}

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
