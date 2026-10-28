//
//  CalendarPage.swift
//  boringNotch
//
//  Takvim: the month (Monday first, always 6 weeks) and the selected day's
//  list side by side (AC-6.1a, design-language §5.4). The permission asks
//  (Calendar first, Reminders after) live here, never on Şimdi, so the
//  first-use prompt has the page's full room.
//
//  The month label and arrows sit in a column left of the grid, not in a row
//  above it: with the 254 × 45 pt notch the page is 167 pt tall, and a title
//  row + weekday letters + 6 × 24 pt rows needs 174.
//

import Defaults
import SwiftUI

struct CalendarPage: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Default(.showReminders) private var showReminders
    @Default(.remindersPromptDismissed) private var remindersPromptDismissed
    @State private var grid = MonthGrid(containing: .now)
    @State private var selected = Calendar.current.startOfDay(for: .now)

    var body: some View {
        CalendarPageContent(
            access: CalendarAccess(
                calendar: calendarManager.calendarPermission,
                reminders: calendarManager.reminderPermission,
                showReminders: showReminders,
                remindersPromptDismissed: remindersPromptDismissed),
            items: calendarManager.monthEvents,
            now: .now,
            grid: $grid,
            selected: $selected,
            onAllowCalendar: { Task { await calendarManager.requestCalendarAccess() } },
            onAllowReminders: { Task { await calendarManager.requestReminderAccess() } },
            onDismissReminders: { remindersPromptDismissed = true })
        .onHover { vm.isHoveringCalendar = $0 }
        .onAppear {
            calendarManager.refreshAuthorizationStatus()
            showToday()
            reload()
        }
        // Every opening starts on today, as Şimdi does.
        .onChange(of: vm.notchState) { _, _ in
            calendarManager.refreshAuthorizationStatus()
            showToday()
        }
        .onChange(of: grid) { _, _ in reload() }
        .onChange(of: calendarManager.calendarAuthorizationStatus) { _, _ in reload() }
        .onChange(of: calendarManager.reminderAuthorizationStatus) { _, _ in reload() }
    }

    private func showToday() {
        let today = Calendar.current.startOfDay(for: .now)
        selected = today
        if !grid.isInMonth(today) { grid = MonthGrid(containing: today) }
    }

    private func reload() {
        let interval = grid.interval
        Task { await calendarManager.updateMonth(interval) }
    }
}

struct CalendarAccess: Equatable {
    var calendar: PermissionState
    var reminders: PermissionState
    var showReminders: Bool
    var remindersPromptDismissed: Bool

    /// Something to list: events, or reminders alone when Calendar was
    /// declined but Reminders was not (AC-6R.8).
    var canList: Bool { calendar == .granted || (showReminders && reminders == .granted) }

    /// Calendar answered "no", Reminders never asked: Reminders still gets
    /// its one ask, after Calendar's and never beside it (AC-6R.8).
    var asksForRemindersAlone: Bool {
        calendar.isBlocked && showReminders && reminders == .notDetermined && !remindersPromptDismissed
    }
}

/// Values in, view out, so the offscreen render can feed it fixtures.
struct CalendarPageContent: View {
    let access: CalendarAccess
    /// Everything in the grid's 6 weeks, unfiltered.
    let items: [EventModel]
    let now: Date
    @Binding var grid: MonthGrid
    @Binding var selected: Date
    let onAllowCalendar: () -> Void
    let onAllowReminders: () -> Void
    let onDismissReminders: () -> Void

    static let headerWidth: CGFloat = 76
    static let gridGap: CGFloat = 12
    static let listGap: CGFloat = 28

