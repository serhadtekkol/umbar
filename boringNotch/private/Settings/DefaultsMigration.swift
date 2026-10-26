//
//  DefaultsMigration.swift
//  boringNotch
//
//  Keeps an existing install's settings when a fresh-install default changes
//  (K13 HUD on, #93 shelf auto-remove). Foundation only, so umbarTests can
//  compile it without the Defaults package.
//

import Foundation

enum DefaultsMigration {
    /// One changed default: from `version` on, fresh installs get the new
    /// default; installs older than `version` keep `previousDefault`.
    struct Change {
        let version: Int
        let key: String
        let previousDefault: Bool
    }

    /// Append a change with the next version number; never edit a shipped row.
    static let changes: [Change] = [
        Change(version: 1, key: "hudReplacement", previousDefault: false),
        Change(version: 1, key: "autoRemoveShelfItems", previousDefault: false),
    ]

    static let versionKey = "defaultsVersion"
    static var currentVersion: Int { changes.map(\.version).max() ?? 0 }

    /// Keys AppKit and other system frameworks write into an app's domain on
    /// their own. Their presence says nothing about umbar having run before.
    private static let systemKeyPrefixes = ["NS", "Apple", "com.apple."]

    /// Whether the domain shows that umbar ran here before. Has to be read
    /// before umbar writes its first key of this launch.
    static func isExistingInstall(storedKeys: some Sequence<String>) -> Bool {
        storedKeys.contains { key in
            key != versionKey && !systemKeyPrefixes.contains { key.hasPrefix($0) }
        }
    }

    /// The values to write for a domain holding `stored`. Empty once the
    /// domain is at `currentVersion`.
    static func writes(for stored: [String: Any]) -> [String: Any] {
        let storedVersion = stored[versionKey] as? Int ?? 0
        guard storedVersion < currentVersion else { return [:] }

        var result: [String: Any] = [versionKey: currentVersion]
        // A domain without a version but with umbar keys predates versioning;
        // one without either is a fresh install and keeps every new default.
        guard storedVersion > 0 || isExistingInstall(storedKeys: stored.keys) else {
            return result
        }
        // An install that never touched a changed key was running with its
        // old default, so that value is written explicitly and survives.
        for change in changes where change.version > storedVersion && stored[change.key] == nil {
            result[change.key] = change.previousDefault
        }
        return result
    }

    /// Runs once at launch, before anything else touches the defaults.
    static func apply(to defaults: UserDefaults = .standard, bundleID: String? = Bundle.main.bundleIdentifier) {
        guard let bundleID else { return }
        let stored = defaults.persistentDomain(forName: bundleID) ?? [:]
        for (key, value) in writes(for: stored) {
            defaults.set(value, forKey: key)
        }
    }
}
