//
//  MotionFrameRenderer.swift
//  boringNotch
//
//  Debug-only: `-UmbarRenderMotion <dir>` plays island animations in an
//  off-screen window and writes PNG key frames of them, then quits. There is
//  no screen recording on the build machine, so this is how a motion change
//  is looked at frame by frame. Never compiled into Release.
//
//  Frames, at each of `times` after the change:
//    tab-<to>-<notch>-<ms>.png   the tab bar switching to <to> from its left
//                                neighbour (from the right one for the first tab)
//    open-<notch>-<ms>.png       the whole island opening, music playing
//    close-<notch>-<ms>.png      and closing again
//    page-<notch>-<ms>.png       the open panel going Şimdi → Takvim
//    wifi-arm-<ms>.png           the quick toggles row, first tap on Wi-Fi
//    wifi-off-<ms>.png           and the confirming second tap
//    wifi-on-<ms>.png            and the one-tap turn back on
//    undo-chip-in-<ms>.png       the Raf "Taşındı · Geri al" chip arriving
//    undo-chip-out-<ms>.png      and leaving on its close button
//    privacy-<state>-<notch>-<ms>.png  the camera/mic ear arriving on the
//                                closed island (state: both, camera, mic)
//    privacy-caffeinate-<notch>.png    that ear beside Caffeinate's ear
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum MotionFrameRenderer {
    static let times: [Double] = [0, 0.05, 0.1, 0.2, 0.4]

    static func runIfRequested() -> Bool {
        guard let dir = UserDefaults.standard.string(forKey: "UmbarRenderMotion") else { return false }
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for notch in [CGSize(width: 190, height: 37), CGSize(width: 200, height: 32), CGSize(width: 254, height: 45)] {
            renderTabSwitches(notch: notch, out: out)
            renderIsland(notch: notch, out: out)
            renderPrivacyEar(notch: notch, out: out)
        }
        renderWiFiConfirm(out: out)
        renderUndoChip(out: out)
        exit(0)
    }

    // MARK: Tab bar

    private static func renderTabSwitches(notch: CGSize, out: URL) {
        let tag = "\(Int(notch.width))x\(Int(notch.height))"
        let tabs = PanelTab.available
        for (index, tab) in tabs.enumerated() {
            let from = tabs[index == 0 ? 1 : index - 1].view
            let vm = fixtureViewModel(notch: notch)
            vm.open()
            BoringViewCoordinator.shared.currentView = from

            let header = PanelLayout.headerHeight(notchHeight: notch.height)
            let root = BoringHeader()
                .frame(height: header)
                .padding(.horizontal, cornerRadiusInsets.opened.top + PanelLayout.sideInset)
                .frame(width: openNotchSize.width, alignment: .top)
                .background(.black)
                .environmentObject(vm)
                .environment(\.colorScheme, .dark)

            play(root, size: NSSize(width: openNotchSize.width, height: header), change: {
                withAnimation(UmbarMotion.tab()) { BoringViewCoordinator.shared.currentView = tab.view }
            }, name: { ms in out.appendingPathComponent("tab-\(tab.view)-\(tag)-\(ms).png") })
        }
    }

    // MARK: Whole island

    private static func renderIsland(notch: CGSize, out: URL) {
        let tag = "\(Int(notch.width))x\(Int(notch.height))"
        seedMusic()
        let vm = fixtureViewModel(notch: notch)
        vm.notchSize = notch
        BoringViewCoordinator.shared.currentView = .home

        let root = ContentView()
            .environmentObject(vm)
            .frame(width: windowSize.width, height: windowSize.height, alignment: .top)
            .background(Color(white: 0.85))
        let size = NSSize(width: windowSize.width, height: windowSize.height)

        let session = Session(root, size: size)
        session.play(change: { withAnimation(UmbarMotion.open()) { vm.open() } },
                     name: { out.appendingPathComponent("open-\(tag)-\($0).png") })
        for tab in PanelTab.available where tab.view != .home {
            session.play(change: { withAnimation(UmbarMotion.tab()) { BoringViewCoordinator.shared.currentView = tab.view } },
                         name: { out.appendingPathComponent("page-\(tab.view)-\(tag)-\($0).png") })
        }
        session.play(change: {
            BoringViewCoordinator.shared.currentView = .home
            vm.close()
            // close() measures the real screen; keep the fixture notch.
            vm.closedNotchSize = notch
            vm.notchSize = notch
        }, name: { out.appendingPathComponent("close-\(tag)-\($0).png") })
        session.close()
    }

    // MARK: Camera / microphone ear

    /// The real closed island with a fixture usage; nothing is listening to
    /// the hardware in a render run, so the fixture is all it shows.
    private static func renderPrivacyEar(notch: CGSize, out: URL) {
        let tag = "\(Int(notch.width))x\(Int(notch.height))"
        let monitor = PrivacyIndicatorMonitor.shared
        let states: [(String, PrivacyUsage)] = [
            ("both", PrivacyUsage(camera: true, microphone: true, microphoneApps: ["FaceTime"])),
            ("camera", PrivacyUsage(camera: true, microphone: false, microphoneApps: [])),
            ("mic", PrivacyUsage(camera: false, microphone: true, microphoneApps: [])),
        ]
        let vm = fixtureViewModel(notch: notch)
        vm.notchSize = notch
        let root = ContentView()
            .environmentObject(vm)
            .frame(width: windowSize.width, height: 80, alignment: .top)
            .background(Color(white: 0.85))
        let session = Session(root, size: NSSize(width: windowSize.width, height: 80))
        for (state, usage) in states {
            session.play(change: { monitor.showFixture(usage) },
                         name: { out.appendingPathComponent("privacy-\(state)-\(tag)-\($0).png") })
            // Back to no ear between states, so each one is seen arriving.
            monitor.showFixture(.idle)
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        }
        session.close()

        // Caffeinate's ear drawn without CaffeinateService, so the render
        // never takes a power assertion.
        let both = states[0].1
        let pair = UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
            .fill(.black)
            .frame(width: notch.width, height: notch.height)
            .background(alignment: .topTrailing) {
                PrivacyClosedEar(usage: both, height: notch.height, innerWidth: CaffeinateClosedBadge.width(height: notch.height))
                CaffeinateClosedEar(height: notch.height)
            }
            .frame(width: notch.width + 200, height: notch.height + 20, alignment: .top)
            .background(Color(white: 0.85))
            .environment(\.colorScheme, .dark)
        let still = Session(pair, size: NSSize(width: notch.width + 200, height: notch.height + 20))
        capture(still.host, to: out.appendingPathComponent("privacy-caffeinate-\(tag).png"))
        still.close()
    }

    // MARK: Wi-Fi off confirmation

    /// The row on a fake backend, so the render never switches this Mac's
    /// Wi-Fi and every tile has a fixed state.
    private static func renderWiFiConfirm(out: URL) {
        let store = QuickTogglesStore(backend: FixtureToggles(), focusShortcut: { "Rahatsız Etme" })
        let root = QuickTogglesRow(store: store)
            .padding(12)
            .frame(width: openNotchSize.width - 40, alignment: .leading)
            .background(.black)
            .environment(\.colorScheme, .dark)
        let session = Session(root, size: NSSize(width: openNotchSize.width - 40, height: QuickTogglesRow.height + 24))
        for name in ["arm", "off", "on"] {
            session.play(change: { Task { await store.activate(.wifi) } }, name: {
                out.appendingPathComponent("wifi-\(name)-\($0).png")
            })
        }
        session.close()
    }

    // MARK: Shelf undo chip

    /// A model of its own, not the shelf's: the move is made up and its
    /// paths are never touched (nothing calls undo).
    private static func renderUndoChip(out: URL) {
        let model = ShelfMoveUndoModel()
        let width = openNotchSize.width - 40
        let root = ZStack(alignment: .bottom) {
            Color.black
            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 3).padding(.bottom, ShelfMoveUndoChip.height / 2)
            ShelfMoveUndoChip(model: model).padding(.horizontal, 40)
        }
        .frame(width: width, height: 60)
        .environment(\.colorScheme, .dark)
        let session = Session(root, size: NSSize(width: width, height: 60))
        let item = ShelfItem(kind: .file(bookmark: Data()))
        let source = ShelfDragSource(path: "/Users/me/Desktop/teklif.pdf", identity: ShelfFileIdentity(device: 1, inode: 1))
        let destination = URL(fileURLWithPath: "/Users/me/Documents/teklif.pdf")
        session.play(change: {
            model.recordMove(of: item, at: 0, source: source) { .found(destination, identity: ShelfFileIdentity(device: 1, inode: 1)) }
        }, name: { out.appendingPathComponent("undo-chip-in-\($0).png") })
        session.play(change: { model.dismiss(item.id) }, name: { out.appendingPathComponent("undo-chip-out-\($0).png") })
        session.close()
    }

    private final class FixtureToggles: QuickTogglesBackend {
        var onChange: (() -> Void)?
        private var wifi = WiFiPower.on
        func wifiPower() -> WiFiPower { wifi }
        func setWiFiPower(_ on: Bool) throws { wifi = on ? .on : .off }
        var bluetoothConfigured: Bool { true }
        func bluetoothPermission() -> QuickPermission { .granted }
        func requestBluetoothPermission() async -> QuickPermission { .granted }
        func bluetoothPowered() -> Bool? { true }
        func bluetoothDevices() async -> [QuickBluetoothDevice] { [] }
        func connect(deviceID: String) async -> Bool { true }
        func disconnect(deviceID: String) async -> Bool { true }
        var focusConfigured: Bool { true }
        func focusPermission() -> QuickPermission { .granted }
        func requestFocusPermission() async -> QuickPermission { .granted }
        func focusIsActive() -> Bool? { false }
        func runShortcut(named name: String) async throws {}
        func shortcutNames() async -> [String] { [] }
        func isDarkMode() -> Bool { true }
        func setDarkMode(_ dark: Bool) async throws {}
        func open(_ pane: QuickSettingsPane) {}
        func openAppSettings() {}
    }

    /// A view model for an off-screen window. It has no screen, so
    /// `hideOnClosed` (true until the fullscreen detector reports) would make
    /// `effectiveClosedNotchHeight` 0: a 24 pt header and a 10 pt shorter
    /// island than any Mac with a notch shows. Pin it to the fixture notch.
    static func fixtureViewModel(notch: CGSize) -> BoringViewModel {
        let vm = BoringViewModel()
        vm.hideOnClosed = false
        vm.closedNotchSize = notch
        return vm
    }

    private static func seedMusic() {
        let music = MusicManager.shared
        music.albumArt = NSImage(size: NSSize(width: 200, height: 200), flipped: false) { rect in
            NSGradient(colors: [.systemIndigo, .systemPink])?.draw(in: rect, angle: 45)
            return true
        }
        music.songTitle = "Gesaffelstein — Pursuit"
        music.artistName = "Gesaffelstein"
        music.songDuration = 245
        music.elapsedTime = 92
        music.timestampDate = Date()
        music.isPlaying = true
        music.isPlayerIdle = false
    }

    // MARK: Player

    /// One hosted view that several changes are played on in turn.
    @MainActor final class Session {
        let host: NSView
        let window: NSWindow

        init(_ root: some View, size: NSSize) {
            host = NSHostingView(rootView: root)
            host.frame = NSRect(origin: .zero, size: size)
            window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderFrontRegardless()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        }

        func play(change: () -> Void, name: (Int) -> URL) {
            change()
            let start = Date()
            for t in MotionFrameRenderer.islandTimes {
                RunLoop.main.run(until: start.addingTimeInterval(t))
                MotionFrameRenderer.capture(host, to: name(Int(t * 1000)))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }

        func close() { window.orderOut(nil) }
    }

    static let islandTimes: [Double] = [0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.4]


    /// Hosts `root`, lets it settle, applies `change` and captures a frame
    /// at each of `times` after it. The window is ordered in far off screen:
    /// SwiftUI only advances animations for a window that is on the
    /// window list.
    static func play(_ root: some View, size: NSSize, change: () -> Void, name: (Int) -> URL) {
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        change()
        let start = Date()
        for t in times {
            RunLoop.main.run(until: start.addingTimeInterval(t))
            capture(host, to: name(Int(t * 1000)))
        }
        window.orderOut(nil)
    }

    static func capture(_ host: NSView, to url: URL) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