    private var visible: [EventModel] { access.canList ? CalendarFilter.visible(items) : [] }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            MonthHeader(grid: $grid, selected: $selected, today: now)
                .frame(width: Self.headerWidth, alignment: .topLeading)
            MonthGridView(grid: $grid, selected: $selected, today: now, busyDays: busyDays)
                .padding(.leading, Self.gridGap)
            dayColumn
                .padding(.leading, Self.listGap)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Start-of-day dates with at least one visible item, for the dots.
    private var busyDays: Set<Date> {
        let calendar = grid.calendar
        let shown = grid.interval
        var days = Set<Date>()
        for item in visible {
            if item.type.isReminder {
                days.insert(calendar.startOfDay(for: item.start))
                continue
            }
            var day = max(calendar.startOfDay(for: item.start), shown.start)
            // All-day events end at the next midnight; that day is not busy.
            while day < min(item.end, shown.end) {
                days.insert(day)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return days
    }

    @ViewBuilder private var dayColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            DayTitle(day: selected, isToday: grid.calendar.isDate(selected, inSameDayAs: now))
            if access.canList {
                DayList(agenda: DayAgenda(day: selected, items: visible, now: now, calendar: grid.calendar),
                        isToday: grid.calendar.isDate(selected, inSameDayAs: now), now: now)
                secondaryAccess
            } else if access.asksForRemindersAlone {
                NotchPermissionPrompt(
                    state: access.reminders,
                    systemImage: "checklist",
                    title: "Reminders access",
                    reason: "Allow Reminders access to list your reminders here.",
                    deniedMessage: "Reminders access is off.",
                    pane: .reminders,
                    onAllow: onAllowReminders)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                // First use of the calendar is where Calendar access is asked
                // for, never at launch (AC-1.12, #59); AC-6.5 when declined.
                NotchPermissionPrompt(
                    state: access.calendar,
                    systemImage: "calendar",
                    title: "Calendar access",
                    reason: "umbar needs access to your calendar to list today's events here.",
                    deniedMessage: "Calendar access is off. Turn it on for umbar in System Settings.",
                    pane: .calendars,
                    onAllow: onAllowCalendar)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// The permission the list works without, as one row under it: Reminders
    /// while Calendar works (AC-6R.8), or Calendar while only Reminders does.
    @ViewBuilder private var secondaryAccess: some View {
        if access.calendar != .granted {
            AccessRow(state: access.calendar, glyph: "calendar",
                      ask: String(localized: "calendar.access.calendar.ask", defaultValue: "Show your events here too?"),
                      denied: String(localized: "calendar.access.calendar.denied", defaultValue: "Calendar access needed for events"),
                      pane: .calendars, onAllow: onAllowCalendar, onDismiss: nil)
        } else if access.showReminders, access.reminders != .granted,
                  !(access.reminders == .notDetermined && access.remindersPromptDismissed) {
            AccessRow(state: access.reminders, glyph: "checklist",
                      ask: String(localized: "calendar.access.reminders.ask", defaultValue: "Show your reminders here too?"),
                      denied: String(localized: "calendar.access.reminders.denied", defaultValue: "Reminders access needed"),
                      pane: .reminders, onAllow: onAllowReminders, onDismiss: onDismissReminders)
        }
    }
}

// MARK: - Month

private struct MonthHeader: View {
    @Binding var grid: MonthGrid
    @Binding var selected: Date
    let today: Date

    private var showsToday: Bool {
        !grid.calendar.isDate(selected, inSameDayAs: today) || !grid.isInMonth(today)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(grid.month.formatted(.dateTime.month(.wide)))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PageTokens.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 20, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Text(grid.month.formatted(.dateTime.year()))
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(PageTokens.textSecondary)
                .frame(height: 18, alignment: .leading)
            HStack(spacing: 0) {
                arrow("chevron.left", label: String(localized: "calendar.month.previous", defaultValue: "Previous month"), by: -1)
                arrow("chevron.right", label: String(localized: "calendar.month.next", defaultValue: "Next month"), by: 1)
            }
            .padding(.top, 6)
            .padding(.leading, -8)
            Spacer(minLength: 0)
            if showsToday {
                Button(String(localized: "calendar.today", defaultValue: "Today")) {
                    let day = grid.calendar.startOfDay(for: today)
                    selected = day
                    if !grid.isInMonth(day) { grid = MonthGrid(containing: day, calendar: grid.calendar) }
                }
                .buttonStyle(NotchSecondaryCapsuleButtonStyle())
                .frame(minHeight: 24)
                .transition(.opacity)
            }
        }
        .frame(height: MonthGridView.height, alignment: .topLeading)
    }

    private func arrow(_ glyph: String, label: String, by months: Int) -> some View {
        Button {
            grid = grid.shifted(by: months)
            // Keep the list in step with the month on screen.
            if !grid.isInMonth(selected) {
                selected = grid.calendar.isDate(today, equalTo: grid.month, toGranularity: .month)
                    ? grid.calendar.startOfDay(for: today) : grid.month
            }
        } label: {
            Image(systemName: glyph)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PageTokens.textPrimary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct MonthGridView: View {
    @Binding var grid: MonthGrid
    @Binding var selected: Date
    let today: Date
    let busyDays: Set<Date>

    static let cell = CGSize(width: 28, height: 24)
    static let lettersHeight: CGFloat = 12
    static let width = cell.width * CGFloat(MonthGrid.weekdays)
    static let height = lettersHeight + cell.height * CGFloat(MonthGrid.weeks)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(grid.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(PageTokens.textSecondary)
                        .frame(width: Self.cell.width, height: Self.lettersHeight)
                }
            }
            .accessibilityHidden(true)
            ForEach(0..<MonthGrid.weeks, id: \.self) { week in
                HStack(spacing: 0) {
                    ForEach(0..<MonthGrid.weekdays, id: \.self) { weekday in
                        cell(grid.days[week * MonthGrid.weekdays + weekday])
                    }
                }
            }
        }
        .frame(width: Self.width, height: Self.height)
        .contentShape(Rectangle())
        // One tab stop for the whole grid, arrows inside it (§6.2): 42 cells
        // as separate stops would bury the day list behind them.
        .focusable()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            if press.modifiers.contains(.command) {
                switch press.key {
                case .leftArrow: move(months: -1)
                case .rightArrow: move(months: 1)
                default: return .ignored
                }
                return .handled
            }
            switch press.key {
            case .leftArrow: select(grid.day(selected, movedBy: -1))
            case .rightArrow: select(grid.day(selected, movedBy: 1))
            case .upArrow: select(grid.day(selected, movedBy: -7))
            default: select(grid.day(selected, movedBy: 7))
            }
            return .handled
        }
        .accessibilityElement(children: .contain)
    }

    private func cell(_ day: Date) -> some View {
        DayCell(day: day,
                inMonth: grid.isInMonth(day),
                isToday: grid.calendar.isDate(day, inSameDayAs: today),
                isSelected: grid.calendar.isDate(day, inSameDayAs: selected),
                isBusy: busyDays.contains(day),
                calendar: grid.calendar) {
            select(day)
        }
    }

    /// A neighbouring month's day opens that month (§5.4).
    private func select(_ day: Date) {
        selected = day
        if !grid.isInMonth(day) { grid = MonthGrid(containing: day, calendar: grid.calendar) }
    }

    private func move(months: Int) {
        let day = grid.calendar.date(byAdding: .month, value: months, to: selected) ?? selected
        select(grid.calendar.startOfDay(for: day))
    }
}

private struct DayCell: View {
    let day: Date
    let inMonth: Bool
    let isToday: Bool
    let isSelected: Bool
    let isBusy: Bool
    let calendar: Calendar
    let action: () -> Void
    @State private var hovering = false

