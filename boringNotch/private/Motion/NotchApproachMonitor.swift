//
//  NotchApproachMonitor.swift
//  boringNotch
//
//  Reports NotchApproachPolicy's value while the island is closed. Event
//  driven (mouse-moved monitors, like NotchClickThrough): nothing runs while
//  the pointer is still, and nothing runs at all while the panel is open.
//

import AppKit

@MainActor
final class NotchApproachMonitor {
    private var monitors: [Any] = []
    private var rect: CGRect?
    private var last: CGFloat = 0
    private var onChange: ((CGFloat) -> Void)?

    /// `rect` is the closed island in AppKit screen space; nil stops the
    /// monitor and reports 0.
    func update(closedRect rect: CGRect?, onChange: @escaping (CGFloat) -> Void) {
        self.onChange = onChange
        self.rect = rect
        if rect == nil {
            stop()
            return
        }
        if monitors.isEmpty { start() }
        apply()
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        report(0)
    }

    private func start() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.apply() }
            return event
        }) { monitors.append(local) }
    }

    private func apply() {
        guard let rect else { return }
        report(NotchApproachPolicy.approach(
            to: rect,
            pointer: NSEvent.mouseLocation,
            reach: UmbarMotion.hoverApproachReach,
            steps: UmbarMotion.hoverApproachSteps
        ))
    }

    private func report(_ value: CGFloat) {
        guard value != last else { return }
        last = value
        onChange?(value)
    }
}
