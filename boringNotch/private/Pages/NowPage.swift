//
//  NowPage.swift
//  boringNotch
//
//  The right column of Şimdi: today's next three items and, only while
//  something is happening, the live activities. The month and the full day
//  list are on Takvim; "+N more" goes there.
//

import Defaults
import SwiftUI

struct TodayColumn: View {
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var liveCenter = LiveActivityCenter.shared
    @ObservedObject private var privacy = PrivacyIndicatorMonitor.shared
    @Default(.showCalendar) private var showCalendar
    @Default(.showReminders) private var showReminders

    var body: some View {
        TodayColumnContent(agenda: agenda, live: liveCenter.panelItems, privacy: privacy.usage) {
            withAnimation(.easeOut(duration: 0.18)) {
                BoringViewCoordinator.shared.currentView = .calendar
            }
        }
        .onAppear {
            // Takvim may have left the shared list on another day.
            guard showCalendar else { return }
            calendarManager.refreshAuthorizationStatus()
            Task { await calendarManager.updateCurrentDate(Date.now) }
        }
    }

    private var agenda: TodayAgenda {
        guard showCalendar else { return .off }
        let canList = calendarManager.calendarPermission == .granted
            || (showReminders && calendarManager.reminderPermission == .granted)
        guard canList else { return .needsAccess }
        return .items(TodayAgenda.today(from: calendarManager.events))
    }
}

enum TodayAgenda: Equatable {
    case off
    case needsAccess
    case items([EventModel])

    /// Today's items worth a glance: overdue reminders first, then by start;
    /// events that already ended are left out (they are on Takvim).
    static func today(from events: [EventModel], now: Date = .now) -> [EventModel] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return EventListView.filteredEvents(events: events)
            .filter { event in
                if case .reminder(let completed) = event.type {
                    return !completed && event.start < dayEnd
                }
                return event.start < dayEnd && event.end > max(dayStart, now)
            }
            .sorted { lhs, rhs in
                let lo = isOverdue(lhs, now: now), ro = isOverdue(rhs, now: now)
                if lo != ro { return lo }
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                return lhs.start < rhs.start
            }
    }

    static func isOverdue(_ event: EventModel, now: Date = .now) -> Bool {
        guard case .reminder(let completed) = event.type, !completed, !event.isAllDay else { return false }
        return event.start < now
    }
}

/// Values in, view out, so the offscreen render can feed it fixtures.
struct TodayColumnContent: View {
    let agenda: TodayAgenda
    let live: [LiveActivity]
    /// Camera/microphone in use (F23); a row under the live activities.
    var privacy: PrivacyUsage = .idle
    let showCalendarPage: () -> Void

    static let width: CGFloat = 236
    private static let rowLimit = 3

    /// Calendar off and nothing live: no column, the music takes the width.
    var body: some View {
        if agenda != .off || !live.isEmpty || privacy.isActive { column }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: PageTokens.s) {
            switch agenda {
            case .off:
                EmptyView()
            case .needsAccess:
                header(more: 0)
                accessRow
            case .items(let items):
                header(more: max(0, items.count - Self.rowLimit))
                if items.isEmpty {
                    Text(String(localized: "now.today.empty", defaultValue: "Nothing else today"))
                        .font(.system(size: 12))
                        .foregroundStyle(PageTokens.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items.prefix(Self.rowLimit)) { TodayRow(event: $0) }
                    }
                }
            }
            if !live.isEmpty || privacy.isActive {
                // One list of capsules: the privacy row takes the place of
                // one live line, at the live lines' own spacing.
                VStack(alignment: .leading, spacing: 6) {
                    if !live.isEmpty {
                        LiveActivityList(items: live, limit: (agenda == .off ? 4 : 2) - (privacy.isActive ? 1 : 0))
                    }
                    if privacy.isActive { PrivacyUsageRow(usage: privacy) }
                }
                .padding(.top, agenda == .off ? 0 : 4)
            }
        }
        .frame(width: Self.width, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }

    private func header(more: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(String(localized: "now.today.title", defaultValue: "Today"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PageTokens.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if more > 0 {
                Button(action: showCalendarPage) {
                    Text(String(format: String(localized: "now.today.more", defaultValue: "+%lld more"), more))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PageTokens.textSecondary)
                        .frame(minHeight: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "now.today.more.help", defaultValue: "Open Calendar"))
            }
        }
    }

    private var accessRow: some View {
        Button(action: showCalendarPage) {
            HStack(spacing: 6) {
                Image(systemName: "lock")
                    .font(.system(size: 11, weight: .semibold))
                    .accessibilityHidden(true)
                Text(String(localized: "now.today.access", defaultValue: "Allow calendar access on the Calendar page"))
                    .font(.system(size: 12))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(PageTokens.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TodayRow: View {
    @Environment(\.openURL) private var openURL
    let event: EventModel

    private var overdue: Bool { TodayAgenda.isOverdue(event) }

    var body: some View {
        HStack(spacing: 8) {
            marker
            Text(event.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PageTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            trailing
                .font(.system(size: 11).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
        }
        .frame(height: 20)
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = event.calendarAppURL() { openURL(url) }
        }
        .help(event.title)
        .accessibilityElement(children: .combine)
    }

    /// Event = calendar-coloured bar; reminder = completion circle (AC-6R.2):
    /// told apart by shape, not by colour.
    @ViewBuilder private var marker: some View {
        if event.type.isReminder {
            ReminderToggle(
                isOn: Binding(
                    get: { false },
                    set: { done in
                        Task { await CalendarManager.shared.setReminderCompleted(reminderID: event.id, completed: done) }
                    }),
                color: Color(event.calendar.color))
        } else {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(event.calendar.color))
                .frame(width: 3, height: 16)
                .frame(width: 14)
        }
    }

    @ViewBuilder private var trailing: some View {
        if overdue {
            Label(String(localized: "now.today.overdue", defaultValue: "Overdue"), systemImage: "exclamationmark.circle")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color(red: 0xFF / 255, green: 0x7B / 255, blue: 0x72 / 255))
        } else if event.isAllDay {
            Text(String(localized: "now.today.allDay", defaultValue: "All day"))
                .foregroundStyle(PageTokens.textSecondary)
        } else if event.start <= .now {
            Text(String(localized: "now.today.untilTime", defaultValue: "until \(event.end.formatted(date: .omitted, time: .shortened))"))
                .foregroundStyle(PageTokens.textPrimary)
        } else {
            Text(event.start, style: .time)
                .foregroundStyle(PageTokens.textSecondary)
        }
    }
}
