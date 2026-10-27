//
//  PanelKeyController.swift
//  boringNotch
//
//  Gives the notch panel the keyboard when it is asked for, and hands it
//  back when the panel closes (Can B1, #98; AC-1.16–AC-1.21). The rules
//  are in PanelKeyPolicy; this type applies them to the window.
//

import AppKit
import Combine
import os

extension Notification.Name {
    /// Posted when a keyboard opening (shortcut, menu) made the panel key.
    /// The tab group takes focus on it, so VoiceOver reads the selected tab
    /// (AC-1.18, AC-1.21). `object` is the panel's BoringViewModel.
    static let panelDidTakeKeyboard = Notification.Name("umbar.panelDidTakeKeyboard")
}

/// Owns "which panel holds the keyboard". At most one panel does at a time,
/// even with a notch on every display: there is one keyboard.
///
/// Main-thread only. Every entry point is an AppKit or SwiftUI callback.
@MainActor
final class PanelKeyController {
    static let shared = PanelKeyController()

    private let log = Logger(subsystem: "umbar", category: "PanelKey")

    private weak var keyWindow: BoringNotchSkyLightWindow?
    /// The app that had the keyboard before the panel took it; it gets it
    /// back on close (AC-1.18, AC-1.21).
    private var previousApp: NSRunningApplication?
    private var closeObserver: AnyCancellable?
    private var resignObserver: Any?

    private init() {}

    /// Whether `viewModel`'s panel holds the keyboard. ContentView asks this
    /// before folding the panel on pointer exit (AC-1.4 R1.2 exception).
    func isKey(_ viewModel: BoringViewModel) -> Bool {
        keyWindow?.viewModel === viewModel
    }

    /// Applies the panel shortcut to `window` (AC-1.18).
    func handleShortcut(for window: BoringNotchSkyLightWindow) {
        guard let viewModel = window.viewModel else { return }
        let action = PanelKeyPolicy.shortcutAction(
            isOpen: viewModel.notchState == .open,
            isKey: isKey(viewModel)
        )
        switch action {
        case .openWithKeyboard:
            open(window, from: .shortcut)
        case .takeKeyboard:
            takeKeyboard(window, focusTabs: true)
        case .close:
            close(window)
        }
    }

    /// Opens the panel from an explicit keyboard request: the shortcut or
    /// "Open panel" in the menu bar extra.
    func open(_ window: BoringNotchSkyLightWindow, from source: PanelOpenSource) {
        guard let viewModel = window.viewModel else { return }
        if viewModel.notchState != .open {
            viewModel.open()
        }
        if PanelKeyPolicy.takesKeyboard(openedBy: source) {
            takeKeyboard(window, focusTabs: true)
        }
    }

    /// Makes the panel key. A text-field click (AC-1.17) does not move focus
    /// to the tabs; the click itself puts it in the field.
    func takeKeyboard(_ window: BoringNotchSkyLightWindow, focusTabs: Bool) {
        if let current = keyWindow, current !== window {
            release(current)
        }
        if keyWindow !== window {
            // Captured before makeKey: afterwards the frontmost app may be us.
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            keyWindow = window
            observeClose(of: window)
        }
        window.acceptsKeyboard = true
        window.makeKeyAndOrderFront(nil)
        if !window.isKeyWindow {
            // A non-activating panel should become key without umbar becoming
            // the active app; if the window server refused, activate umbar so
            // the keyboard reaches the panel at all. release() then gives the
            // keyboard back to previousApp.
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        log.debug("panel took keyboard: isKeyWindow=\(window.isKeyWindow, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)")
        if focusTabs, let viewModel = window.viewModel {
            NotificationCenter.default.post(name: .panelDidTakeKeyboard, object: viewModel)
        }
    }

    /// Closes the panel (Esc, outside click, shortcut again). Releasing the
    /// keyboard follows from the close through `observeClose`.
    func close(_ window: BoringNotchSkyLightWindow) {
        window.viewModel?.close()
        // vm.close() refuses while a share sheet is up; the panel then stays
        // open and keeps the keyboard, which is what the sheet needs.
        if window.viewModel?.notchState == .closed {
            release(window)
        }
    }

    // MARK: - Private

    private func observeClose(of window: BoringNotchSkyLightWindow) {
        // Any close releases the keyboard, not only the ones that go through
        // close(_:): a swipe up, a drop that folds the shelf, a screen change.
        closeObserver = window.viewModel?.$notchState
            .dropFirst()
            .filter { $0 == .closed }
            .sink { [weak self, weak window] _ in
                // notchState is only ever written on the main thread.
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.release(window)
                }
            }

        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let window = note.object as? BoringNotchSkyLightWindow else { return }
                self?.panelDidResignKey(window)
            }
        }
    }

    private func panelDidResignKey(_ window: BoringNotchSkyLightWindow) {
        // The window that took the keyboard is only known once this
        // notification has returned.
        Task { @MainActor [weak self, weak window] in
            guard let self, let window, self.keyWindow === window else { return }
            let isChild = NSApp.keyWindow.map { $0.parent === window } ?? false
            if PanelKeyPolicy.closesOnResignKey(wasKey: true, newKeyWindowIsPanelChild: isChild) {
                self.log.debug("panel lost keyboard to another window; closing")
                self.close(window)
            }
        }
    }

    /// Hands the keyboard back. Idempotent.
    private func release(_ window: BoringNotchSkyLightWindow) {
        guard keyWindow === window else { return }
        keyWindow = nil
        closeObserver = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        window.acceptsKeyboard = false

        if window.isKeyWindow {
            // A non-activating panel stays key after canBecomeKey turns false;
            // AppKit has no public "resign" call. Re-ordering the window lets
            // the window server pass key back to the active app's window. Both
            // calls run in one run-loop turn, before the next frame is drawn,
            // so the compact notch should not flicker (checked by eye, #98 H-list).
            window.orderOut(nil)
            window.orderFrontRegardless()
        }
        if NSApp.isActive, let previousApp, !previousApp.isTerminated {
            // Only if something activated umbar on the way (a menu choice can):
            // the previous app gets the keyboard back (AC-1.18, AC-1.21).
            previousApp.activate()
        }
        log.debug("panel released keyboard: isKeyWindow=\(window.isKeyWindow, privacy: .public) appActive=\(NSApp.isActive, privacy: .public)")
        previousApp = nil
    }
}
