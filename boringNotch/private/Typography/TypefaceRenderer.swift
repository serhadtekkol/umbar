//
//  TypefaceRenderer.swift
//  boringNotch
//
//  Debug-only: `-UmbarRenderTypefaces <dir>` draws the text the typeface
//  choice reaches, in the typeface of this run, writes PNGs and quits. Pick
//  the face with the argument domain (nothing is written to the user's
//  defaults), one run per face:
//
//    -UmbarRenderTypefaces /tmp/faces -umbarTypeface dotMatrix -AppleLanguages '(tr)'
//
//  Frames, per notch size:
//    typeface-<face>-songpeek-<notch>.png  the closed island, song name under it
//    typeface-<face>-timer-<notch>.png     the closed island's timer ear
//    typeface-<face>-now-<notch>.png       the open panel on Şimdi
//    typeface-<face>-settings-<light|dark>.png  the Settings rows: typeface
//                                          picker and preview, sneak peek duration
//  Captured at 2×. Never compiled into Release.
//

#if DEBUG
import AppKit
import Defaults
import SwiftUI

@MainActor
enum TypefaceRenderer {
    static func runIfRequested() -> Bool {
        guard let dir = UserDefaults.standard.string(forKey: "UmbarRenderTypefaces") else { return false }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let face = Defaults[.umbarTypeface].rawValue
        for notch in [CGSize(width: 190, height: 37), CGSize(width: 200, height: 32), CGSize(width: 254, height: 45)] {
            let tag = "\(Int(notch.width))x\(Int(notch.height))"
            renderSongPeek(notch: notch, to: out.appendingPathComponent("typeface-\(face)-songpeek-\(tag).png"))
            renderTimerEar(notch: notch, to: out.appendingPathComponent("typeface-\(face)-timer-\(tag).png"))
            renderNow(notch: notch, to: out.appendingPathComponent("typeface-\(face)-now-\(tag).png"))
        }
        for scheme in [ColorScheme.light, .dark] {
            renderSettings(scheme, to: out.appendingPathComponent("typeface-\(face)-settings-\(scheme == .dark ? "dark" : "light").png"))
        }
        exit(0)
    }

