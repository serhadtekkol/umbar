//
//  MirrorPolicy.swift
//  boringNotch
//
//  The mirror's pure part: when the camera may run, what the tile shows,
//  and when umbar may ask macOS for camera access. No AVFoundation here,
//  so umbarTests compiles this file hostless (membershipExceptions).
//
//  The rules, in order of how much they matter:
//    1. Off by default. Nothing about the camera is touched until the user
//       turns the mirror on in Settings.
//    2. Access is asked for only by a user action: turning the setting on,
//       or tapping the tile while macOS has never been asked. Never at
//       launch, never from onboarding.
//    3. The camera runs only while the user asked for it on this opening
//       of the panel *and* the tile is on screen. Closing the panel,
//       leaving Şimdi, locking, sleeping or switching user stops it, and
//       forgets the request: the next opening shows the idle tile again,
//       so hovering the notch never lights the camera by itself.
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
    /// Some screen's panel is open on Şimdi with the tile in it.
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

/// What the tile draws.
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
    /// The user tapped for a preview during this showing of the tile.
    private(set) var wanted = false
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
        // Rule 3: the wish lasts one showing of the tile.
        if !conditions.tileInFront { wanted = false }
        let desired = wanted && conditions.tileInFront
            && conditions.access == .granted && conditions.cameraAvailable
        guard desired != running else { return nil }
        running = desired
        if desired { generation &+= 1 }
        return desired ? .start : .stop
    }

    /// The cap timer for preview `generation` fired. Stops it when it is
    /// still the one running; a tap starts a fresh preview.
    mutating func runTimeElapsed(generation: UInt64) -> MirrorCommand? {
        guard running, generation == self.generation else { return nil }
        sessionEnded()
        return .stop
    }

    /// The user tapped the tile.
    mutating func tap(_ conditions: MirrorConditions) -> MirrorCommand? {
        guard conditions.tileInFront else { return nil }
        if running {
            wanted = false
            return update(conditions)
        }
        switch conditions.access {
        case .denied:
            return .openPrivacySettings
        case .notDetermined:
            // Started by `update` once the answer comes back granted, if
            // the tile is still in front by then.
            wanted = true
            return .requestAccess
        case .granted:
            guard conditions.cameraAvailable else { return nil }
            wanted = true
            return update(conditions)
        }
    }

    /// The capture stopped without being told to (the camera was unplugged,
    /// a runtime error). The tile goes back to idle rather than retrying.
    mutating func sessionEnded() {
        running = false
        wanted = false
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

enum MirrorAccessPolicy {
    /// Whether turning the setting from `wasEnabled` to `isEnabled` should
    /// show the macOS camera prompt. Only the user's own off-to-on flip
    /// does, and only while macOS has never been asked: a setting that is
    /// already on at launch never prompts (rule 2).
    static func requestsOnEnable(wasEnabled: Bool, isEnabled: Bool, access: MirrorAccess) -> Bool {
        !wasEnabled && isEnabled && access == .notDetermined
    }
}
