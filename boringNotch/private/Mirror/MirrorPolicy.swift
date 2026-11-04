//
//  MirrorPolicy.swift
//  boringNotch
//
//  The mirror's pure part: when the camera may run, what the page shows,
//  and when umbar may ask macOS for camera access. No AVFoundation here,
//  so umbarTests compiles this file hostless (membershipExceptions).
//
//  The rules, in order of how much they matter:
//    1. Off by default. Nothing about the camera is touched until the user
//       turns the mirror on in Settings.
//    2. Access is asked for only by a user action: turning the setting on,
//       or tapping the preview while macOS has never been asked. Never at
//       launch, never from onboarding, never just by opening the tab.
//    3. The camera runs while the Ayna tab is in front, and only then.
//       Picking the tab is the user action that starts it (it replaced
//       "tap to start" when the mirror moved off Şimdi: the tab exists
//       only to show the camera, and a panel never opens on Ayna by
//       itself, `BoringViewModel.close` sends it back to Şimdi). Leaving the tab, closing the panel, locking, sleeping, the
//       screen saver or switching user stops it. A tap on the live preview
//       stops it too, and it stays off until the tab is shown again.
//    4. A preview runs at most `maxRunDuration`. A panel opened from the
//       keyboard stays open without the pointer, and leaving the desk
//       unlocked with display sleep held off says nothing; the cap bounds
//       how long the camera, and the camera-dot mask, can stay on.
//

import Foundation

/// The camera permission as the mirror needs it. `restricted` (MDM,
/// parental controls) behaves like `denied`: the user cannot grant it
/// from umbar, only from System Settings or not at all.
enum MirrorAccess: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

/// Everything outside the mirror that decides whether it may run.
struct MirrorConditions: Equatable, Sendable {
    /// Settings > General > Mirror (`Defaults[.mirrorEnabled]`).
    var enabled: Bool
    var access: MirrorAccess
    /// At least one video device is connected.
    var cameraAvailable: Bool
    /// Some screen's panel is open on the Ayna tab (the "tile" is the
    /// page's preview).
    var tileVisible: Bool
    /// Not asleep, locked or switched away (`CritterSystemState.userAway`).
    var userPresent: Bool

    /// The tile is in front of the user, so a preview could be looked at.
    var tileInFront: Bool { enabled && tileVisible && userPresent }
}

/// What the camera controller has to do after a policy step.
enum MirrorCommand: Equatable, Sendable {
    case start
    case stop
    case requestAccess
    case openPrivacySettings
}

/// What the preview draws.
enum MirrorTileState: Equatable, Sendable {
    /// Ready; a tap starts the preview.
    case idle
    case live
    /// macOS has not been asked yet; a tap asks.
    case needsAccess
    /// Denied or restricted; a tap opens System Settings.
    case denied
    /// No camera connected.
    case unavailable
}

extension MirrorTileState {
    /// The tile draws the camera picture. While it does, the notch window
    /// is kept out of screen shares and recordings (`CapturePrivacy`):
    /// otherwise an app with Screen Recording access but no camera access
    /// could read the camera through the mirror (Muhittin M2).
    var showsCameraPicture: Bool { self == .live }
}

/// The start/stop state machine. The controller owns one on the main
/// actor, feeds it every change of `MirrorConditions` and every tap, and
/// carries out the command it returns. It never starts or stops the
/// hardware on its own, so its view of `running` is the controller's.
struct MirrorSession: Equatable, Sendable {
    /// Turned off during this showing of the tab: by a tap, the run cap,
    /// or the capture ending on its own. Cleared when the tab leaves, so
    /// the next showing starts the camera again.
    private(set) var held = false
    /// The controller was told to start and not yet to stop.
    private(set) var running = false
    /// Bumped on every `.start`, so the cap timer of an earlier preview
    /// cannot stop a later one.
    private(set) var generation: UInt64 = 0

    /// Rule 4. Long enough to fix your hair before a call, short enough
    /// that a forgotten preview does not run for the afternoon.
    static let maxRunDuration: TimeInterval = 5 * 60

    /// Re-evaluates after any condition changed. Returns `.start` or
    /// `.stop` when the hardware has to follow, nil when it already does.
    mutating func update(_ conditions: MirrorConditions) -> MirrorCommand? {
        // Rule 3: a stop lasts one showing of the tab.
        if !conditions.tileInFront { held = false }
        let desired = !held && conditions.tileInFront
            && conditions.access == .granted && conditions.cameraAvailable
        guard desired != running else { return nil }
        running = desired
        if desired { generation &+= 1 }
        return desired ? .start : .stop
    }