    /// Today = filled disc (r 8.5), selected = ring outside it (r 10), so a
    /// day that is both shows both; busy = dot under the ring.
    var body: some View {
        Button(action: action) {
            ZStack {
                if isToday {
                    Circle().fill(Color.white).frame(width: 17, height: 17)
                } else if hovering {
                    Circle().fill(PageTokens.raisedStrong).frame(width: 17, height: 17)
                }
                if isSelected {
                    Circle().strokeBorder(PageTokens.textPrimary, lineWidth: 1.5).frame(width: 21, height: 21)
                }
                Text(day.formatted(.dateTime.day()))
                    .font(.system(size: 11, weight: isToday ? .semibold : .medium).monospacedDigit())
                    .foregroundStyle(isToday ? Color.black : inMonth ? PageTokens.textPrimary : PageTokens.textSecondary)
                if isBusy {
                    Circle()
                        .fill(PageTokens.textSecondary)
                        .frame(width: 3, height: 3)
                        .offset(y: 11)
                }
            }
            .offset(y: -1)
            .frame(width: MonthGridView.cell.width, height: MonthGridView.cell.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .accessibilityLabel(day.formatted(.dateTime.day().month(.wide).weekday(.wide)))
        .accessibilityValue(value)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var value: String {
        var parts: [String] = []
        if isToday { parts.append(String(localized: "calendar.cell.today", defaultValue: "today")) }
        if isSelected { parts.append(String(localized: "calendar.cell.selected", defaultValue: "selected")) }
        if isBusy { parts.append(String(localized: "calendar.cell.busy", defaultValue: "has events")) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Day

private struct DayTitle: View {
    let day: Date
    let isToday: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(day.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PageTokens.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if isToday {
                Text(String(localized: "calendar.today", defaultValue: "Today"))
                    .font(.system(size: 11))
                    .foregroundStyle(PageTokens.textSecondary)
            }
        }
        .frame(height: 16)
    }
}

private struct DayList: View {
    let agenda: DayAgenda<EventModel>
    let isToday: Bool
    let now: Date

    var body: some View {
        if agenda.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 13))
                    .accessibilityHidden(true)
                Text(isToday
                     ? String(localized: "calendar.day.emptyToday", defaultValue: "Nothing today")
                     : String(localized: "calendar.day.empty", defaultValue: "Nothing on this day"))
                    .font(.system(size: 12))
            }
            .foregroundStyle(PageTokens.textSecondary)
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(.top, 4)
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(agenda.overdue) { DayRow(event: $0, now: now, overdue: true) }
                    if !agenda.allDay.isEmpty {
                        Text(String(localized: "now.today.allDay", defaultValue: "All day"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PageTokens.textSecondary)
                            .frame(height: 18, alignment: .bottom)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(agenda.allDay) { DayRow(event: $0, now: now) }
                    }
                    if !agenda.timed.isEmpty, !agenda.allDay.isEmpty {
                        Spacer().frame(height: 4)
                    }
                    ForEach(agenda.timed) { DayRow(event: $0, now: now) }
                }
            }
            .scrollIndicators(.automatic)
            // Scrolls inside whatever height is left; its ideal height is 0
            // so the render's overflow probe measures the page, not the list.
            .frame(minHeight: 0, idealHeight: 0, maxHeight: .infinity, alignment: .top)
            // A row cut by the bottom edge fades out: it reads as "scrolls",
            // not as clipped.
            .mask {
                VStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 10)
                }
            }
        }
    }
}

