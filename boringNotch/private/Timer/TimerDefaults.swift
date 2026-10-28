//
//  TimerDefaults.swift
//  boringNotch
//
//  Defaults keys for the timer and stopwatch (F25). Kept out of
//  Constants.swift to avoid merge conflicts.
//

import Defaults
import Foundation

/// Which clock the Araçlar time card shows. The focus timer, the countdown
/// and the stopwatch share one card: four tiles do not fit the page width.
enum TimeToolMode: String, Defaults.Serializable, CaseIterable {
    case focus
    case countdown
    case stopwatch
}

extension Defaults.Keys {
    static let timerEnabled = Key<Bool>("timerEnabled", default: true)
    /// The custom length offered next to the 1/5/10/25 presets.
    static let timerCustomMinutes = Key<Int>("timerCustomMinutes", default: 15)
    /// Off by default: the end of a countdown is shown, not heard, unless asked.
    static let timerPlaysSound = Key<Bool>("timerPlaysSound", default: false)
    /// Posts a system notification at the end, if umbar already has permission.
    /// Never asks for permission itself.
    static let timerNotifies = Key<Bool>("timerNotifies", default: true)
    static let timeToolMode = Key<TimeToolMode>("timeToolMode", default: .focus)

    /// JSON of `TimerState`; what lets a running timer survive a restart.
    static let timerState = Key<Data?>("timerState", default: nil)

    // Verification only, not in Settings: seconds per "minute". 0 = production (60).
    // `defaults write <bundle id> timerDebugMinuteSeconds -int 2` makes 5 min = 10 s.
    static let timerDebugMinuteSeconds = Key<Int>("timerDebugMinuteSeconds", default: 0)
}
