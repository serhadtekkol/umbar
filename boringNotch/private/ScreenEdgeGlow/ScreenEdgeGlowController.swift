//
//  ScreenEdgeGlowController.swift
//  boringNotch
//
//  One transparent, click-through panel per screen for the screen edge
//  glow: a strip along the top of the screen (ScreenEdgeGlowPolicy.panelFrame),
//  where the bands beside the notch are drawn. Idle, every panel is ordered out and holds no view, so nothing is
//  drawn or scheduled; a glow starting puts one on each screen that no
//  fullscreen app owns.
//
//  The panel sits over the menu bar (its top edge is where the light
//  starts) and under the notch's own window, open menus and alerts. It
//  ignores the mouse, never becomes key, stays put in Mission Control, is
//  on every Space, fullscreen ones included (where it is ordered out by
//  the fullscreen check), and is left out of screenshots and recordings.
//
//  Fullscreen: FullscreenMediaDetector (MacroVisionKit) does not report on
//  macOS 27, so this asks the window server directly: a window of another
//  app that covers the whole screen (ScreenEdgeGlowPolicy.isFullscreen).
//  It is asked when the glow starts, when the Space or the frontmost app
//  changes, and when screens change; never on a timer.
//

import AppKit
import Combine
import Defaults
import SwiftUI

final class ScreenEdgeGlowPanel: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: ScreenEdgeGlowPolicy.panelFrame(screen: screen.frame), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        // Over the menu bar and its extras, under the notch (.mainMenu + 3).
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Light on the bezel is not part of what the user is capturing.
        sharingType = .none
        setAccessibilityElement(false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ScreenEdgeGlowController {
    static let shared = ScreenEdgeGlowController()

    /// Keyed by display UUID, as the notch windows are.
    private var panels: [String: ScreenEdgeGlowPanel] = [:]
    private var drawing = false
    private var recheck: Task<Void, Never>?
    private var observations: [AnyCancellable] = []

    private init() {}

    /// Call once at launch.
    func start() {
        guard observations.isEmpty else { return }
        let model = ScreenEdgeGlowModel.shared
        model.start()
        observations.append(model.$envelope
            .map { $0.state != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in MainActor.assumeIsolated { self?.drawing = on; self?.refresh() } })
        observations.append(NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.screensChanged() } })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observations.append(workspace.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.spaceChanged() } })
        }
    }

    /// Screens came or went, or moved: panels for gone screens are closed,
    /// the rest are fitted again.
    private func screensChanged() {
        let live = Set(NSScreen.screens.compactMap(\.displayUUID))
        for (id, panel) in panels where !live.contains(id) {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
            panels.removeValue(forKey: id)
        }
        refresh()
    }

    /// The window server reports a new Space's windows a moment after the
    /// notification, so this looks now and once more shortly after.
    private func spaceChanged() {
        guard drawing else { return }
        refresh()
        recheck?.cancel()
        recheck = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    private func refresh() {
        guard drawing else {
            recheck?.cancel()
            panels.values.forEach(hide)
            return
        }
        let windows = Self.onScreenWindows()
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let pid = ProcessInfo.processInfo.processIdentifier
        for screen in NSScreen.screens {
            guard let id = screen.displayUUID else { continue }
            let rect = ScreenEdgeGlowPolicy.displayRect(fromAppKit: screen.frame, mainScreenHeight: mainHeight)
            let fullscreen = ScreenEdgeGlowPolicy.isFullscreen(screen: rect, windows: windows, ownPID: pid)
            let panel = panels[id] ?? ScreenEdgeGlowPanel(screen: screen)
            panels[id] = panel
            if ScreenEdgeGlowPolicy.showsWindow(drawing: drawing, fullscreen: fullscreen) {
                show(panel, on: screen)
            } else {
                hide(panel)
            }
        }
    }

    private func show(_ panel: ScreenEdgeGlowPanel, on screen: NSScreen) {
        let frame = ScreenEdgeGlowPolicy.panelFrame(screen: screen.frame)
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        if panel.contentView == nil || !panel.isVisible {
            let view = ScreenEdgeGlowView(screenWidth: screen.frame.width, notchWidth: Self.notchWidth(of: screen))
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: frame.size)
            panel.contentView = host
        }
        panel.orderFrontRegardless()
    }

    /// Ordered out with no view left: nothing observes the model or ticks.
    private func hide(_ panel: ScreenEdgeGlowPanel) {
        guard panel.isVisible || panel.contentView != nil else { return }
        panel.orderOut(nil)
        panel.contentView = nil
    }

    /// The hardware notch's width: what the menu bar leaves between its
    /// two halves. A display without one gets the closed island's width.
    static func notchWidth(of screen: NSScreen) -> CGFloat {
        guard let left = screen.auxiliaryTopLeftArea?.width, let right = screen.auxiliaryTopRightArea?.width else {
            return ScreenEdgeGlowPolicy.fallbackNotchWidth
        }
        let width = screen.frame.width - left - right
        return width > 0 ? width : ScreenEdgeGlowPolicy.fallbackNotchWidth
    }

    /// Bounds, layer and owner of every on-screen window. Needs no screen
    /// recording permission: window names are not read.
    private static func onScreenWindows() -> [ScreenEdgeGlowPolicy.WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
            return .init(bounds: bounds, layer: layer, ownerPID: pid, alpha: alpha)
        }
    }
}
