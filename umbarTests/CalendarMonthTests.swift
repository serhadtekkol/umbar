//
//  CalendarMonthTests.swift
//  umbarTests
//
//  Takvim's pure date logic (AC-6.1a, AC-6.4, AC-6R.2, AC-6R.3, #110): the
//  Monday-first 6 × 7 grid and the selected day's order. Fixed Gregorian
//  calendar in Istanbul so the run does not depend on the Mac's region.
//

import Foundation
import Testing

private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Istanbul")!
    c.locale = Locale(identifier: "tr_TR")
    c.firstWeekday = 1  // Sunday, so the grid has to override it
    return c
}()

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private struct Item: DayAgendaItem, Equatable {
    let id: String
    let start: Date
    let end: Date
    var isAllDay = false
    var reminderCompleted: Bool? = nil
}

@Suite(.timeLimit(.minutes(1)))
struct CalendarMonthTests {
    @Test(arguments: [(2026, 3), (2026, 8), (2026, 11), (2026, 2), (2026, 6), (2026, 10)])
    func sixWeeksMondayFirstWholeMonthVisible(year: Int, month: Int) {
        let grid = MonthGrid(containing: date(year, month, 15), calendar: calendar)
        #expect(grid.days.count == 42)
        #expect(calendar.component(.weekday, from: grid.days[0]) == 2)  // Monday
        let last = calendar.range(of: .day, in: .month, for: grid.month)!.count
        #expect(grid.days.contains(date(year, month, 1)))
        #expect(grid.days.contains(date(year, month, last)))
        #expect(grid.days.filter(grid.isInMonth).count == last)
    }

    @Test func november2026RunsFrom26OctoberTo6December() {
        let grid = MonthGrid(containing: date(2026, 11, 30), calendar: calendar)
        #expect(grid.days.first == date(2026, 10, 26))
        #expect(grid.days.last == date(2026, 12, 6))
        #expect(grid.days.firstIndex(of: date(2026, 11, 30)) == 35)  // 6th row, Monday
    }

    @Test func monthStartingOnMondayHasNoLeadingDays() {
        let grid = MonthGrid(containing: date(2026, 6, 10), calendar: calendar)
        #expect(grid.days.first == date(2026, 6, 1))
    }

    @Test func everyCellIsMidnightAcrossDSTChange() {
        var berlin = calendar
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let grid = MonthGrid(containing: berlin.date(from: DateComponents(year: 2026, month: 3, day: 15))!, calendar: berlin)
        #expect(grid.days.allSatisfy { berlin.component(.hour, from: $0) == 0 })
    }

    @Test func weekdaySymbolsStartOnMonday() {
        let grid = MonthGrid(containing: date(2026, 11, 1), calendar: calendar)
        let symbols = grid.weekdaySymbols
        #expect(symbols.count == 7)
        #expect(symbols.first == calendar.veryShortStandaloneWeekdaySymbols[1])
        #expect(symbols.last == calendar.veryShortStandaloneWeekdaySymbols[0])
    }

    @Test func shiftingCrossesTheYear() {
        let grid = MonthGrid(containing: date(2026, 12, 31), calendar: calendar)
        #expect(grid.shifted(by: 1).month == date(2027, 1, 1))
        #expect(grid.shifted(by: -12).month == date(2025, 12, 1))
        #expect(grid.interval.start == grid.days.first)
        #expect(grid.interval.end == calendar.date(byAdding: .day, value: 1, to: grid.days.last!))
    }

    @Test func todayOrdersOverdueThenAllDayThenByStart() {
        let now = date(2026, 11, 12, 10, 20)
        let items = [
            Item(id: "late", start: date(2026, 11, 12, 18), end: date(2026, 11, 12, 19)),
            Item(id: "early", start: date(2026, 11, 12, 8), end: date(2026, 11, 12, 9)),
            Item(id: "allday", start: date(2026, 11, 12), end: date(2026, 11, 13), isAllDay: true),
            Item(id: "overdueYesterday", start: date(2026, 11, 11, 18), end: date(2026, 11, 11, 18), reminderCompleted: false),
            Item(id: "doneYesterday", start: date(2026, 11, 11, 18), end: date(2026, 11, 11, 18), reminderCompleted: true),
            Item(id: "reminderLater", start: date(2026, 11, 12, 17), end: date(2026, 11, 12, 17), reminderCompleted: false),
            Item(id: "untimedReminder", start: date(2026, 11, 12), end: date(2026, 11, 12), isAllDay: true, reminderCompleted: false),
            Item(id: "tomorrow", start: date(2026, 11, 13, 9), end: date(2026, 11, 13, 10)),
        ]
        let agenda = DayAgenda(day: now, items: items, now: now, calendar: calendar)
        #expect(agenda.overdue.map(\.id) == ["overdueYesterday"])
        #expect(agenda.allDay.map(\.id) == ["allday", "untimedReminder"])
        #expect(agenda.timed.map(\.id) == ["early", "reminderLater", "late"])
        #expect(agenda.count == 6)
    }

    @Test func otherDayHidesOverdueAndKeepsMultiDayEvents() {
        let now = date(2026, 11, 12, 10, 20)
        let items = [
            Item(id: "overdue", start: date(2026, 11, 11, 18), end: date(2026, 11, 11, 18), reminderCompleted: false),
            Item(id: "trip", start: date(2026, 11, 29), end: date(2026, 12, 2), isAllDay: true),
            Item(id: "overnight", start: date(2026, 11, 29, 22), end: date(2026, 11, 30, 2)),
        ]
        let agenda = DayAgenda(day: date(2026, 11, 30), items: items, now: now, calendar: calendar)
        #expect(agenda.overdue.isEmpty)
        #expect(agenda.allDay.map(\.id) == ["trip"])
        #expect(agenda.timed.map(\.id) == ["overnight"])
        // An all-day event ends at midnight: not on the following day.
        #expect(DayAgenda(day: date(2026, 12, 2), items: items, now: now, calendar: calendar).isEmpty)
    }

    @Test func timingAgainstTheClock() {
        let now = date(2026, 11, 12, 10, 20)
        #expect(AgendaTiming(start: date(2026, 11, 12, 9), end: date(2026, 11, 12, 10), now: now) == .past)
        #expect(AgendaTiming(start: date(2026, 11, 12, 10), end: date(2026, 11, 12, 11), now: now) == .now)
        #expect(AgendaTiming(start: date(2026, 11, 12, 10, 30), end: date(2026, 11, 12, 11), now: now) == .soon(minutes: 10))
        #expect(AgendaTiming(start: date(2026, 11, 12, 10, 35), end: date(2026, 11, 12, 11), now: now) == .soon(minutes: 15))
        #expect(AgendaTiming(start: date(2026, 11, 12, 10, 36), end: date(2026, 11, 12, 11), now: now) == .later)
    }
}
