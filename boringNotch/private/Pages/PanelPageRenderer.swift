//
//  PanelPageRenderer.swift
//  boringNotch
//
//  Debug-only: `-UmbarRenderPages <dir>` draws every page of the open panel
//  at the real panel size, with fixture data where the page would otherwise
//  show this Mac's state, writes one PNG per page and quits. Lets a layout
//  change be looked at for overlap and clipping without hovering the notch.
//  Never compiled into Release. Features that are off on this Mac can be
//  turned on for the run only, e.g. `-showCalendar YES -eyeBreakEnabled YES`
//  (argument domain; nothing is written to the user's defaults).
//

#if DEBUG
import AppKit
import EventKit
import SwiftUI

@MainActor
enum PanelPageRenderer {
    /// Returns false when the argument is absent; otherwise renders and exits.
    static func runIfRequested() -> Bool {
        guard let dir = UserDefaults.standard.string(forKey: "UmbarRenderPages") else { return false }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // MacBook Air 13" notch (design-language §3 reference) and a 14" Pro.
        for notch in [CGSize(width: 190, height: 37), CGSize(width: 200, height: 32), CGSize(width: 254, height: 45)] {
            let tag = "\(Int(notch.width))x\(Int(notch.height))"
            for view in NotchViews.allCases {
                render(page(view), selected: view, notch: notch, to: out.appendingPathComponent("page-\(view)-\(tag).png"))
            }
            for (name, fixture) in calendarFixtures() {
                render(fixture, selected: .calendar, notch: notch,
                       to: out.appendingPathComponent("page-calendar-\(name)-\(tag).png"))
            }
            render(nowPage(agenda: .items([]), live: []), selected: .home, notch: notch,
                   to: out.appendingPathComponent("page-home-empty-\(tag).png"))
            render(nowPage(agenda: .needsAccess, live: []), selected: .home, notch: notch,
                   to: out.appendingPathComponent("page-home-noaccess-\(tag).png"))
            render(nowPage(agenda: .off, live: []), selected: .home, notch: notch,
                   to: out.appendingPathComponent("page-home-musiconly-\(tag).png"))
        }
        exit(0)
    }

    @ViewBuilder
    private static func page(_ view: NotchViews) -> some View {
        switch view {
        case .home: nowPage(agenda: .items(fixtureEvents()), live: fixtureLive())
        case .shelf: ShelfView()
        case .calendar: CalendarPage()
        case .network: NetworkPageContent(snapshot: fixtureNetwork(), onReset: {})
        case .tools: ToolsPage()
        }
    }

    private static func nowPage(agenda: TodayAgenda, live: [LiveActivity]) -> some View {
        NowFixture(column: TodayColumnContent(agenda: agenda, live: live, showCalendarPage: {}))
    }

    private struct NowFixture: View {
        @Namespace private var ns
        let column: TodayColumnContent
        var body: some View { NotchHomeView(albumArtNamespace: ns, todayFixture: column) }
    }

    private static func render(_ page: some View, selected: NotchViews, notch: CGSize, to url: URL) {
        let vm = MotionFrameRenderer.fixtureViewModel(notch: notch)
        vm.open()
        BoringViewCoordinator.shared.currentView = selected

        // Mirrors ContentView.NotchLayout for the open state: header the
        // notch's height, the page under it, the same insets.
        let root = VStack(alignment: .leading, spacing: PanelLayout.headerSpacing) {
            BoringHeader()
                .frame(height: PanelLayout.headerHeight(notchHeight: notch.height))
            page
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .background { OverflowProbe(page: page, name: url.lastPathComponent) }
        }
        .padding(.horizontal, cornerRadiusInsets.opened.top + PanelLayout.sideInset)
        .padding(.bottom, PanelLayout.bottomInset)
        .frame(width: openNotchSize.width, height: openNotchSize.height, alignment: .top)
        .background(.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: cornerRadiusInsets.opened.bottom,
                                          bottomTrailingRadius: cornerRadiusInsets.opened.bottom))
        .padding(10)
        .background(Color(white: 0.85))
        .environmentObject(vm)
        .environment(\.colorScheme, .dark)

        let size = NSSize(width: openNotchSize.width + 20, height: openNotchSize.height + 20)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Let onAppear work and the first async updates settle, as on screen;
        // then put the fixture track back over whatever the player reported.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        seedMusic()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Says on stderr when a page needs more height than the panel gives it
    /// (it would be cut off by the island's bottom edge), so a render run
    /// catches it without anyone measuring the PNG.
    private struct OverflowProbe<Page: View>: View {
        let page: Page
        let name: String

