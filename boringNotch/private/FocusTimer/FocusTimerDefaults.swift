//
//  FocusTimerDefaults.swift
//  boringNotch
//
//  Defaults keys for the focus timer (F18). Kept out of Constants.swift to
//  avoid merge conflicts.
//

import Defaults
import Foundation

extension Defaults.Keys {
    static let focusTimerEnabled = Key<Bool>("focusTimerEnabled", default: true)
    /// The "Custom" chip in the header.
    static let focusTimerCustomFocusMinutes = Key<Int>("focusTimerCustomFocusMinutes", default: 40)
    static let focusTimerCustomBreakMinutes = Key<Int>("focusTimerCustomBreakMinutes", default: 8)
    static let focusTimerLongBreakMinutes = Key<Int>("focusTimerLongBreakMinutes", default: 15)
    static let focusTimerSessionsBeforeLongBreak = Key<Int>("focusTimerSessionsBeforeLongBreak", default: 4)

    /// Off by default. macOS has no public API to toggle Focus / Do Not Disturb,
    /// so the user may name Shortcuts shortcuts that do it for them.
    static let focusTimerRunShortcuts = Key<Bool>("focusTimerRunShortcuts", default: false)
    static let focusTimerStartShortcut = Key<String>("focusTimerStartShortcut", default: "")
    static let focusTimerStopShortcut = Key<String>("focusTimerStopShortcut", default: "")

    /// JSON of `FocusTimerState`; what lets a running session survive a restart.
    static let focusTimerState = Key<Data?>("focusTimerState", default: nil)

    // Verification only, not in Settings: seconds per "minute". 0 = production (60).
    // `defaults write <bundle id> focusTimerDebugMinuteSeconds -int 2` makes 25 min = 50 s.
    static let focusTimerDebugMinuteSeconds = Key<Int>("focusTimerDebugMinuteSeconds", default: 0)
}
