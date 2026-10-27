//
//  EyeBreakManager.swift
//  boringNotch
//
//  Glue between EyeBreakEngine and the system: samples idle time, lock/sleep
//  state and the frontmost app, drives the engine, and delivers the reminder
//  (notch panel, or a system notification per AC-14.1 / AC-14.7).
//
//  Public APIs only: CGEventSource idle time, NSWorkspace sleep/wake,
//  distributed screen-lock notifications, IOPMCopyAssertionsByProcess.
//

import AppKit
import Combine
import Defaults
import IOKit.pwr_mgt
import os
import UserNotifications

@MainActor
final class EyeBreakManager: ObservableObject {
    static let shared = EyeBreakManager()

    /// Drives the notch UI. Only changes on visible transitions, never per second.
    @Published private(set) var phase: EyeBreakPhase = .counting

    /// True while the reminder should be drawn in the notch.
    var isPromptingInPanel: Bool {
        if case .prompting = phase { return showInPanel }
        return false
    }

    private var engine = EyeBreakEngine()
    private var timer: Timer?
    private var showInPanel = true
    private var isSuspended = false
    private var cancellables = Set<AnyCancellable>()
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "umbar", category: "EyeBreak")
    private let notificationID = "eyebreak.reminder"
    /// Counting only needs coarse resolution; a prompt needs 1 s to dismiss on time.
    private let idleTickInterval: TimeInterval = 5

    private init() {}

    /// Call once at launch. Cheap when the feature is off: no timer, no observers
    /// beyond the Defaults subscription (AC-1.13 / C1: disabled = no background work).
    func start() {
        guard cancellables.isEmpty else { return }
        Defaults.publisher(.eyeBreakEnabled)
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated { enabled ? self?.activate() : self?.deactivate() }
            }
            .store(in: &cancellables)
        // Re-read durations when the user edits them; a running interval keeps its progress.
        Publishers.MergeMany(
            Defaults.publisher(.eyeBreakIntervalMinutes).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.eyeBreakDurationSeconds).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.eyeBreakIdleResetMinutes).map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in
            MainActor.assumeIsolated { self?.engine.config = Self.currentConfig() }
        }
        .store(in: &cancellables)
    }

    // MARK: - User actions (AC-14.2 / AC-14.3)

    func skip() {
        engine.skip()
        dismissNotification()
        publish()
    }

    func snooze() {
        engine.snooze(now: Date())
        dismissNotification()
        publish()
    }

    // MARK: - Lifecycle

    private func activate() {
        engine = EyeBreakEngine(config: Self.currentConfig())
        log.info("activated: interval=\(self.engine.config.interval, privacy: .public)s break=\(self.engine.config.breakDuration, privacy: .public)s idleReset=\(self.engine.config.idleReset, privacy: .public)s")
        isSuspended = false
        observeSystemState()
        scheduleTimer(interval: idleTickInterval)
        publish()
    }

    private func deactivate() {
        log.info("deactivated")
        timer?.invalidate()
        timer = nil
        removeObservers()
        dismissNotification()
        engine.reset()
        publish()
    }

    private static func currentConfig() -> EyeBreakConfig {
        var cfg = EyeBreakConfig()
        cfg.interval = TimeInterval(max(1, Defaults[.eyeBreakIntervalMinutes]) * 60)
        cfg.breakDuration = TimeInterval(max(1, Defaults[.eyeBreakDurationSeconds]))
        cfg.idleReset = TimeInterval(max(1, Defaults[.eyeBreakIdleResetMinutes]) * 60)
        // Verification-only overrides (see EyeBreakDefaults.swift); 0 in production.
        if Defaults[.eyeBreakDebugIntervalSeconds] > 0 {
            cfg.interval = TimeInterval(Defaults[.eyeBreakDebugIntervalSeconds])
        }
        if Defaults[.eyeBreakDebugIdleResetSeconds] > 0 {
            cfg.idleReset = TimeInterval(Defaults[.eyeBreakDebugIdleResetSeconds])
        }
        return cfg
    }

    // MARK: - Ticking

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = interval * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let input = EyeBreakInputs(
            now: Date(),
            idleSeconds: Self.secondsSinceLastInput(),
            isSuspended: isSuspended,
            isDeferred: Defaults[.eyeBreakDeferDuringVideo] && Self.frontmostAppKeepsDisplayAwake()
                || FocusTimerService.shared.defersEyeBreaks
        )
        if engine.tick(input) { publish() }
    }

    /// Mirrors engine state to observers and adjusts tick rate / delivery.
    private func publish() {
        let new = engine.phase
        let old = phase
        phase = new
        if new != old { log.info("phase \(String(describing: old), privacy: .public) -> \(String(describing: new), privacy: .public)") }
        guard timer != nil else { return }
        let wasPrompting = old.isPrompting
        if new.isPrompting && !wasPrompting {
            scheduleTimer(interval: 1)
            deliver()
        } else if !new.isPrompting && wasPrompting {
            scheduleTimer(interval: idleTickInterval)
            dismissNotification()
        }
    }

    // MARK: - Delivery (AC-14.1, AC-14.7)

    private func deliver() {
        showInPanel = true
        guard Defaults[.eyeBreakDelivery] == .notification else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    // AC-14.7: permission denied -> keep showing it in the panel.
                    self.showInPanel = true
                    self.objectWillChange.send()
                    return
                }
                self.showInPanel = false
                self.objectWillChange.send()
                let content = UNMutableNotificationContent()
                content.title = String(localized: "eyebreak.title", defaultValue: "Look 20 feet away")
                content.body = String(
                    localized: "eyebreak.notification.body",
                    defaultValue: "Rest your eyes for \(Int(self.engine.config.breakDuration)) seconds.")
                content.sound = nil  // Never audible.
                try? await center.add(UNNotificationRequest(identifier: self.notificationID, content: content, trigger: nil))
            }
        }
        // Until authorization resolves the panel stays visible, so the reminder is never lost.
    }

    private func dismissNotification() {
        guard Defaults[.eyeBreakDelivery] == .notification else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [notificationID])
    }

    // MARK: - System signals

    /// Seconds since the last keyboard or mouse input, any source.
    static func secondsSinceLastInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
    }

    /// AC-14.5 heuristic: a frontmost app that holds a "prevent display sleep"
    /// assertion is playing video or presenting/screen-sharing (browsers, QuickTime,
    /// Keynote, Zoom and Teams all take it). Reading assertions needs no permission.
    /// Limitation: an app that plays video without the assertion is not detected.
    static func frontmostAppKeepsDisplayAwake() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return false }
        var byPID: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byPID) == kIOReturnSuccess,
              let dict = byPID?.takeRetainedValue() as? [Int: [[String: Any]]],
              let assertions = dict[Int(front.processIdentifier)]
        else { return false }
        return assertions.contains {
            ($0["AssertType"] as? String) == "PreventUserIdleDisplaySleep"
                || ($0["AssertType"] as? String) == "NoDisplaySleepAssertion"
        }
    }

    private func observeSystemState() {
        guard observers.isEmpty else { return }
        let ws = NSWorkspace.shared.notificationCenter
        let dist = DistributedNotificationCenter.default()
        func add(_ center: NotificationCenter, _ name: Notification.Name, suspended: Bool) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isSuspended = suspended
                    if suspended { self?.tick() }
                }
            }
            observers.append((center, token))
        }
        // AC-14.4: any of these means the user is away from the screen.
        add(ws, NSWorkspace.willSleepNotification, suspended: true)
        add(ws, NSWorkspace.screensDidSleepNotification, suspended: true)
        add(dist, Notification.Name("com.apple.screenIsLocked"), suspended: true)
        add(ws, NSWorkspace.didWakeNotification, suspended: false)
        add(ws, NSWorkspace.screensDidWakeNotification, suspended: false)
        add(dist, Notification.Name("com.apple.screenIsUnlocked"), suspended: false)
    }

    private func removeObservers() {
        observers.forEach { $0.center.removeObserver($0.token) }
        observers.removeAll()
    }
}

private extension EyeBreakPhase {
    var isPrompting: Bool {
        if case .prompting = self { return true }
        return false
    }
}
