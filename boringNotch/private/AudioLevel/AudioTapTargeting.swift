//
//  AudioTapTargeting.swift
//  boringNotch
//
//  Which Core Audio process objects belong to the now-playing app, so the
//  tap hears that app and nothing else (no notification sounds, no call in
//  another app). Pure, so the hostless umbarTests cover it.
//

import Foundation

enum AudioTapTargeting {
    /// One entry of the HAL's process object list.
    struct Candidate: Equatable, Sendable {
        var objectID: UInt32
        var bundleID: String?
        var isRunningOutput: Bool
    }

    /// What the tap should listen to.
    enum Target: Equatable, Sendable {
        /// Only these process objects (stereo mixdown of their output).
        case processes([UInt32])
        /// Everything the system plays, except umbar itself.
        case global
    }

    /// Apps whose audio is played by a process with an unrelated bundle ID.
    /// Safari (and every WKWebView app) renders media in the shared WebKit
    /// GPU process; tapping Safari's own process hears nothing.
    static let audioHosts: [String: [String]] = [
        "com.apple.safari": ["com.apple.webkit.gpu"],
        "com.apple.safaritechnologypreview": ["com.apple.webkit.gpu"],
    ]

    /// True when `process` is the app itself or one of its helpers. Helpers
    /// carry the app's ID plus a suffix ("com.google.Chrome.helper"), and
    /// some apps change case for them ("company.thebrowser.Browser" →
    /// "company.thebrowser.browser.helper"), so the match ignores case.
    static func belongs(process: String, to app: String) -> Bool {
        let process = process.lowercased()
        let app = app.lowercased()
        guard !app.isEmpty else { return false }
        if process == app || process.hasPrefix(app + ".") { return true }
        return audioHosts[app]?.contains(process) ?? false
    }

    /// Chooses the tap target for `nowPlaying`.
    ///
    /// Per-app only when at least one of the app's processes is producing
    /// output right now; those processes, and only those, are tapped. An app
    /// with no outputting process (not found, not yet started, or playing
    /// through a process this table does not know) falls back to `.global`,
    /// so the glow still moves instead of tapping silence.
    static func target(
        nowPlaying: String?,
        candidates: [Candidate],
        ownBundleID: String?
    ) -> Target {
        guard let app = nowPlaying, !app.isEmpty else { return .global }
        let own = ownBundleID?.lowercased()
        let matches = candidates.filter { candidate in
            guard let id = candidate.bundleID, candidate.isRunningOutput else { return false }
            return id.lowercased() != own && belongs(process: id, to: app)
        }
        return matches.isEmpty ? .global : .processes(matches.map(\.objectID).sorted())
    }

    /// Whether a live tap aimed at `current` (built while `currentApp` was
    /// playing) must be replaced by one aimed at `proposed`.
    ///
    /// The process list is re-read every few seconds, and a player's
    /// "running output" flag drops for a moment between tracks. Rebuilding on
    /// every such blip would make the glow stutter, so for the same app a
    /// per-app tap only grows: it is rebuilt when a new process of the app
    /// starts playing, never because one of its processes went quiet or
    /// because the app briefly had none (which proposes `.global`).
    static func shouldRebuild(
        current: Target,
        currentApp: String?,
        proposed: Target,
        app: String?
    ) -> Bool {
        let sameApp = currentApp?.lowercased() == app?.lowercased()
        guard sameApp else { return current != proposed }
        switch (current, proposed) {
        case (.global, .global):
            return false
        case (.global, .processes):
            return true
        case (.processes, .global):
            return false
        case (.processes(let live), .processes(let wanted)):
            return !Set(wanted).isSubset(of: Set(live))
        }
    }
}
