//
//  EyeBreakDefaults.swift
//  boringNotch
//
//  Defaults keys for the 20-20-20 eye-break reminder (F14).
//  Kept out of Constants.swift on purpose to avoid merge conflicts.
//

import Defaults
import Foundation

/// Where the reminder is shown (AC-14.1).
enum EyeBreakDelivery: String, CaseIterable, Identifiable, Defaults.Serializable {
    /// In the notch. Needs no permission.
    case panel = "Panel"
    /// System notification. Falls back to the panel if permission is denied (AC-14.7).
    case notification = "Notification"

    var id: String { rawValue }
}

extension Defaults.Keys {
    /// On for fresh installs (K17, 2026-10-26); existing installs keep the
    /// value they ran with (DefaultsMigration). Switchable in Settings (AC-1.13).
    static let eyeBreakEnabled = Key<Bool>("eyeBreakEnabled", default: true)
    static let eyeBreakDelivery = Key<EyeBreakDelivery>("eyeBreakDelivery", default: .panel)
    /// Minutes of active use between reminders (BR-14.1, default 20).
    static let eyeBreakIntervalMinutes = Key<Int>("eyeBreakIntervalMinutes", default: 20)
    /// Length of the look-away countdown in seconds (default 20).
    static let eyeBreakDurationSeconds = Key<Int>("eyeBreakDurationSeconds", default: 20)
    /// Minutes of keyboard/mouse inactivity that count as a break (AC-14.4, default 5).
    static let eyeBreakIdleResetMinutes = Key<Int>("eyeBreakIdleResetMinutes", default: 5)
    /// AC-14.5: hold the reminder while a full-screen video / presentation is active.
    static let eyeBreakDeferDuringVideo = Key<Bool>("eyeBreakDeferDuringVideo", default: true)
    /// Set once the first reminder (which introduces the feature) has ended.
    static let eyeBreakIntroShown = Key<Bool>("eyeBreakIntroShown", default: false)

    // Debug overrides for verification only. 0 = unused. Not exposed in Settings;
    // set with `defaults write <bundle id> eyeBreakDebugIntervalSeconds -int 30`.
    static let eyeBreakDebugIntervalSeconds = Key<Int>("eyeBreakDebugIntervalSeconds", default: 0)
    static let eyeBreakDebugIdleResetSeconds = Key<Int>("eyeBreakDebugIdleResetSeconds", default: 0)
}
