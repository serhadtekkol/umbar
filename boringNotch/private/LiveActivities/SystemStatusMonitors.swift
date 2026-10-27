//
//  SystemStatusMonitors.swift
//  boringNotch
//
//  F19 live activities: the two sources that need no permission.
//  - Charging: IOPowerSources change notifications (event-driven, no polling).
//  - Time Machine: the world-readable preferences plist, read once a minute.
//
//  A separate power-source reader rather than BatteryActivityManager: that
//  class is a process-wide singleton started by the battery UI, and its
//  observer IDs are array indices that shift on removal, so a second
//  subscriber that comes and goes with a toggle would break the first.
//

import Foundation
import IOKit.ps
import os

/// Calls back with the charging status whenever the power source changes.
@MainActor
final class PowerSourceMonitor {
    private let onChange: @MainActor (ChargingStatus?) -> Void
    private var runLoopSource: CFRunLoopSource?

    init(onChange: @escaping @MainActor (ChargingStatus?) -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        // IOPS calls back on the run loop the source is added to: main here,
        // so the callback is already on the main actor.
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.read() }
        }, context)?.takeRetainedValue() else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        read()
    }

    /// Must be called before the monitor is released: the run-loop source
    /// holds an unretained pointer to it.
    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
    }

    private func read() {
        onChange(Self.currentStatus())
    }

    static func currentStatus() -> ChargingStatus? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let status = PowerSourceParser.chargingStatus(from: description) { return status }
        }
        return nil
    }
}

/// Reports when a Time Machine backup has finished.
@MainActor
final class TimeMachineMonitor {
    /// The plist only changes at the end of a backup, so a minute of delay
    /// costs nothing a person would notice, and one 70-byte read a minute is
    /// below any energy measurement.
    static let pollInterval: TimeInterval = 60

    private let plistURL: URL
    private let onFinished: @MainActor (Date) -> Void
    private let log = Logger(subsystem: "umbar", category: "LiveActivities")
    private var timer: Timer?
    private var lastDate: Date?
    private var hasBaseline = false
    private(set) var isConfigured = false

    init(plistURL: URL = URL(fileURLWithPath: TimeMachinePlistParser.path),
         onFinished: @escaping @MainActor (Date) -> Void) {
        self.plistURL = plistURL
        self.onFinished = onFinished
    }

    func start() {
        guard timer == nil else { return }
        poll()
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        hasBaseline = false
        lastDate = nil
    }

    private func poll() {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = TimeMachinePlistParser.parse(data: data)
        else { return }
        isConfigured = TimeMachinePlistParser.hasDestinations(plist)
        let current = TimeMachinePlistParser.latestBackupDate(plist)
        if TimeMachinePlistParser.didFinishBackup(previous: lastDate, current: current, isBaseline: !hasBaseline),
           let current
        {
            log.info("time machine backup finished")
            onFinished(current)
        }
        lastDate = current ?? lastDate
        hasBaseline = true
    }
}