        var body: some View {
            GeometryReader { proxy in
                page.fixedSize(horizontal: false, vertical: true)
                    .frame(width: proxy.size.width)
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { needed in
                        let given = proxy.size.height
                        if needed > given + 0.5 {
                            FileHandle.standardError.write(Data("\(name): page needs \(Int(needed.rounded())) pt, panel gives \(Int(given))\n".utf8))
                        }
                    }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: Fixtures

    private static func seedMusic() {
        let music = MusicManager.shared
        let art = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
            NSGradient(colors: [.systemIndigo, .systemPink])?.draw(in: rect, angle: 45)
            return true
        }
        music.albumArt = art
        music.songTitle = "Gesaffelstein — Pursuit (Extended Version)"
        music.artistName = "Gesaffelstein"
        music.songDuration = 245
        music.elapsedTime = 92
        music.timestampDate = Date()
        music.playbackRate = 0
        music.isPlaying = true
        music.isPlayerIdle = false
    }

    private static func fixtureEvents() -> [EventModel] {
        let now = Date()
        let work = CalendarModel(id: "w", account: "", title: "İş", color: .systemBlue, isSubscribed: false, isReminder: false)
        let home = CalendarModel(id: "h", account: "", title: "Ev", color: .systemOrange, isSubscribed: false, isReminder: true)
        func event(_ id: String, _ title: String, _ start: TimeInterval, _ length: TimeInterval, _ cal: CalendarModel,
                   type: EventType = .event(.accepted), allDay: Bool = false) -> EventModel {
            EventModel(id: id, start: now.addingTimeInterval(start), end: now.addingTimeInterval(start + length),
                       title: title, location: nil, notes: nil, url: nil, isAllDay: allDay, type: type,
                       calendar: cal, participants: [], timeZone: nil, hasRecurrenceRules: false, priority: nil)
        }
        // Already in TodayAgenda order; not filtered by the clock, so the
        // render looks the same at any hour.
        return [
            event("r1", "Faturayı öde", -3600, 0, home, type: .reminder(completed: false)),
            event("e1", "Haftalık ekip toplantısı ve sprint planlaması", -600, 2400, work),
            event("e2", "Tasarım incelemesi", 5400, 1800, work),
            event("e3", "Diş hekimi", 9000, 1800, home),
            event("e4", "Akşam koşusu", 14000, 1800, home),
        ]
    }

    // MARK: Takvim

    /// Thursday 12 November 2026, 10:20: a 6-week month (26 Oct – 6 Dec),
    /// so the last row and the 30th are in every render.
    private static let calendarNow: Date = {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 10, minute: 20)) ?? .now
    }()

    private struct CalendarFixture: View {
        let access: CalendarAccess
        let items: [EventModel]
        @State var grid = MonthGrid(containing: PanelPageRenderer.calendarNow)
        @State var selected: Date

        var body: some View {
            CalendarPageContent(access: access, items: items, now: PanelPageRenderer.calendarNow,
                                grid: $grid, selected: $selected,
                                onAllowCalendar: {}, onAllowReminders: {}, onDismissReminders: {})
        }
    }

    private static func calendarFixtures() -> [(String, CalendarFixture)] {
        let today = Calendar.current.startOfDay(for: calendarNow)
        let day30 = Calendar.current.date(byAdding: .day, value: 18, to: today) ?? today
        let items = fixtureMonth()
        func access(_ cal: EKAuthorizationStatus, _ rem: EKAuthorizationStatus, dismissed: Bool = false) -> CalendarAccess {
            CalendarAccess(calendar: PermissionState(cal), reminders: PermissionState(rem),
                           showReminders: true, remindersPromptDismissed: dismissed)
        }
        return [
            ("filled", CalendarFixture(access: access(.fullAccess, .fullAccess), items: items, selected: today)),
            ("day30", CalendarFixture(access: access(.fullAccess, .fullAccess), items: items, selected: day30)),
            ("empty", CalendarFixture(access: access(.fullAccess, .fullAccess), items: [], selected: today)),
            ("ask", CalendarFixture(access: access(.notDetermined, .notDetermined), items: [], selected: today)),
            ("denied", CalendarFixture(access: access(.denied, .denied), items: [], selected: today)),
            ("restricted", CalendarFixture(access: access(.restricted, .restricted), items: [], selected: today)),
            ("reminders-ask", CalendarFixture(access: access(.fullAccess, .notDetermined), items: items, selected: today)),
            ("reminders-denied", CalendarFixture(access: access(.fullAccess, .denied), items: items, selected: today)),
            ("reminders-restricted", CalendarFixture(access: access(.fullAccess, .restricted), items: items, selected: today)),
            ("reminders-only", CalendarFixture(access: access(.denied, .fullAccess), items: items.filter { $0.type.isReminder }, selected: today)),
            ("reminders-alone-ask", CalendarFixture(access: access(.denied, .notDetermined), items: [], selected: today)),
        ]
    }

