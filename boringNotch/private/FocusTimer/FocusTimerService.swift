//
//  FocusTimerService.swift
//  boringNotch
//
//  F18: owns the engine, the 1 s clock, persistence, the banner and the
//  integrations (eye break deferral, optional Shortcuts). No sound anywhere.
//

import AppKit
import Combine
import Defaults
import Foundation
import os

enum FocusBanner: Equatable {
    /// Focus finished; a break of `phase` is now running.
    case breakStarted(FocusPhase)
    /// The break ran out; ready for the next focus session.
    case breakEnded
}

@MainActor
final class FocusTimerService: ObservableObject {
    static let shared = FocusTimerService()

    /// Changes on transitions and user actions only; per-second display is
    /// drawn by TimelineView in the views.
    @Published private(set) var state: FocusTimerState
    @Published private(set) var banner: FocusBanner?

    var isShowingBanner: Bool { banner != nil }

    /// Read by EyeBreakManager: no eye-break prompt while a focus session is
    /// counting down. The focus break that follows is the rest.
    var defersEyeBreaks: Bool { state.phase == .focus && state.isRunning }

    private var engine: FocusTimerEngine
    private var clock: Timer?
    private var bannerTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var wakeObserver: NSObjectProtocol?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "umbar", category: "FocusTimer")
    private static let bannerDuration: TimeInterval = 20
    /// A break that ended longer ago than this (sleep, restart) is not worth a banner.
    private static let staleBannerAge: TimeInterval = 60

    private init() {
        let saved = Defaults[.focusTimerState]
            .flatMap { try? JSONDecoder().decode(FocusTimerState.self, from: $0) } ?? .idle
        engine = FocusTimerEngine(state: saved, config: Self.currentConfig())
        state = saved
        // Catches a phase that ended while the app was not running.
        handle(engine.tick(now: Date()), previous: saved.phase)
        state = engine.state
        persist()
        scheduleClock()

        Defaults.publisher(.focusTimerEnabled, options: [])
            .sink { [weak self] change in
                guard !change.newValue else { return }
                Task { @MainActor in self?.stop() }
            }
            .store(in: &cancellables)
        Publishers.MergeMany(
            Defaults.publisher(.focusTimerLongBreakMinutes, options: []).map { _ in () }.eraseToAnyPublisher(),
            Defaults.publisher(.focusTimerSessionsBeforeLongBreak, options: []).map { _ in () }.eraseToAnyPublisher()
        )
        .sink { [weak self] in
            Task { @MainActor in self?.engine.config = Self.currentConfig() }
        }
        .store(in: &cancellables)

        // Timer.fire is not guaranteed on the first tick after wake; check explicitly.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: - Actions

    func start(_ preset: FocusPreset) {
        mutate { $0.start(preset: preset, now: Date()) }
    }

    func startCustom() {
        start(FocusPreset(
            focusMinutes: Defaults[.focusTimerCustomFocusMinutes],
            breakMinutes: Defaults[.focusTimerCustomBreakMinutes]))
    }

    /// Next focus session of the current cycle (keeps preset and session count).
    func startNextFocus() {
        mutate { $0.startNextFocus(now: Date()) }
    }

    func pause() { mutate { $0.pause(now: Date()) } }
    func resume() { mutate { $0.resume(now: Date()) } }
    func skip() { mutate { $0.skip(now: Date()) } }

    func stop() {
        guard !state.isIdle else { return }
        mutate { $0.stop() }
    }

    func dismissBanner() {
        bannerTimer?.invalidate()
        bannerTimer = nil
        banner = nil
    }

    // MARK: - Internals

    private func tick() {
        let before = engine.state.phase
        let event = engine.tick(now: Date())
        guard event != nil else { return }
        handle(event, previous: before)
        publish()
    }

    /// Single funnel for every state change: runs the mutation, then reacts to
    /// the phase transition it caused (Shortcuts, eye break, banner).
    private func mutate(_ change: (inout FocusTimerEngine) -> Void) {
        let before = engine.state.phase
        change(&engine)
        handle(nil, previous: before)
        publish()
    }

    private func publish() {
        state = engine.state
        persist()
        scheduleClock()
    }

    private func handle(_ event: FocusEvent?, previous: FocusPhase?) {
        let now = engine.state.phase

        if previous != .focus, now == .focus { runShortcut(Defaults[.focusTimerStartShortcut]) }
        if previous == .focus, now != .focus { runShortcut(Defaults[.focusTimerStopShortcut]) }

        // The break is the eye rest: restart the 20-20-20 interval so a reminder
        // that was held back during focus does not fire the moment the break ends.
        if let now, now.isBreak, previous != now { EyeBreakManager.shared.skip() }

        switch event {
        case .focusCompleted(let next):
            show(.breakStarted(next))
        case .breakCompleted(let lateness):
            if lateness < Self.staleBannerAge { show(.breakEnded) }
        case nil:
            // A user action supersedes whatever the banner was announcing.
            if banner != nil { dismissBanner() }
        }
    }

    private func show(_ new: FocusBanner) {
        banner = new
        bannerTimer?.invalidate()
        let t = Timer(timeInterval: Self.bannerDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissBanner() }
        }
        RunLoop.main.add(t, forMode: .common)
        bannerTimer = t
    }

    /// The clock only runs while a phase counts down: idle and paused cost nothing.
    private func scheduleClock() {
        if state.isRunning {
            guard clock == nil else { return }
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            t.tolerance = 0.2
            RunLoop.main.add(t, forMode: .common)
            clock = t
        } else {
            clock?.invalidate()
            clock = nil
        }
    }

    private func persist() {
        Defaults[.focusTimerState] = state.isIdle && state.completedFocus == 0
            ? nil
            : try? JSONEncoder().encode(state)
    }

    private static func currentConfig() -> FocusConfig {
        var cfg = FocusConfig()
        cfg.longBreakMinutes = max(1, Defaults[.focusTimerLongBreakMinutes])
        cfg.sessionsBeforeLongBreak = max(1, Defaults[.focusTimerSessionsBeforeLongBreak])
        if Defaults[.focusTimerDebugMinuteSeconds] > 0 {
            cfg.minuteLength = TimeInterval(Defaults[.focusTimerDebugMinuteSeconds])
        }
        return cfg
    }

    // MARK: - Shortcuts

    /// Runs a user-named shortcut through the shortcuts:// URL scheme: no
    /// subprocess, and `activates = false` so Shortcuts.app does not steal focus.
    /// Fire-and-forget: if the name does not exist Shortcuts shows its own error.
    private func runShortcut(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Defaults[.focusTimerRunShortcuts], !trimmed.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: trimmed)]
        guard let url = components.url else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(url, configuration: config) { [log] _, error in
            if let error { log.error("shortcut failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
