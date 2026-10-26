//
//  ClipboardMonitorController.swift
//  umbar
//
//  App-side owner of the spike A2 ClipboardMonitor: starts and stops it
//  with `Defaults[.clipboardMonitorEnabled]`. Separate from
//  ClipboardMonitor.swift so that file stays free of app dependencies and
//  can be compiled by the Tools/PasteboardProbe harness.
//

import AppKit
import Combine
import Defaults
import os

/// Owns the single ClipboardMonitor instance for the app.
///
/// Prototype scope only: it records counts and the permission state, never
/// item contents. History storage, dedupe (BR-4.2) and the widget are #16/#17.
@MainActor
final class ClipboardMonitorController: ObservableObject {
    static let shared = ClipboardMonitorController()

    /// True when the last text change could not be read because the user
    /// has not set "Allow" under Privacy & Security > Paste from Other Apps.
    /// Drives the AC-4.8 "permission required" state.
    @Published private(set) var permissionRequired = false
    /// Number of text items captured since launch (content is not kept).
    @Published private(set) var capturedCount = 0

    private var monitor: ClipboardMonitor?
    private var enabledObservation: AnyCancellable?
    private let log = Logger(subsystem: "umbar", category: "ClipboardMonitor")

    private init() {}

    /// Begins following the feature flag. Call once at launch; idempotent.
    func activate() {
        guard enabledObservation == nil else { return }
        // Defaults.publisher emits the current value first, so this also
        // applies the persisted state at launch.
        enabledObservation = Defaults.publisher(.clipboardMonitorEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                MainActor.assumeIsolated { self?.setEnabled(change.newValue) }
            }
    }

    private func setEnabled(_ enabled: Bool) {
        if enabled {
            guard monitor == nil else { return }
            let m = ClipboardMonitor { [weak self] event in self?.handle(event) }
            monitor = m
            m.start()
            log.info("clipboard monitor started")
        } else {
            monitor?.stop()
            monitor = nil
            log.info("clipboard monitor stopped")
        }
    }

    private func handle(_ event: ClipboardEvent) {
        switch event {
        case .captured:
            capturedCount += 1
            permissionRequired = false
        case .permissionRequired:
            permissionRequired = true
        case .skippedSensitive, .skippedNonText:
            break
        }
    }
}
