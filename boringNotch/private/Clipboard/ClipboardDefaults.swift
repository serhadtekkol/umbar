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
    /// Off by default (the user's decision after the security review): a
    /// clipboard history keeps what people copy on disk, so it is opt-in,
    /// from Settings or the Pano side's "Turn on" button. Defaults stores
    /// only explicit choices, so someone who already turned it on keeps it.
    static let clipboardHistoryEnabled = Key<Bool>("clipboardHistoryEnabled", default: false)
    /// How many copies to keep; one of `ClipboardHistoryPolicy.limitChoices`.
    static let clipboardHistoryLimit = Key<Int>("clipboardHistoryLimit", default: ClipboardHistoryPolicy.defaultLimit)
    /// BR-4.4: days a copy is kept; one of
    /// `ClipboardHistoryPolicy.retentionChoices`, 0 for unlimited.
    static let clipboardHistoryRetentionDays = Key<Int>("clipboardHistoryRetentionDays", default: ClipboardHistoryPolicy.defaultRetentionDays)
    /// AC-4.5: bundle IDs of apps whose copies are never recorded, on top
    /// of `ClipboardMonitor.passwordManagerBundleIDs`. Managed in Settings.
    static let clipboardExcludedBundleIDs = Key<[String]>("clipboardExcludedBundleIDs", default: [])
    /// Which side of the Raf page was last shown, so reopening the panel
    /// comes back to it. Not a setting; not shown in Settings.
    static let shelfPageSection = Key<ShelfPageSection>("shelfPageSection", default: .files)
}

/// The two sides of the Raf page.
enum ShelfPageSection: String, Defaults.Serializable, CaseIterable {
    case files
    case clipboard
}