    /// Turkish title and artist: every letter a face must have (ğ ş ı İ ç ö ü).
    private static func seedMusic() {
        let music = MusicManager.shared
        music.albumArt = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
            NSGradient(colors: [.systemIndigo, .systemPink])?.draw(in: rect, angle: 45)
            return true
        }
        music.songTitle = "Gözlerin İstanbul'u Dinliyor"
        music.artistName = "Çağrı Şıklar"
        music.songDuration = 245
        music.elapsedTime = 92
        music.timestampDate = Date()
        music.playbackRate = 0
        music.isPlaying = true
        music.isPlayerIdle = false
    }

    // MARK: Closed island

    private static func renderSongPeek(notch: CGSize, to url: URL) {
        seedMusic()
        let vm = MotionFrameRenderer.fixtureViewModel(notch: notch)
        vm.notchSize = notch
        BoringViewCoordinator.shared.currentView = .home
        let root = ContentView()
            .environmentObject(vm)
            .frame(width: windowSize.width, height: 90, alignment: .top)
            .background(Color(white: 0.85))
        let session = MotionFrameRenderer.Session(root, size: NSSize(width: windowSize.width, height: 90))
        // The real player may have reported while the window settled.
        seedMusic()
        BoringViewCoordinator.shared.toggleSneakPeek(status: true, type: .music, duration: 10)
        // The marquee waits 1 s before it scrolls: capture before it moves.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        capture(session.host, to: url)
        BoringViewCoordinator.shared.toggleSneakPeek(status: false, type: .music)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        session.close()
    }

    /// The ear alone on a notch, an hour-long stopwatch: the widest clock.
    private static func renderTimerEar(notch: CGSize, to url: URL) {
        var watch = TimerEngine()
        watch.startStopwatch(now: Date().addingTimeInterval(-3_725))
        let ear = TimerClosedEar(state: watch.state, alerting: false, height: notch.height)
        let root = UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
            .fill(.black)
            .frame(width: notch.width, height: notch.height)
            .background(alignment: .topLeading) { ear }
            .frame(width: notch.width + 200, height: notch.height + 20, alignment: .top)
            .background(Color(white: 0.85))
            .umbarTypefaceFromDefaults()
            .environment(\.colorScheme, .dark)
        let session = MotionFrameRenderer.Session(root, size: NSSize(width: notch.width + 200, height: notch.height + 20))
        capture(session.host, to: url)
        session.close()
    }

    // MARK: Settings

    private struct SettingsFixture: View {
        @State private var seconds = 4.5
        var body: some View {
            Form {
                TypefaceSettingsSection()
                Section { SongPeekDurationRow(seconds: $seconds) }
                Section { SongPeekDurationRow(seconds: $seconds).disabled(true) }
            }
            .formStyle(.grouped)
        }
    }

    private static func renderSettings(_ scheme: ColorScheme, to url: URL) {
        let size = NSSize(width: 520, height: 460)
        let root = SettingsFixture()
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, scheme)
        let session = MotionFrameRenderer.Session(root, size: size)
        session.window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        capture(session.host, to: url)
        session.close()
    }

    // MARK: Open panel

    private struct NowFixture: View {
        @Namespace private var ns
        let column: TodayColumnContent
        var body: some View { NotchHomeView(albumArtNamespace: ns, todayFixture: column) }
    }

    /// Mirrors PanelPageRenderer's open-panel frame: header, page, insets.
    private static func renderNow(notch: CGSize, to url: URL) {
        let vm = MotionFrameRenderer.fixtureViewModel(notch: notch)
        vm.open()
        BoringViewCoordinator.shared.currentView = .home
        let column = TodayColumnContent(agenda: .items(fixtureEvents()), live: [], privacy: .idle, showCalendarPage: {})
        let root = VStack(alignment: .leading, spacing: PanelLayout.headerSpacing) {
            BoringHeader()
                .frame(height: PanelLayout.headerHeight(notchHeight: notch.height))
            NowFixture(column: column)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, cornerRadiusInsets.opened.top + PanelLayout.sideInset)
        .padding(.bottom, PanelLayout.bottomInset)
        .frame(width: openNotchSize.width, height: openNotchSize.height, alignment: .top)
        .background(.black)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: cornerRadiusInsets.opened.bottom,
                                          bottomTrailingRadius: cornerRadiusInsets.opened.bottom))
        .padding(10)
        .background(Color(white: 0.85))
        .umbarTypefaceFromDefaults()
        .environmentObject(vm)
        .environment(\.colorScheme, .dark)

        let session = MotionFrameRenderer.Session(
            root, size: NSSize(width: openNotchSize.width + 20, height: openNotchSize.height + 20))
        // After onAppear: put the fixture track back over whatever the player reported.
        seedMusic()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        capture(session.host, to: url)
        session.close()
    }

    /// At 2×, as on a Retina screen: at 1× a dot-matrix face's dots blur
    /// into strokes and the render says nothing about how it reads.
    private static func capture(_ host: NSView, to url: URL) {
        let bounds = host.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func fixtureEvents() -> [EventModel] {
        let now = Date()
        let work = CalendarModel(id: "w", account: "", title: "İş", color: .systemBlue, isSubscribed: false, isReminder: false)
        func event(_ id: String, _ title: String, _ start: TimeInterval) -> EventModel {
            EventModel(id: id, start: now.addingTimeInterval(start), end: now.addingTimeInterval(start + 1800),
                       title: title, location: nil, notes: nil, url: nil, isAllDay: false, type: .event(.accepted),
                       calendar: work, participants: [], timeZone: nil, hasRecurrenceRules: false, priority: nil)
        }
        return [
            event("e1", "Tasarım incelemesi", 3600),
            event("e2", "Diş hekimi", 9000),
        ]
    }
}
#endif
