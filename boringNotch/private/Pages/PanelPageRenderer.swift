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
            render(CalendarPage(), selected: .calendar, notch: notch, seedCalendar: true,
                   to: out.appendingPathComponent("page-calendar-content-\(tag).png"))
            render(nowPage(agenda: .items([]), live: []), selected: .home, notch: notch,
                   to: out.appendingPathComponent("page-home-empty-\(tag).png"))
            render(nowPage(agenda: .needsAccess, live: []), selected: .home, notch: notch,
                   to: out.appendingPathComponent("page-home-noaccess-\(tag).png"))
            render(nowPage(agenda: .off, live: []), selected: .home, notch: notch,
                   to: out.appendingPathComponent("page-home-musiconly-\(tag).png"))
            for (state, agenda, live, usage) in privacyFixtures() {
                render(nowPage(agenda: agenda, live: live, privacy: usage), selected: .home, notch: notch,
                       to: out.appendingPathComponent("page-home-privacy-\(state)-\(tag).png"))
            }
            for (state, ghosts) in undoChipFixtures() {
                render(ShelfView(undoChipFixture: ghosts), selected: .shelf, notch: notch,
                       to: out.appendingPathComponent("page-shelf-undo-\(state)-\(tag).png"))
            }
        }
        renderDragPreview(to: out.appendingPathComponent("shelf-drag-preview.png"))
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

    private static func nowPage(agenda: TodayAgenda, live: [LiveActivity], privacy: PrivacyUsage = .idle) -> some View {
        NowFixture(column: TodayColumnContent(agenda: agenda, live: live, privacy: privacy, showCalendarPage: {}))
    }

    /// F23 rows: the fullest column, the column with nothing else in it,
    /// a microphone nobody could be named for, and a name list that must
    /// truncate.
    private static func privacyFixtures() -> [(String, TodayAgenda, [LiveActivity], PrivacyUsage)] {
        let both = PrivacyUsage(camera: true, microphone: true, microphoneApps: ["FaceTime", "zoom.us"])
        let camera = PrivacyUsage(camera: true, microphone: false, microphoneApps: [])
        let unnamed = PrivacyUsage(camera: false, microphone: true, microphoneApps: [])
        let many = PrivacyUsage(camera: false, microphone: true,
                                microphoneApps: ["Google Chrome", "Microsoft Teams", "Slack", "zoom.us"])
        return [
            ("full", .items(fixtureEvents()), fixtureLive(), both),
            ("cameraonly", .off, [], camera),
            ("micunnamed", .items(fixtureEvents()), [], unnamed),
            ("manyapps", .items([]), fixtureLive(), many),
        ]
    }

    private struct NowFixture: View {
        @Namespace private var ns
        let column: TodayColumnContent
        var body: some View { NotchHomeView(albumArtNamespace: ns, todayFixture: column) }
    }

    private static func render(_ page: some View, selected: NotchViews, notch: CGSize, seedCalendar: Bool = false, to url: URL) {
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
        if seedCalendar {
            // CalendarView re-reads access on appear; put the fixture back after.
            CalendarManager.shared.calendarAuthorizationStatus = .fullAccess
            CalendarManager.shared.events = fixtureEvents()
        }
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
