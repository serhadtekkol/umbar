//
//  SysMonitor.swift
//  boringNotch
//
//  F22 system status: samples CPU, memory, thermal state and the busiest
//  apps once a second while the stats row is on screen, and not at all
//  otherwise. There is no background cadence (unlike NetMonitor, nothing
//  here accumulates), so with the panel closed the feature costs nothing:
//  no timer, no reads.
//
//  Threading. The published state is main-actor. One read walks every
//  process (a few hundred libproc calls, ~1-3 ms), so it runs on a serial
//  utility queue that owns the `SysSampler`; the result is handed back to
//  the main actor.
//

import Combine
import Defaults
import Foundation

@MainActor
final class SysMonitor: ObservableObject {
    static let shared = SysMonitor()

    @Published private(set) var snapshot: SysSnapshot?

    /// How many apps the row names.
    static let topLimit = 2
    private let interval: TimeInterval = 1
    /// The first figures after opening: CPU and top apps need two reads, and
    /// waiting a full second shows a dash for too long.
    private let firstDelay: TimeInterval = 0.5

    private var observerCount = 0
    private var timer: Timer?
    /// Bumped on every stop, so a read that was in flight when the row
    /// went away does not publish into the next session.
    private var generation = 0
    private let sampler = SysSampler()
    private let queue = DispatchQueue(label: "umbar.SysMonitor.sample", qos: .utility)
    private var cancellable: AnyCancellable?

    private init() {}

    /// Stops sampling at once when the setting is turned off with the row
    /// on screen; the view goes away too, but not necessarily first.
    func start() {
        guard cancellable == nil else { return }
        cancellable = Defaults.publisher(.sysMonitorEnabled)
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated { self?.update(enabled: enabled) }
            }
    }

    /// The stats row appeared. Balanced by `endObserving`.
    func beginObserving() {
        observerCount += 1
        if observerCount == 1 { update(enabled: Defaults[.sysMonitorEnabled]) }
    }

    func endObserving() {
        observerCount = max(0, observerCount - 1)
        if observerCount == 0 { stop() }
    }

    private func update(enabled: Bool) {
        if enabled, observerCount > 0 { begin() } else { stop() }
    }

    private func begin() {
        guard timer == nil else { return }
        read()
        let newTimer = Timer(fire: Date().addingTimeInterval(firstDelay), interval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.read() }
        }
        newTimer.tolerance = 0.1
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stop() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        generation += 1
        // The next open starts from fresh baselines; a delta across the
        // closed time would be an average of minutes, not "now".
        let sampler = self.sampler
        queue.async { sampler.reset() }
        snapshot = nil
    }

    private func read() {
        let sampler = self.sampler
        let current = generation
        let limit = Self.topLimit
        queue.async { [weak self] in
            let result = sampler.sample(now: ProcessInfo.processInfo.systemUptime, topLimit: limit)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == current else { return }
                    self.snapshot = result
                }
            }
        }
    }
}
