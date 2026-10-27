//
//  LiveActivityModel.swift
//  boringNotch
//
//  F19 live activities: the value the notch renders, and the rule for which
//  one the closed island shows when several are live at once.
//
//  Foundation-only for umbarTests. Text is formatted in the view.
//

import Foundation

enum LiveActivityKind: String, CaseIterable, Sendable {
    case download
    case airDrop
    case timeMachine
    case charging
}

/// One thing that is happening (or just happened) worth a glance.
struct LiveActivity: Identifiable, Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case running
        case finished
    }

    /// Stable across updates of the same activity (the download's entry name,
    /// "charging", ...), so SwiftUI animates value changes instead of
    /// replacing the row.
    let id: String
    let kind: LiveActivityKind
    var phase: Phase
    /// File name for downloads and AirDrop; empty for the others.
    var title: String
    /// 0...1 when known.
    var fraction: Double?
    var bytesSoFar: Int64?
    var bytesPerSecond: Double?
    /// Charging only.
    var percent: Int?
    var minutesRemaining: Int?
    /// The finished file, for drag-to-shelf.
    var fileURL: URL?
    var startedAt: Date
    /// When the closed island stops showing it. Nil = for as long as it runs.
    var stripUntil: Date?
    /// When it leaves the panel row too. Nil = for as long as it runs.
    var expiresAt: Date?
}

enum LiveActivityRanking {
    /// How long a "finished" item (download done, AirDrop received, backup
    /// done) stays on screen. Long enough to notice and drag the file to the
    /// shelf, short enough not to sit under the notch.
    static let finishedLinger: TimeInterval = 8
    /// The open panel keeps finished items a while longer so the user who
    /// missed the closed strip can still find the file.
    static let finishedPanelLinger: TimeInterval = 120
    /// Charging appears under the notch only briefly after the charger is
    /// connected (product decision pending, see F19 hand-off); the panel row
    /// shows it the whole time it charges.
    static let chargingStripLinger: TimeInterval = 8

    /// Lower sorts first.
    static func priority(_ a: LiveActivity) -> Int {
        switch (a.kind, a.phase) {
        case (.download, .running): return 0
        case (.airDrop, _): return 1
        case (.download, .finished): return 2
        case (.timeMachine, _): return 3
        case (.charging, _): return 4
        }
    }

    /// Items still alive at `now`, in display order: by priority, then newest
    /// first, then by id so equal items never swap places between frames.
    static func panelItems(_ items: [LiveActivity], now: Date) -> [LiveActivity] {
        items.filter { $0.expiresAt.map { $0 > now } ?? true }.sorted(by: order)
    }

    /// What the closed island shows: the first item, and how many more are
    /// live behind it.
    static func stripItems(_ items: [LiveActivity], now: Date) -> [LiveActivity] {
        panelItems(items, now: now).filter { $0.stripUntil.map { $0 > now } ?? true }
    }

    /// The earliest moment a visible item will disappear, so the owner can
    /// schedule a single refresh instead of ticking.
    static func nextExpiry(_ items: [LiveActivity], after now: Date) -> Date? {
        items.flatMap { [$0.stripUntil, $0.expiresAt] }
            .compactMap { $0 }
            .filter { $0 > now }
            .min()
    }

    private static func order(_ l: LiveActivity, _ r: LiveActivity) -> Bool {
        let pl = priority(l), pr = priority(r)
        if pl != pr { return pl < pr }
        if l.startedAt != r.startedAt { return l.startedAt > r.startedAt }
        return l.id < r.id
    }
}
