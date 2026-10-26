//
//  ClipboardDefaults.swift
//  umbar
//
//  Kept out of Constants.swift on purpose: F4 is a separate feature with
//  its own lifecycle, and Constants.swift is shared by every branch.
//

import Defaults

extension Defaults.Keys {
    /// Spike A2 (card #3) prototype switch for the clipboard monitor.
    /// Off by default and deliberately not surfaced in Settings yet; the
    /// real F4 toggle (AC-1.13) replaces it in #16/#17. Toggle manually with
    /// `defaults write <bundle id> clipboardMonitorEnabled -bool YES`.
    static let clipboardMonitorEnabled = Key<Bool>("clipboardMonitorEnabled", default: false)
}
