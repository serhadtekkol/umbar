//
//  NotchClickThrough.swift
//  boringNotch
//
//  The notch window keeps the open panel's size while the island is closed,
//  and the empty area below the closed island swallowed clicks meant for the
//  app behind it. While closed, the window ignores the mouse whenever the
//  pointer is away from the island's strip, so those clicks pass through.
//

import AppKit

enum NotchClickThroughPolicy {
    /// How far beside the closed island the window still listens, so the
    /// ears (timer, network, privacy badges) keep their hover.
    static let earMargin: CGFloat = 160

    /// `closedRect` and `pointer` are in AppKit screen space.
    static func passesThrough(isOpen: Bool, closedRect: CGRect?, pointer: CGPoint, buttonsDown: Bool) -> Bool {
        // A drag carrying a file onto the notch must reach the drop detector.
        guard !isOpen, !buttonsDown, let closedRect, !closedRect.isEmpty else { return false }
        return !closedRect.insetBy(dx: -earMargin, dy: 0).contains(pointer)
    }
}

/// Event-driven (mouse-moved monitors), so nothing runs while the pointer
/// is still. The eye-break banner runs its own click-through while shown;
/// this one stands aside then.
@MainActor
final class NotchClickThrough {
    private weak var window: NSWindow?
    private var monitors: [Any] = []
    private var isOpen = false
    private var closedRect: CGRect?

    func update(window: NSWindow?, isOpen: Bool, closedRect: CGRect?) {
        if let window { self.window = window }
        self.isOpen = isOpen
        self.closedRect = closedRect
        if monitors.isEmpty { start() }
        apply()
    }

    private func start() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .leftMouseUp]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.apply() }
            return event
        }) { monitors.append(local) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let window, !EyeBreakClickThrough.isActive { window.ignoresMouseEvents = false }
    }

    private func apply() {
        guard let window, !EyeBreakClickThrough.isActive else { return }
        let ignore = NotchClickThroughPolicy.passesThrough(
            isOpen: isOpen,
            closedRect: closedRect,
            pointer: NSEvent.mouseLocation,
            buttonsDown: NSEvent.pressedMouseButtons != 0
        )
        if window.ignoresMouseEvents != ignore { window.ignoresMouseEvents = ignore }
    }
}
