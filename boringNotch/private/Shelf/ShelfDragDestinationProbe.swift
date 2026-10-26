//
//  ShelfDragDestinationProbe.swift
//  boringNotch
//
//  Finds out whether an outgoing shelf drag is over Finder, so the drag can
//  offer Finder a move and everyone else a copy (BR-3.5). The decision itself
//  is ShelfDragOutPolicy in ShelfDropService.swift; this file only reads the
//  live window list.
//

import AppKit
import CoreGraphics

/// Reads the on-screen window list and asks `ShelfDragOutPolicy` what the
/// pointer is over.
///
/// AppKit tells a drag source only whether the destination is inside or
/// outside the source app, not which app it is, so the window under the
/// pointer is looked up directly. The window list carries owner PIDs and
/// bounds without the Screen Recording permission (only window titles need
/// it), so this adds no prompt.
///
/// Measured on macOS 27.0.1 (Mac mini M4, 17 windows): about 0.4 ms per
/// `CGWindowListCopyWindowInfo` call. AppKit asks for the operation mask as
/// the pointer moves, so this runs at pointer rate during a drag and not at
/// all otherwise.
@MainActor
enum ShelfDragDestinationProbe {
    static func destinationUnderPointer() -> ShelfDragDestination {
        guard let primary = NSScreen.screens.first else { return .other }
        let point = ShelfDragOutPolicy.quartzPoint(
            fromAppKit: NSEvent.mouseLocation,
            primaryScreenHeight: primary.frame.height
        )
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        // Only windows under the pointer can matter, and looking up the owner's
        // bundle ID goes through LaunchServices, so do it for those alone.
        let windows = info.compactMap { window(from: $0, containing: point) }
        return ShelfDragOutPolicy.destination(
            at: point,
            windows: windows,
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
    }

    private static func window(from entry: [String: Any], containing point: CGPoint) -> ShelfDragWindow? {
        guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
              let layer = entry[kCGWindowLayer as String] as? Int,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              bounds.contains(point) else { return nil }
        let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
        return ShelfDragWindow(
            ownerPID: pid,
            ownerBundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            layer: layer,
            bounds: bounds,
            alpha: alpha
        )
    }
}
