//
//  ScreenshotShelfDefaults.swift
//  umbar
//
//  Defaults keys for F16 (screenshots go to the shelf).
//

import Defaults

extension Defaults.Keys {
    /// New screenshots appear on the shelf. On by default: the user asked
    /// for it, and the file itself is never moved or copied.
    static let screenshotShelfEnabled = Key<Bool>("screenshotShelfEnabled", default: true)
    /// Also shelve screen recordings (.mov).
    static let screenshotShelfIncludeRecordings = Key<Bool>("screenshotShelfIncludeRecordings", default: false)
    /// Folder to watch instead of the system screenshot location. Empty means
    /// "follow macOS". Not shown in Settings; used for QA and advanced setups.
    static let screenshotShelfWatchPath = Key<String>("screenshotShelfWatchPath", default: "")
}
