//
//  BoringNotchSkyLightWindow.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-20.
//

import Cocoa
import Defaults
import Combine

/// The notch panel window.
///
/// The name is upstream's: it used to move itself into a private SkyLight
/// space to render on the lock screen. That path was removed with the lock
/// screen feature (K6); the name is kept to ease upstream merges.
///
/// Keyboard model (Can B1, #98; AC-1.16–AC-1.19): the panel is a
/// non-activating panel that becomes key only when asked to, through
/// `PanelKeyController`. A hover-opened panel never takes the keyboard, so
/// ⌘2 still reaches Safari. While key, the window itself handles Esc and
/// ⌘1…⌘5 before anything inside it can, so those keys never leak to the
/// app behind the panel and a text field cannot swallow Esc.
class BoringNotchSkyLightWindow: NSPanel {
    /// The model of the notch this window draws. Set once, by the app
    /// delegate, when the window is created.
    weak var viewModel: BoringViewModel?

    /// Whether the panel may become key. Only `PanelKeyController` sets it.
    var acceptsKeyboard = false

    /// ⌘<n> while key. The page may not have a view yet (AC-1.19); the key
    /// is consumed either way.
    var onSelectPage: ((PanelPage) -> Void)?

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )

        configureWindow()
        setupObservers()
    }

    private func configureWindow() {
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false

        // Force dark appearance regardless of system setting
        appearance = NSAppearance(named: .darkAqua)

        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]

        // Apply initial sharing type setting
        updateSharingType()
    }

    private func setupObservers() {
        // Listen for changes to the hideFromScreenRecording setting
        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in
                self?.updateSharingType()
            }
            .store(in: &observers)
    }

    private func updateSharingType() {
        if Defaults[.hideFromScreenRecording] {
            sharingType = .none
        } else {
            sharingType = .readWrite
        }
    }

    private var observers: Set<AnyCancellable> = []

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where !isKeyWindow && hitsEditableText(event):
            // AC-1.17: a click in a text field (notes, city) gives the panel
            // the keyboard. It has to happen before the click is delivered,
            // or the field cannot become first responder in a non-key window.
            PanelKeyController.shared.takeKeyboard(self, focusTabs: false)
        case .keyDown where isKeyWindow:
            if handlePanelKey(event) { return }
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Esc and ⌘1…⌘5 inside a key panel. Returns true when the key was used.
    private func handlePanelKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if PanelKeyPolicy.isClose(keyCode: event.keyCode, noModifiers: modifiers.isEmpty) {
            PanelKeyController.shared.close(self)
            return true
        }
        if let page = PanelKeyPolicy.page(forKeyCode: event.keyCode, commandOnly: modifiers == .command) {
            onSelectPage?(page)
            return true
        }
        return false
    }

    private func hitsEditableText(_ event: NSEvent) -> Bool {
        // hitTest wants the point in the content view's superview, which for
        // a window's content view is the window's own coordinate space.
        guard let contentView,
              let hit = contentView.hitTest(contentView.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
        else { return false }
        var view: NSView? = hit
        while let current = view, current !== contentView {
            if let field = current as? NSTextField, field.isEditable { return true }
            if let text = current as? NSTextView, text.isEditable { return true }
            view = current.superview
        }
        return false
    }
}
