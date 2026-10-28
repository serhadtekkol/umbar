//
//  CalendarMonth.swift
//  boringNotch
//
//  Takvim's date logic with no EventKit and no SwiftUI, so the hostless
//  umbarTests bundle compiles it: the Monday-first 6 × 7 month grid
//  (design-language §5.4, #110) and the selected day's ordering (AC-6.1a,
//  AC-6.4, AC-6R.2, AC-6R.3).
//

import Foundation

/// One month as the grid draws it: always 6 weeks of 7 days, Monday first,
/// the neighbouring months filling the first and last rows. A fixed row count
/// keeps the page the same height in every month (no layout shift).
struct MonthGrid: Equatable {
    static let weeks = 6
    static let weekdays = 7

    /// Start of the month's first day.
    let month: Date
    /// `weeks × weekdays` start-of-day dates, row by row.
    let days: [Date]
    let calendar: Calendar

    /// The grid's calendar: the system one with Monday as the first weekday
    /// (AC-6.1a, NFR-LOC-1), whatever the region says.
    static func mondayFirst(_ base: Calendar = .current) -> Calendar {
        var calendar = base
        calendar.firstWeekday = 2
        return calendar
    }

    init(containing date: Date, calendar base: Calendar = .current) {
        let calendar = Self.mondayFirst(base)
        let components = calendar.dateComponents([.year, .month], from: date)
        let first = calendar.date(from: components).map { calendar.startOfDay(for: $0) } ?? calendar.startOfDay(for: date)
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + Self.weekdays) % Self.weekdays
        let start = calendar.date(byAdding: .day, value: -lead, to: first) ?? first
        self.month = first
        self.calendar = calendar
        self.days = (0..<(Self.weeks * Self.weekdays)).map { offset in
            // Adding days, not seconds, keeps every cell at local midnight
            // across a DST change.
            calendar.date(byAdding: .day, value: offset, to: start) ?? start
        }
    }

    func isInMonth(_ day: Date) -> Bool {
        calendar.isDate(day, equalTo: month, toGranularity: .month)
    }

    func shifted(by months: Int) -> MonthGrid {
        MonthGrid(containing: calendar.date(byAdding: .month, value: months, to: month) ?? month, calendar: calendar)
    }

    /// The column headers, Monday first, in the calendar's locale.
    var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The span the grid shows, for fetching the "has events" dots.
    var interval: DateInterval {
        let end = days.last.flatMap { calendar.date(byAdding: .day, value: 1, to: $0) } ?? month
        return DateInterval(start: days.first ?? month, end: end)
    }

    /// `offset` days from `day` (keyboard: arrows move by 1 and 7).
    func day(_ day: Date, movedBy offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: day) ?? day
    }
}

/// What the day list needs from an item; `EventModel` conforms in the page.
protocol DayAgendaItem {
    var start: Date { get }
    var end: Date { get }
    var isAllDay: Bool { get }
    /// nil for an event; the completion state for a reminder.
    var reminderCompleted: Bool? { get }
}

/// The selected day's list in three groups, each already in display order.
struct DayAgenda<Item: DayAgendaItem> {
    /// Unfinished timed reminders whose time has passed; only when the
    /// selected day is today, and always on top (AC-6R.3, BR-6R.2).
    var overdue: [Item] = []
    /// All-day events and reminders without a time (AC-6.4, AC-6R.2).
    var allDay: [Item] = []
    /// Events and timed reminders by start time.
    var timed: [Item] = []

    var isEmpty: Bool { overdue.isEmpty && allDay.isEmpty && timed.isEmpty }
    var count: Int { overdue.count + allDay.count + timed.count }

    init(day: Date, items: [Item], now: Date, calendar: Calendar = .current) {
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
        let isToday = calendar.isDate(dayStart, inSameDayAs: now)
        for item in items {
            if Self.isOverdue(item, now: now) {
                // Overdue reminders belong to today only, whatever day they
                // were due; on any other day they are not shown at all.
                if isToday { overdue.append(item) }
                continue
            }
            // Overlaps the day: a multi-day event shows on each of its days;
            // a reminder is a point in time.
            let overlaps = item.reminderCompleted == nil
                ? item.start < dayEnd && item.end > dayStart
                : item.start >= dayStart && item.start < dayEnd
            guard overlaps else { continue }
            if item.isAllDay { allDay.append(item) } else { timed.append(item) }
        }
        let byStart: (Item, Item) -> Bool = { $0.start < $1.start }
        overdue.sort(by: byStart)
        allDay.sort(by: byStart)
        timed.sort(by: byStart)
    }

    static func isOverdue(_ item: Item, now: Date) -> Bool {
        guard item.reminderCompleted == false, !item.isAllDay else { return false }
        return item.start < now
    }
}

/// Where an event of today stands against the clock, for the list's
/// "Now" and "in 12 min" markers.
enum AgendaTiming: Equatable {
    case past
    case now
    /// Starts within the next `soonWindow` (AC-6.2's 15 minutes).
    case soon(minutes: Int)
    case later

    static let soonWindow: TimeInterval = 15 * 60

    init(start: Date, end: Date, now: Date) {
        if end <= now {
            self = .past
        } else if start <= now {
            self = .now
        } else if start.timeIntervalSince(now) <= Self.soonWindow {
            self = .soon(minutes: max(1, Int((start.timeIntervalSince(now) / 60).rounded(.up))))
        } else {
            self = .later
        }
    }
}
