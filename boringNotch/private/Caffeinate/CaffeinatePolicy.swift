//
//  CaffeinatePolicy.swift
//  boringNotch
//
//  Pure (Foundation-only) rules for F11 caffeinate: durations, expiry and the
//  low-battery cut-off. Kept free of IOKit/SwiftUI so the logic can be unit
//  tested without touching real power assertions.
//

import Foundation

/// Durations offered in the UI (AC-11.2).
enum CaffeinateDuration: CaseIterable, Equatable {
    case indefinite
    case minutes15
    case hour1
    case hours2

    /// Length of the session, or `nil` for "until turned off".
    var interval: TimeInterval? {
        switch self {
        case .indefinite: return nil
        case .minutes15: return 15 * 60
        case .hour1: return 60 * 60
        case .hours2: return 2 * 60 * 60
        }
    }
}

/// Why caffeinate went from on to off. Drives the notice the user sees.
enum CaffeinateStopReason: Equatable {
    case user
    case expired
    /// BR-11.1: battery dropped below the threshold while unplugged.
    case lowBattery
}

/// One running caffeinate session. The deadline is fixed at creation so a
/// late timer callback cannot stretch the session.
struct CaffeinateSession: Equatable {
    let duration: CaffeinateDuration
    let startedAt: Date
    let deadline: Date?

    init(duration: CaffeinateDuration, startedAt: Date) {
        self.duration = duration
        self.startedAt = startedAt
        self.deadline = duration.interval.map { startedAt.addingTimeInterval($0) }
    }

    /// Seconds left, clamped at 0; `nil` for an indefinite session.
    func remaining(at now: Date) -> TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Expiry is inclusive: at exactly the deadline the session is over.
    func hasExpired(at now: Date) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }
}

enum CaffeinatePolicy {
    /// BR-11.1: exactly this percent keeps caffeinate on; one below turns it off.
    static let lowBatteryThresholdPercent = 10

    /// Integer battery percent as the system presents it, or `nil` when the
    /// reading is unusable (no battery, max capacity 0) so we never switch off
    /// on a garbage value.
    static func percent(current: Double, max: Double) -> Int? {
        guard max > 0, current >= 0 else { return nil }
        return Int((current / max * 100).rounded())
    }

    /// BR-11.1 / AC-11.6: only on battery power and strictly below the threshold.
    static func shouldStopForBattery(percent: Int?, isPluggedIn: Bool) -> Bool {
        guard let percent, !isPluggedIn else { return false }
        return percent < lowBatteryThresholdPercent
    }

    /// Compact label for the remaining time: "42m", "1h 05m", "59s".
    static func remainingLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        if total < 60 { return "\(total)s" }
        let minutes = (total + 59) / 60
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }
}
