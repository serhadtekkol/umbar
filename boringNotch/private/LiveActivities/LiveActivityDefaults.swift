//
//  LiveActivityDefaults.swift
//  boringNotch
//
//  Defaults keys for F19 live activities. Kept out of Constants.swift, like
//  the other private features, to stay clear of merge conflicts.
//

import Defaults
import Foundation

extension Defaults.Keys {
    /// Charging time-to-full. Needs no permission.
    static let liveActivityChargingEnabled = Key<Bool>("liveActivityChargingEnabled", default: true)
    /// Download progress. On, but nothing is read from ~/Downloads until the
    /// user has also granted access (`liveActivityDownloadsAccessRequested`).
    static let liveActivityDownloadsEnabled = Key<Bool>("liveActivityDownloadsEnabled", default: true)
    /// AirDrop receive. Reads the same folder, so the same gate applies.
    static let liveActivityAirDropEnabled = Key<Bool>("liveActivityAirDropEnabled", default: true)
    /// Time Machine "backup finished". Reads a world-readable plist, no permission.
    static let liveActivityTimeMachineEnabled = Key<Bool>("liveActivityTimeMachineEnabled", default: true)

    /// Set when the user presses "Allow access" in Settings. Only then does
    /// umbar open ~/Downloads, so the macOS "access files in your Downloads
    /// folder" prompt appears right after the user asked for the feature and
    /// never at launch.
    static let liveActivityDownloadsAccessRequested = Key<Bool>("liveActivityDownloadsAccessRequested", default: false)

    /// Verification only, not in Settings: watch this folder instead of
    /// ~/Downloads (QA fixtures; no Downloads-folder prompt is involved).
    /// `defaults write <bundle id> liveActivityDebugWatchPath -string /path`
    static let liveActivityDebugWatchPath = Key<String>("liveActivityDebugWatchPath", default: "")
}
