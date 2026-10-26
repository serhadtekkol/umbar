//
//  EventTap.swift
//  boringNotch
//

import CoreGraphics

/// Helpers for `CGEvent` tap callbacks that do not depend on any tap owner,
/// so they can be unit-tested on their own (card #56).
enum EventTap {
    /// Returns an event to the tap unchanged.
    ///
    /// The tap callback receives the event at +0 and the system takes the
    /// returned reference without consuming a retain, so it must go back
    /// unretained. Upstream used `passRetained`, which leaked one CGEvent per
    /// passed-through system-defined event (card #45).
    static func passThrough(_ cgEvent: CGEvent) -> Unmanaged<CGEvent> {
        Unmanaged.passUnretained(cgEvent)
    }
}
