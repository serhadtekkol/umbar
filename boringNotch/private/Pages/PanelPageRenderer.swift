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
import UniformTypeIdentifiers

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
            // F22 states: pressure + heat warnings with a long app name, the
            // first half second after opening, and traffic turned off.
            render(NetworkPageStack { NetworkPageContent(snapshot: fixtureNetwork(), onReset: {}) }
                       system: { SysStatsRow(snapshot: fixtureSystemStressed()) },
                   selected: .network, notch: notch, to: out.appendingPathComponent("page-network-stressed-\(tag).png"))
            render(NetworkPageStack { NetworkPageContent(snapshot: fixtureNetwork(), onReset: {}) }
                       system: { SysStatsRow(snapshot: SysSnapshot(cpu: nil, memory: nil, thermal: .nominal, topApps: [])) },
                   selected: .network, notch: notch, to: out.appendingPathComponent("page-network-firstread-\(tag).png"))
            render(NetworkPageStack { EmptyView() } system: { SysStatsRow(snapshot: fixtureSystem()) },
                   selected: .network, notch: notch, to: out.appendingPathComponent("page-network-systemonly-\(tag).png"))
            render(nowPage(agenda: .items([]), live: []), selected: .home, notch: notch,
                   to: out.appendingPathComponent("page-home-empty-\(tag).png"))
            render(nowPage(agenda: .needsAccess, live: []), selected: .home, notch: notch,
                   to: out.appendingPathComponent("page-home-noaccess-\(tag).png"))
            render(nowPage(agenda: .off, live: []), selected: .home, notch: notch,
                   to: out.appendingPathComponent("page-home-musiconly-\(tag).png"))
            render(ToolsPage(btFixture: btBatteryFixture()), selected: .tools, notch: notch,
                   to: out.appendingPathComponent("page-tools-btbattery-\(tag).png"))
            for (state, model, section) in clipboardFixtures() {
                render(ShelfPage(clipboard: model, section: section), selected: .shelf, notch: notch,
                       to: out.appendingPathComponent("page-shelf-clipboard-\(state)-\(tag).png"))
            }
            for (state, ghosts) in undoChipFixtures() {
                render(ShelfPage(clipboard: ClipboardHistoryModel(fixture: []), undoChipFixture: ghosts, section: .files),
                       selected: .shelf, notch: notch,
                       to: out.appendingPathComponent("page-shelf-undo-\(state)-\(tag).png"))
            }
        }
        renderDragPreview(to: out.appendingPathComponent("shelf-drag-preview.png"))
        EyeBreakBannerRenderer.renderPages(to: out)
        exit(0)
    }

    @ViewBuilder
    private static func page(_ view: NotchViews) -> some View {
        switch view {
        case .home: nowPage(agenda: .items(fixtureEvents()), live: fixtureLive())
        case .shelf: ShelfPage(clipboard: ClipboardHistoryModel(fixture: []), section: .files)
        case .calendar: CalendarPage()
        case .network:
            NetworkPageStack { NetworkPageContent(snapshot: fixtureNetwork(), onReset: {}) }
                system: { SysStatsRow(snapshot: fixtureSystem()) }
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

    /// F24: AirPods with per-ear and case levels, a low Magic Mouse, a
    /// keyboard, and a long name, so truncation and the low state show.
    static func btBatteryFixture() -> [BTBatteryDevice] {
        [
            BTBatteryDevice(id: "A1", name: "Serhad Bahadır (AirPods Pro)", kind: .headphones,
                            battery: QuickBattery(left: 80, right: 75, caseLevel: 60)),
            BTBatteryDevice(id: "B2", name: "Magic Mouse", kind: .mouse, battery: QuickBattery(single: 12)),
            BTBatteryDevice(id: "C3", name: "Magic Keyboard with Touch ID and Numeric Keypad", kind: .keyboard,
                            battery: QuickBattery(single: 64)),
            BTBatteryDevice(id: "D4", name: "Magic Trackpad", kind: .trackpad, battery: QuickBattery(single: 100)),
        ]
    }

    /// The Pano side (F21) in each state it can be in. Fixed dates relative
    /// to now, so the cards' "2 min ago" footers read the same on every run.
    private static func clipboardFixtures() -> [(String, ClipboardHistoryModel, ShelfPageSection)] {
        let now = Date()
        func text(_ s: String, _ ago: TimeInterval) -> ClipboardItem {
            ClipboardItem(content: .text(s), copiedAt: now.addingTimeInterval(-ago))
        }
        let imageID = UUID()
        let image = ClipboardItem(id: imageID, content: .image(.init(fileName: "x.png", typeIdentifier: "public.png",
                                                                       byteCount: 1_240_000, digest: "d")),
                                  copiedAt: now.addingTimeInterval(-300))
        let art = NSImage(size: NSSize(width: 160, height: 100), flipped: false) { rect in
            NSGradient(colors: [.systemTeal, .systemPurple])?.draw(in: rect, angle: 30)
            return true
        }
        let items = [
            text("Toplantı notu: Perşembe 14:00'te tasarım incelemesi, Hüsna sunacak.", 40),
            ClipboardItem(content: .url("https://www.example.com/docs/clipboard-history?ref=umbar"), copiedAt: now.addingTimeInterval(-120)),
            image,
            text("    func copy(_ item: ClipboardItem) {\n\n        let pasteboard = NSPasteboard.general\n        pasteboard.clearContents()\n    }", 900),
            text("Çok uzun bir metin: " + String(repeating: "öğrenci şemsiye ığdır çay ", count: 20), 3600),
            text("TR42 0006 4000 0011 2345 6789 01", 7200),
        ]
        return [
            ("items", ClipboardHistoryModel(fixture: items, images: [imageID: art]), .clipboard),
            ("copied", ClipboardHistoryModel(fixture: items, images: [imageID: art], justCopied: items[0].id), .clipboard),
            ("empty", ClipboardHistoryModel(fixture: []), .clipboard),
            ("permission", ClipboardHistoryModel(fixture: Array(items.prefix(2)), permissionRequired: true), .clipboard),
        ]
    }

    /// One set of ghosts per chip state (design-language §5.3). The paths
    /// are never touched: the chip only shows them.
    private static func undoChipFixtures() -> [(String, [ShelfMoveGhost])] {
        func ghost(_ name: String, _ status: ShelfMoveGhost.Status, to folder: String = "/Users/me/Documents/Teklifler") -> ShelfMoveGhost {
            ShelfMoveGhost(id: UUID(), name: name, index: 0, originalPath: "/Users/me/Desktop/\(name)",
                           destination: URL(fileURLWithPath: "\(folder)/\(name)"), status: status)
        }
        return [
            ("ready", [ghost("teklif.pdf", .ready)]),
            ("locating", [ghost("teklif.pdf", .locating)]),
            ("longname", [ghost("2026-Q4 Müşteri Sunumu — son hali (revize 3, onaylı) kopya.key", .ready)]),
            ("multi", [ghost("teklif.pdf", .ready), ghost("fatura.pdf", .ready), ghost("logo.png", .ready)]),
            ("trash", [ghost("teklif.pdf", .ready, to: "/Users/me/.Trash")]),
            ("unavailable", [ghost("teklif.pdf", .undoUnavailable)]),
            ("undoing", [ghost("teklif.pdf", .undoing)]),
            ("failed", [ghost("teklif.pdf", .failed(.originalOccupied))]),
            ("leftcopy", [ghost("teklif.pdf", .restoredLeavingCopy, to: "/Volumes/Yedek")]),
        ]
    }

    /// The drag image with its "⌥: kopyala" rule, on a light and a dark
    /// desktop, since it floats over whatever is under the pointer.
    private static func renderDragPreview(to url: URL) {
        let icon = NSWorkspace.shared.icon(for: .pdf)
        let preview = DragPreviewView(thumbnail: icon, displayName: "teklif.pdf", showsCopyRule: true)
        let root = HStack(spacing: 0) {
            preview.padding(16).background(Color(white: 0.96))
            preview.padding(16).background(Color(white: 0.12))
        }
        let renderer = ImageRenderer(content: root)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func fixtureSystem() -> SysSnapshot {
        SysSnapshot(cpu: 0.23,
                    memory: SysMemory(usedBytes: 12_990_000_000, totalBytes: 17_179_869_184, pressure: .normal),
                    thermal: .nominal,
                    topApps: [SysAppUsage(name: "Xcode", cpu: 0.84), SysAppUsage(name: "Safari", cpu: 0.12)])
    }

    private static func fixtureSystemStressed() -> SysSnapshot {
        SysSnapshot(cpu: 0.97,
                    memory: SysMemory(usedBytes: 15_700_000_000, totalBytes: 17_179_869_184, pressure: .critical),
                    thermal: .serious,
                    topApps: [SysAppUsage(name: "Adobe Premiere Pro 2026 (Beta)", cpu: 6.12),
                              SysAppUsage(name: "Google Chrome", cpu: 1.48)])
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
