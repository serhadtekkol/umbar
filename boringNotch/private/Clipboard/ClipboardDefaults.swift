//
//  ClipboardDefaults.swift
//  umbar
//
//  Kept out of Constants.swift on purpose: F21 is a separate feature with
//  its own lifecycle, and Constants.swift is shared by every branch.
//

import Defaults

extension Defaults.Keys {
    /// F21: record copies and show them on the Raf page's "Pano" side.
    /// Turning it off stops the monitor and deletes the saved history.
    static let clipboardHistoryEnabled = Key<Bool>("clipboardHistoryEnabled", default: true)
    /// How many copies to keep; one of `ClipboardHistoryPolicy.limitChoices`.
    static let clipboardHistoryLimit = Key<Int>("clipboardHistoryLimit", default: ClipboardHistoryPolicy.defaultLimit)
    /// Which side of the Raf page was last shown, so reopening the panel
    /// comes back to it. Not a setting; not shown in Settings.
    static let shelfPageSection = Key<ShelfPageSection>("shelfPageSection", default: .files)
}

/// The two sides of the Raf page.
enum ShelfPageSection: String, Defaults.Serializable, CaseIterable {
    case files
    case clipboard
}