    /// November 2026 around `calendarNow`: today has an overdue reminder, an
    /// all-day event, one in progress, one in 10 min and later ones; the 30th
    /// has a multi-day all-day event and a long title.
    private static func fixtureMonth() -> [EventModel] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: calendarNow)
        let work = CalendarModel(id: "w", account: "", title: "İş", color: .systemBlue, isSubscribed: false, isReminder: false)
        let home = CalendarModel(id: "h", account: "", title: "Ev", color: .systemOrange, isSubscribed: false, isReminder: false)
        let list = CalendarModel(id: "l", account: "", title: "Alışveriş", color: .systemGreen, isSubscribed: false, isReminder: true)
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            cal.date(byAdding: DateComponents(day: day, hour: hour, minute: minute), to: today) ?? today
        }
        func item(_ id: String, _ title: String, _ start: Date, _ end: Date, _ c: CalendarModel,
                  type: EventType = .event(.accepted), allDay: Bool = false) -> EventModel {
            EventModel(id: id, start: start, end: end, title: title, location: nil, notes: nil, url: nil,
                       isAllDay: allDay, type: type, calendar: c, participants: [], timeZone: nil,
                       hasRecurrenceRules: false, priority: nil)
        }
        let open = EventType.reminder(completed: false)
        return [
            item("r0", "Faturayı öde", at(-1, 18), at(-1, 18), list, type: open),
            item("a1", "Annemin doğum günü", at(0, 0), at(1, 0), home, allDay: true),
            item("e0", "Kahvaltı toplantısı", at(0, 8), at(0, 9), work),
            item("e1", "Haftalık ekip toplantısı ve sprint planlaması", at(0, 10), at(0, 11), work),
            item("e2", "Tasarım incelemesi", at(0, 10, 30), at(0, 11, 15), work),
            item("r1", "Süt al", at(0, 17), at(0, 17), list, type: open),
            item("e3", "Diş hekimi", at(0, 18), at(0, 18, 45), home),
            item("e4", "Akşam koşusu", at(0, 20), at(0, 21), home),
            item("e5", "Sunum provası", at(-3, 14), at(-3, 15), work),
            item("e6", "Kod incelemesi", at(4, 11), at(4, 12), work),
            item("a2", "Lizbon konferansı", at(17, 0), at(20, 0), work, allDay: true),
            item("e7", "Uçuş TK1759 İstanbul – Lizbon, Havalimanı terminal 1", at(18, 7, 15), at(18, 11, 40), work),
            item("r2", "Pasaportu kontrol et", at(18, 6), at(18, 6), list, type: open),
            item("e8", "Yılbaşı planı", at(22, 19), at(22, 20), home),
        ]
    }

    private static func fixtureLive() -> [LiveActivity] {
        [
            LiveActivity(id: "d1", kind: .download, phase: .running, title: "Xcode_17_beta_3.xip",
                         fraction: 0.42, bytesSoFar: 3_400_000_000, bytesPerSecond: 24_000_000,
                         percent: nil, minutesRemaining: nil, fileURL: nil, startedAt: Date(),
                         stripUntil: nil, expiresAt: nil),
            LiveActivity(id: "c1", kind: .charging, phase: .running, title: "",
                         fraction: nil, bytesSoFar: nil, bytesPerSecond: nil,
                         percent: 64, minutesRemaining: 48, fileURL: nil, startedAt: Date(),
                         stripUntil: nil, expiresAt: nil),
        ]
    }

    private static func fixtureNetwork() -> NetPageSnapshot {
        var history = NetRateHistory()
        for i in 0..<60 {
            let t = TimeInterval(i)
            history.append(NetRatePoint(time: t, rx: 2_000_000 + 9_000_000 * abs(sin(t / 7)), tx: 300_000 + 600_000 * abs(cos(t / 5))))
        }
        return NetPageSnapshot(
            network: NetMonitor.CurrentNetwork(interfaceName: "en0", kind: .wifi, wifiName: "Ev-5G Superonline"),
            rxRate: 12_400_000, txRate: 1_100_000, history: history,
            session: NetByteTotals(rx: 1_240_000_000, tx: 96_000_000),
            today: NetByteTotals(rx: 4_800_000_000, tx: 410_000_000),
            month: NetByteTotals(rx: 182_000_000_000, tx: 12_300_000_000))
    }
}
#endif
