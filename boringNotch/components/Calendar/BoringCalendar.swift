//
//  BoringCalendar.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//
//  What Şimdi and Takvim share: the Settings filters and the reminder
//  completion circle. Upstream's day wheel was replaced by the month grid in
//  private/Pages/CalendarPage.swift (#20).
//

import Defaults
import SwiftUI

enum CalendarFilter {
    /// The items Settings lets through: completed reminders only when
    /// "Hide completed reminders" is off, all-day events only when "Hide
    /// all-day events" is off.
    static func visible(_ events: [EventModel]) -> [EventModel] {
        events.filter { event in
            if case .reminder(let completed) = event.type {
                return !completed || !Defaults[.hideCompletedReminders]
            }
            return !(event.isAllDay && Defaults[.hideAllDayEvents])
        }
    }
}

struct ReminderToggle: View {
    @Binding var isOn: Bool
    var color: Color

    var body: some View {
        Button(action: {
            isOn.toggle()
        }) {
            ZStack {
                // Outer ring
                Circle()
                    .strokeBorder(color, lineWidth: 2)
                    .frame(width: 14, height: 14)
                // Inner fill
                if isOn {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Circle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: 14, height: 14)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(0)
        .accessibilityLabel(isOn ? "Mark as incomplete" : "Mark as complete")
    }
}
