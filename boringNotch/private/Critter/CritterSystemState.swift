//
//  CritterSystemState.swift
//  boringNotch
//
//  Whether anyone is in front of the screen: a critter is not sent across
//  a locked, sleeping or switched-away session. Notifications only; nothing
//  polls.
//

import AppKit
import Combine

@MainActor
final class CritterSystemState: ObservableObject {
    static let shared = CritterSystemState()

    @Published private(set) var userAway = false

    private var presence = UserPresence() { didSet { update() } }
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {
        let ws = NSWorkspace.shared.notificationCenter
        let dist = DistributedNotificationCenter.default()
        observe(ws, NSWorkspace.willSleepNotification) { $0.presence.asleep = true }
        observe(ws, NSWorkspace.didWakeNotification) { $0.presence.asleep = false }
        observe(ws, NSWorkspace.screensDidSleepNotification) { $0.presence.displaysAsleep = true }
        observe(ws, NSWorkspace.screensDidWakeNotification) { $0.presence.displaysAsleep = false }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.presence.sessionInactive = true }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.presence.sessionInactive = false }
        observe(dist, Notification.Name("com.apple.screenIsLocked")) { $0.presence.locked = true }
        observe(dist, Notification.Name("com.apple.screenIsUnlocked")) { $0.presence.locked = false }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ apply: @escaping @MainActor @Sendable (CritterSystemState) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                apply(self)
            }
        }
        tokens.append((center, token))
    }

    private func update() {
        let away = presence.away
        if away != userAway { userAway = away }
    }
}
