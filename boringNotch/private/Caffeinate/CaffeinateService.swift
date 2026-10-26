//
//  CaffeinateService.swift
//  boringNotch
//
//  F11: keep the Mac awake with public IOKit power assertions.
//

import Combine
import Defaults
import Foundation
import IOKit.ps
import IOKit.pwr_mgt
import UserNotifications

/// Owns the power assertions and the observable state for the UI.
///
/// Why two assertions: `PreventUserIdleDisplaySleep` keeps the screen on (and
/// implies no idle system sleep), `PreventUserIdleSystemSleep` is added so the
/// intent is explicit and survives the display assertion being reworked. Both
/// are *idle* assertions, so closing the lid still sleeps the Mac normally
/// (AC-11.5, clamshell blocking is out of scope).
///
/// Why no `caffeinate` subprocess and no persistence: assertions belong to
/// this process and the kernel drops them when it exits, including SIGKILL
/// (AC-11.4 / C2). A child process or a saved "on" flag would be a way to
/// outlive the app, so neither is used.
@MainActor
final class CaffeinateService: ObservableObject {
    static let shared = CaffeinateService()

    @Published private(set) var session: CaffeinateSession?
    /// Seconds left of a timed session, refreshed once a second while on.
    @Published private(set) var remaining: TimeInterval?
    /// Set when caffeinate stopped on its own; cleared on the next start.
    @Published private(set) var notice: String?

    var isActive: Bool { session != nil }

    private var displayAssertion = IOPMAssertionID(kIOPMNullAssertionID)
    private var systemAssertion = IOPMAssertionID(kIOPMNullAssertionID)
    private var expiryTimer: DispatchSourceTimer?
    private var tickTimer: Timer?
    private var batterySource: CFRunLoopSource?

    private var enabledCancellable: AnyCancellable?

    private init() {
        // Switching the feature off in Settings ends a running session (AC-1.13).
        enabledCancellable = Defaults.publisher(.caffeinateEnabled, options: [])
            .sink { [weak self] change in
                guard !change.newValue else { return }
                Task { @MainActor in self?.stop() }
            }
    }

    /// Starts (or restarts with a new duration) a session.
    /// Refuses when already below the battery threshold on battery power,
    /// otherwise the session would be killed at once (BR-11.1).
    func start(_ duration: CaffeinateDuration, now: Date = Date()) {
        stopInternal()
        notice = nil

        let battery = Self.readBattery()
        if CaffeinatePolicy.shouldStopForBattery(percent: battery.percent, isPluggedIn: battery.isPluggedIn) {
            notice = String(localized: "caffeinate.notice.batteryTooLow", defaultValue: "Battery is below 10%. Plug in to use caffeinate.")
            return
        }

        let reason = "\(ProcessInfo.processInfo.processName) caffeinate" as CFString
        let d = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &displayAssertion)
        let s = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &systemAssertion)
        guard d == kIOReturnSuccess, s == kIOReturnSuccess else {
            releaseAssertions()
            notice = String(localized: "caffeinate.notice.failed", defaultValue: "Could not keep the Mac awake.")
            return
        }

        let newSession = CaffeinateSession(duration: duration, startedAt: now)
        session = newSession
        remaining = newSession.remaining(at: now)
        scheduleExpiry(for: newSession)
        startBatteryMonitoring()
    }

    /// Stops a running session on user request.
    func stop() {
        guard session != nil else { return }
        finish(reason: .user)
    }

    func toggle(_ duration: CaffeinateDuration = .indefinite) {
        isActive ? stop() : start(duration)
    }

    // MARK: - Internals

    private func finish(reason: CaffeinateStopReason) {
        stopInternal()
        switch reason {
        case .user:
            notice = nil
        case .expired:
            notice = nil
        case .lowBattery:
            let text = String(localized: "caffeinate.notice.batteryOff", defaultValue: "Caffeinate turned off: battery below 10%.")
            notice = text
            postSystemNotificationIfAuthorized(text)
        }
    }

    private func stopInternal() {
        expiryTimer?.cancel()
        expiryTimer = nil
        tickTimer?.invalidate()
        tickTimer = nil
        stopBatteryMonitoring()
        releaseAssertions()
        session = nil
        remaining = nil
    }

    private func releaseAssertions() {
        if displayAssertion != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = IOPMAssertionID(kIOPMNullAssertionID)
        }
        if systemAssertion != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(systemAssertion)
            systemAssertion = IOPMAssertionID(kIOPMNullAssertionID)
        }
    }

    private func scheduleExpiry(for session: CaffeinateSession) {
        guard let deadline = session.deadline else { return }
        // Wall-clock deadline: a monotonic timer would not count time spent
        // asleep (e.g. after a lid close), and the session would overrun.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(wallDeadline: .now() + deadline.timeIntervalSinceNow)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.finish(reason: .expired) }
        }
        timer.resume()
        expiryTimer = timer

        let tick = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                self.remaining = session.remaining(at: Date())
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        tickTimer = tick
    }

    // MARK: Battery (BR-11.1)

    /// Own power-source observer, only registered while a session runs. The
    /// shared BatteryActivityManager delays events by 1s per queued change,
    /// which is too coarse for a safety cut-off.
    private func startBatteryMonitoring() {
        guard batterySource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let service = Unmanaged<CaffeinateService>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { service.evaluateBattery() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        batterySource = source
    }

    private func stopBatteryMonitoring() {
        if let source = batterySource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            batterySource = nil
        }
    }

    private func evaluateBattery() {
        guard session != nil else { return }
        let battery = Self.readBattery()
        if CaffeinatePolicy.shouldStopForBattery(percent: battery.percent, isPluggedIn: battery.isPluggedIn) {
            finish(reason: .lowBattery)
        }
    }

    private static func readBattery() -> (percent: Int?, isPluggedIn: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, true) }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
            else { continue }
            let current = (desc[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
            let max = (desc[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
            let plugged = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let pct = (current != nil && max != nil) ? CaffeinatePolicy.percent(current: current!, max: max!) : nil
            return (pct, plugged)
        }
        // No internal battery (desktop Mac): never cut off.
        return (nil, true)
    }

    /// Never prompts: if the user has not already granted notifications, the
    /// in-panel notice is the only signal.
    private func postSystemNotificationIfAuthorized(_ body: String) {
        // UNUserNotificationCenter raises an NSException in a process without
        // an app bundle (command-line harnesses); the shipped app always has one.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.body = body
            center.add(UNNotificationRequest(identifier: "caffeinate.lowBattery", content: content, trigger: nil))
        }
    }
}
