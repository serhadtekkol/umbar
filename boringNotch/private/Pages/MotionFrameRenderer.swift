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
        for notch in [CGSize(width: 190, height: 37), CGSize(width: 200, height: 32)] {
            renderTabSwitches(notch: notch, out: out)
            renderIsland(notch: notch, out: out)
        }
        exit(0)
    }

    // MARK: Tab bar

    private static func renderTabSwitches(notch: CGSize, out: URL) {
        let tag = "\(Int(notch.width))x\(Int(notch.height))"
        let tabs = PanelTab.available
        for (index, tab) in tabs.enumerated() {
            let from = tabs[index == 0 ? 1 : index - 1].view
            let vm = BoringViewModel()
            vm.open()
            vm.closedNotchSize = notch
            BoringViewCoordinator.shared.currentView = from

            let root = BoringHeader()
                .frame(height: max(24, notch.height))
                .padding(.horizontal, cornerRadiusInsets.opened.top + 12)
                .frame(width: openNotchSize.width, alignment: .top)
                .background(.black)
                .environmentObject(vm)
                .environment(\.colorScheme, .dark)

            play(root, size: NSSize(width: openNotchSize.width, height: max(24, notch.height)), change: {
                withAnimation(UmbarMotion.tab()) { BoringViewCoordinator.shared.currentView = tab.view }
            }, name: { ms in out.appendingPathComponent("tab-\(tab.view)-\(tag)-\(ms).png") })
        }
    }

    // MARK: Whole island

    private static func renderIsland(notch: CGSize, out: URL) {
        let tag = "\(Int(notch.width))x\(Int(notch.height))"
        seedMusic()
        let vm = BoringViewModel()
        vm.closedNotchSize = notch
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