private struct DayRow: View {
    @Environment(\.openURL) private var openURL
    let event: EventModel
    let now: Date
    var overdue = false
    @State private var pending: Bool?
    @State private var saveFailed = false

    private var completed: Bool { pending ?? (event.reminderCompleted ?? false) }
    /// Events against the clock: "Now", "in 12 min", or dimmed once over.
    private var timing: AgendaTiming? {
        guard !event.isAllDay, !event.type.isReminder else { return nil }
        return AgendaTiming(start: event.start, end: event.end, now: now)
    }
    private var dimmed: Bool { completed || timing == .past }

    var body: some View {
        HStack(spacing: 6) {
            marker
            Button {
                if let url = event.calendarAppURL() { openURL(url) }
            } label: {
                HStack(spacing: 6) {
                    // All-day rows have no time, so the source fits beside
                    // the title and the row takes one line.
                    if event.isAllDay {
                        title
                        Text(meta)
                            .font(.system(size: 11))
                            .foregroundStyle(PageTokens.textSecondary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            title
                            Text(meta)
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(PageTokens.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    badge
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(event.title)
        }
        .frame(height: event.isAllDay ? 22 : 30)
        .accessibilityElement(children: .contain)
    }

    private var title: some View {
        Text(event.title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(dimmed ? PageTokens.textSecondary : PageTokens.textPrimary)
            .strikethrough(completed)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Event = calendar-coloured bar; reminder = completion circle (AC-6R.2):
    /// told apart by shape, not by colour.
    @ViewBuilder private var marker: some View {
        if event.type.isReminder {
            ReminderToggle(
                isOn: Binding(get: { completed }, set: { setCompleted($0) }),
                color: Color(event.calendar.color))
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
        } else {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(event.calendar.color))
                .frame(width: 3, height: event.isAllDay ? 16 : 24)
                .frame(width: 24)
                .accessibilityHidden(true)
        }
    }

    /// Time first, then the calendar or list name (AC-6R.2: the list name is
    /// visible), so the colour bar never carries the only clue.
    private var meta: String {
        let source = event.calendar.title
        if event.isAllDay { return source }
        // An overdue reminder from an earlier day says which day.
        let time = overdue && !Calendar.current.isDate(event.start, inSameDayAs: now)
            ? event.start.formatted(.dateTime.day().month(.abbreviated).hour().minute())
            : event.type.isReminder || event.end <= event.start
            ? event.start.formatted(date: .omitted, time: .shortened)
            : "\(event.start.formatted(date: .omitted, time: .shortened))–\(event.end.formatted(date: .omitted, time: .shortened))"
        return source.isEmpty ? time : "\(time) · \(source)"
    }

    @ViewBuilder private var badge: some View {
        if saveFailed {
            Label(String(localized: "calendar.reminder.saveFailed", defaultValue: "Couldn't save"), systemImage: "exclamationmark.circle")
                .foregroundStyle(PageTokens.danger)
        } else if overdue {
            Label(String(localized: "now.today.overdue", defaultValue: "Overdue"), systemImage: "exclamationmark.circle")
                .foregroundStyle(PageTokens.danger)
        } else if let timing {
            switch timing {
            case .now:
                Label(String(localized: "calendar.event.now", defaultValue: "Now"), systemImage: "circle.fill")
                    .labelStyle(NowBadgeStyle())
                    .foregroundStyle(PageTokens.live)
            case .soon(let minutes):
                Text(String(format: String(localized: "calendar.event.inMinutes", defaultValue: "in %lld min"), minutes))
                    .foregroundStyle(PageTokens.live)
            case .past, .later:
                EmptyView()
            }
        }
    }

    private func setCompleted(_ done: Bool) {
        pending = done
        saveFailed = false
        Task {
            let saved = await CalendarManager.shared.setReminderCompleted(reminderID: event.id, completed: done)
            pending = nil
            if !saved {
                // The circle goes back (the list was re-read) and the row
                // says why, never silently (AC-6R.6).
                saveFailed = true
                AccessibilityNotification.Announcement(
                    String(localized: "calendar.reminder.saveFailed", defaultValue: "Couldn't save")).post()
            }
        }
    }
}

/// "● Now": a small filled dot before the word, so the state has a shape and
/// not only the amber colour.
private struct NowBadgeStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6))
            configuration.title
        }
    }
}

/// One row for the permission the page works without (AC-6R.8): ask, open
/// System Settings, or (restricted) only say why.
private struct AccessRow: View {
    let state: PermissionState
    let glyph: String
    let ask: String
    let denied: String
    let pane: PrivacyPane
    let onAllow: () -> Void
    let onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.glyph(glyph))
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
                .minimumScaleFactor(0.9)
            Spacer(minLength: 4)
            switch state {
            case .notDetermined:
                Button(String(localized: "calendar.access.allow", defaultValue: "Allow"), action: onAllow)
                    .buttonStyle(NotchCapsuleButtonStyle())
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "calendar.access.dismiss", defaultValue: "Not now"))
                    .accessibilityLabel(String(localized: "calendar.access.dismiss", defaultValue: "Not now"))
                }
            case .denied:
                Button(String(localized: "calendar.access.openSettings", defaultValue: "Open Settings")) { pane.open() }
                    .buttonStyle(NotchSecondaryCapsuleButtonStyle())
            case .restricted, .granted:
                EmptyView()
            }
        }
        .foregroundStyle(PageTokens.textSecondary)
        .frame(height: 24)
        .accessibilityElement(children: .contain)
    }

    private var text: String {
        switch state {
        case .notDetermined, .granted: ask
        case .denied: denied
        case .restricted: String(localized: "calendar.access.restricted", defaultValue: "Turned off by an administrator")
        }
    }
}

extension EventModel: DayAgendaItem {
    var reminderCompleted: Bool? {
        if case .reminder(let completed) = type { return completed }
        return nil
    }
}
