//
//  MotionFrameRenderer.swift
//  boringNotch
//
//  Debug-only: `-UmbarRenderMotion <dir>` plays island animations in an
//  off-screen window and writes PNG key frames of them, then quits. There is
//  no screen recording on the build machine, so this is how a motion change
//  is looked at frame by frame. Never compiled into Release.
//
//  Frames: tab-<to>-<notch>-<ms>.png (the tab bar switching to <to> from
//  its left neighbour, or from the right one for the first tab).
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

    // MARK: Player

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

    private static func capture(_ host: NSView, to url: URL) {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
