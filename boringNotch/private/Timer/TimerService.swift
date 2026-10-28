//
//  TimerService.swift
//  boringNotch
//
//  F25: owns the engine, the 1 s clock (only while a countdown runs),
//  persistence and the end-of-countdown alert: the closed ear pulses with
//  "Time's up" for `alertDuration`, a system notification goes out if umbar
//  already has permission, and a sound plays only if the user turned it on.
//  The panel is never opened for it: the alert must not take the pointer or
//  the keyboard from whatever the user is doing.
//

import AppKit
import Combine
import Defaults
import Foundation
import UserNotifications

@MainActor
final class TimerService: ObservableObject {
    static let shared = TimerService()

    /// Changes on transitions and user actions only; per-second display is
    /// drawn by TimelineView in the views.
    @Published private(set) var state: TimerState
    /// True for `alertDuration` after a countdown finished, or until dismissed.
    @Published private(set) var isAlerting = false

    private var engine: TimerEngine
    private var clock: Timer?
    private var alertTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var wakeObserver: NSObjectProtocol?

    static let alertDuration: TimeInterval = 8
    /// A countdown that ended longer ago than this (sleep, restart) still
    /// shows its alert, but stays silent: a chime minutes later is noise.
    private static let staleSoundAge: TimeInterval = 60
    private static let notificationID = "timer.finished"

    private init() {
        let saved = Defaults[.timerState]
            .flatMap { try? JSONDecoder().decode(TimerState.self, from: $0) } ?? .idle
        engine = TimerEngine(state: Defaults[.timerEnabled] ? saved : .idle)
        state = engine.state
        // Catches a countdown that ended while the app was not running.
        tick()
        publish()

        Defaults.publisher(.timerEnabled, options: [])
            .sink { [weak self] change in
                guard !change.newValue else { return }
                Task { @MainActor in self?.disable() }
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

    func startCountdown(minutes: Int) {
        mutate { $0.startCountdown(minutes: minutes, minuteLength: Self.minuteLength(), now: Date()) }
    }

    /// Runs the last countdown length again (the alert's "Again").
    func restartCountdown() {
        let minutes = max(1, Int((state.duration / Self.minuteLength()).rounded()))
        startCountdown(minutes: minutes)
    }

    func startStopwatch() { mutate { $0.startStopwatch(now: Date()) } }
    func lap() { mutate { $0.lap(now: Date()) } }
    func pause() { mutate { $0.pause(now: Date()) } }
    func resume() { mutate { $0.resume(now: Date()) } }
    func reset() { mutate { $0.reset() } }

    func dismissAlert() {
        alertTimer?.invalidate()
        alertTimer = nil
        isAlerting = false
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
    }

    // MARK: - Internals

    private func disable() {
        dismissAlert()
        engine = TimerEngine()
        publish()
    }

    private func tick() {
        guard let event = engine.tick(now: Date()) else { return }
        publish()
        switch event {
        case .countdownFinished(let lateness):
            alert(lateness: lateness)
        }
    }

    /// Single funnel for user actions: any action ends a showing alert.
    private func mutate(_ change: (inout TimerEngine) -> Void) {
        guard Defaults[.timerEnabled] else { return }
        if isAlerting { dismissAlert() }
        change(&engine)
        publish()
    }

    private func publish() {
        if state != engine.state { state = engine.state }
        persist()
        scheduleClock()
    }

    private func alert(lateness: TimeInterval) {
        isAlerting = true
        alertTimer?.invalidate()
        let t = Timer(timeInterval: Self.alertDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.alertTimer = nil
                self?.isAlerting = false
            }
        }
        RunLoop.main.add(t, forMode: .common)
        alertTimer = t

        if Defaults[.timerPlaysSound], lateness < Self.staleSoundAge {
            // A system sound, so nothing is bundled; NSSound(named:) is nil
            // if Apple ever renames it, and then the alert is silent.
            NSSound(named: "Glass")?.play()
        }
        if Defaults[.timerNotifies] { postNotificationIfAuthorized() }
    }

    /// Never prompts: without permission the island's alert is the only signal.
    private func postNotificationIfAuthorized() {
        // UNUserNotificationCenter raises an NSException in a process without
        // an app bundle (command-line harnesses); the shipped app always has one.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let title = String(localized: "timer.alert.title", defaultValue: "Time's up")
        let body = String(localized: "timer.notification.body", defaultValue: "Your timer has finished.")
        let id = Self.notificationID
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // The opt-in sound is played by the app, once; the notification stays silent.
            content.sound = nil
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// The clock only runs while a countdown counts down: a stopwatch has no
    /// deadline and draws itself, idle and paused cost nothing.
    private func scheduleClock() {
        if state.mode == .countdown && state.isRunning {
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
        Defaults[.timerState] = state.isIdle && state.duration == 0
            ? nil
            : try? JSONEncoder().encode(state)
    }

    private static func minuteLength() -> TimeInterval {
        let debug = Defaults[.timerDebugMinuteSeconds]
        return debug > 0 ? TimeInterval(debug) : 60
    }

    #if DEBUG
    /// Frame renderer only: puts the service in a fixed state without the
    /// clock, the notification or the sound.
    func showFixture(_ fixture: TimerState, alerting: Bool) {
        engine = TimerEngine(state: fixture)
        state = fixture
        isAlerting = alerting
    }
    #endif
}