    /// The cap timer for preview `generation` fired. Stops it when it is
    /// still the one running; a tap, or showing the tab again, starts a
    /// fresh preview.
    mutating func runTimeElapsed(generation: UInt64) -> MirrorCommand? {
        guard running, generation == self.generation else { return nil }
        sessionEnded()
        return .stop
    }

    /// The user tapped the preview.
    mutating func tap(_ conditions: MirrorConditions) -> MirrorCommand? {
        guard conditions.tileInFront else { return nil }
        if running {
            held = true
            return update(conditions)
        }
        switch conditions.access {
        case .denied:
            return .openPrivacySettings
        case .notDetermined:
            // Started by `update` once the answer comes back granted, if
            // the tab is still in front by then.
            held = false
            return .requestAccess
        case .granted:
            guard conditions.cameraAvailable else { return nil }
            held = false
            return update(conditions)
        }
    }

    /// The capture stopped without being told to (the camera was unplugged,
    /// a runtime error) or by the run cap. The page goes back to idle
    /// rather than retrying while it stays in front.
    mutating func sessionEnded() {
        running = false
        held = true
    }

    func tileState(_ conditions: MirrorConditions) -> MirrorTileState {
        if running { return .live }
        switch conditions.access {
        case .denied: return .denied
        case .notDetermined: return .needsAccess
        case .granted: return conditions.cameraAvailable ? .idle : .unavailable
        }
    }
}

/// Why a preview started or stopped, for the log: "why was the camera on?"
/// has to be answerable afterwards (Muhittin, detection gap). Event names
/// only; no device, no user data.
enum MirrorRunReason: String, Sendable {
    /// The user tapped the preview (start or stop).
    case tap
    /// The Ayna tab came to the front.
    case tabShown
    /// macOS answered the prompt with "allow" while the tab waited.
    case accessGranted
    /// The panel closed or another tab was picked.
    case hidden
    /// Locked, asleep, screen saver or switched user.
    case away
    /// The setting was turned off.
    case disabled
    /// Access was revoked in System Settings.
    case denied
    /// The camera in use was disconnected.
    case unplug
    /// `MirrorSession.maxRunDuration` passed.
    case timeLimit
    /// AVCaptureSession reported a runtime error.
    case error
    /// The camera could not be opened.
    case startFailed

    /// Why `MirrorSession.update` returned `.start`. A tap's start is
    /// logged by the tap path itself as `.tap`.
    static func start(afterAccessAnswer: Bool) -> MirrorRunReason {
        afterAccessAnswer ? .accessGranted : .tabShown
    }

    /// Why `MirrorSession.update` returned `.stop` under `conditions`. The
    /// first condition that fails names it, most global first.
    static func stop(after conditions: MirrorConditions) -> MirrorRunReason {
        if !conditions.enabled { return .disabled }
        if !conditions.userPresent { return .away }
        if !conditions.tileVisible { return .hidden }
        if conditions.access != .granted { return .denied }
        if !conditions.cameraAvailable { return .unplug }
        return .tap
    }
}

/// Which screens' panels show the tile right now, keyed by their view
/// model. The tile reports itself from onAppear/onDisappear, but a window
/// closed because its display was unplugged may never get onDisappear; the
/// app delegate then says the owner is gone (Muhittin L3), or the camera
/// would keep running for a panel nobody can see.
struct MirrorTileOwners: Equatable, Sendable {
    private var visible: Set<ObjectIdentifier> = []

    var anyVisible: Bool { !visible.isEmpty }

    /// Returns whether anything changed.
    mutating func set(_ isVisible: Bool, for owner: ObjectIdentifier) -> Bool {
        isVisible ? visible.insert(owner).inserted : visible.remove(owner) != nil
    }

    /// The owner's window was closed. Returns whether anything changed.
    mutating func remove(_ owner: ObjectIdentifier) -> Bool {
        set(false, for: owner)
    }
}

enum MirrorTabPolicy {
    /// Whether a closing panel keeps its page for the next opening ("open
    /// last tab"). Never Ayna: opening the tab starts the camera, so a
    /// hover must not reopen on it (rule 3).
    static func keepsPageAcrossClose(isMirror: Bool, openLastTab: Bool) -> Bool {
        openLastTab && !isMirror
    }
}

enum MirrorAccessPolicy {
    /// Whether turning the setting from `wasEnabled` to `isEnabled` should
    /// show the macOS camera prompt. Only the user's own off-to-on flip
    /// does, and only while macOS has never been asked: a setting that is
    /// already on at launch never prompts (rule 2).
    static func requestsOnEnable(wasEnabled: Bool, isEnabled: Bool, access: MirrorAccess) -> Bool {
        !wasEnabled && isEnabled && access == .notDetermined
    }
}
