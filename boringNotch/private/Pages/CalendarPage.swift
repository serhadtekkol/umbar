//
//  CalendarPage.swift
//  boringNotch
//
//  Takvim: the day picker and the chosen day's events and reminders. The
//  permission asks (Calendar first, Reminders after) live here, never on
//  Şimdi, so the first-use prompt has the page's full room.
//

import SwiftUI

struct CalendarPage: View {
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        CalendarView()
            .onHover { vm.isHoveringCalendar = $0 }
    }
}
