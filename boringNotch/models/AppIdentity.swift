//
//  AppIdentity.swift
//  boringNotch
//

import Foundation

/// Names and locations derived from the host app's bundle identifier.
///
/// The project derives every bundle ID from one build setting
/// (`UMBAR_BUNDLE_ID_ROOT`, card #40): host = root, helper = root +
/// ".XPCHelper". Deriving the dependent names at runtime keeps them from
/// drifting apart if the root changes again. These are pure functions of the
/// identifier so the rules can be unit-tested without a running app.
enum AppIdentity {
    /// The embedded XPC helper's service name, which launchd takes from the
    /// helper's bundle identifier.
    static func helperServiceName(hostBundleID: String) -> String {
        "\(hostBundleID).XPCHelper"
    }

    /// Where the shelf keeps `items.json`.
    ///
    /// Keyed by our bundle id, not a fixed folder name: the app is
    /// unsandboxed, so a literal "boringNotch" folder would be the very same
    /// items.json (and security-scoped bookmarks) that upstream Boring Notch
    /// reads when both are installed (card #40).
    ///
    /// - Parameters:
    ///   - base: The user's Application Support directory (or a fallback).
    ///   - hostBundleID: The host app's bundle identifier.
    static func shelfDirectory(in base: URL, hostBundleID: String) -> URL {
        base
            .appendingPathComponent(hostBundleID, isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
    }
}
