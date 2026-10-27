//
//  TimeMachineParsing.swift
//  boringNotch
//
//  F19 live activities: reads /Library/Preferences/com.apple.TimeMachine.plist
//  (world-readable, no permission) for "is Time Machine set up" and "when did
//  the last backup finish".
//
//  Why not live progress: the only public sources of "a backup is running,
//  n % done" are `tmutil status` (a subprocess, ruled out for this app) and
//  backupd's private XPC. The plist only changes when a backup completes,
//  so umbar can say "Yedekleme bitti", not show a progress bar. See the F19
//  hand-off for what was probed on macOS 27.0.1.
//
//  Foundation-only for umbarTests.
//

import Foundation

enum TimeMachinePlistParser {
    static let path = "/Library/Preferences/com.apple.TimeMachine.plist"
    static let destinationsKey = "Destinations"
    static let snapshotDatesKey = "SnapshotDates"

    /// True when at least one backup destination is configured. A Mac that
    /// has never had Time Machine set up has only `PreferencesVersion`
    /// (seen on both test machines, macOS 27.0.1).
    static func hasDestinations(_ plist: [String: Any]) -> Bool {
        !(plist[destinationsKey] as? [[String: Any]] ?? []).isEmpty
    }

    /// The newest completed backup across all destinations, or nil if none
    /// is recorded.
    static func latestBackupDate(_ plist: [String: Any]) -> Date? {
        let destinations = plist[destinationsKey] as? [[String: Any]] ?? []
        return destinations
            .flatMap { $0[snapshotDatesKey] as? [Date] ?? [] }
            .max()
    }

    static func parse(data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Whether a newly read date means a backup just finished. The first read
    /// after launch only sets the baseline, so an old backup is never
    /// announced as new.
    static func didFinishBackup(previous: Date?, current: Date?, isBaseline: Bool) -> Bool {
        guard !isBaseline, let current else { return false }
        guard let previous else { return true }
        return current > previous
    }
}
