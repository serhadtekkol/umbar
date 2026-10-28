//
//  SysMonitorCore.swift
//  boringNotch
//
//  F22 system status, the pure part: CPU tick deltas, memory arithmetic,
//  per-app CPU from per-process CPU time, and the display formats. No
//  kernel calls here (those are in SysMonitorProbe), so the hostless
//  umbarTests bundle compiles this file and checks the math directly.
//

import Foundation

// MARK: - CPU

/// Cumulative host CPU ticks from `HOST_CPU_LOAD_INFO`, summed over all
/// cores. The kernel keeps them as 32-bit `natural_t` and lets them wrap,
/// so they stay `UInt32` here and every difference is a wrapping one.
struct SysCPUTicks: Equatable, Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

enum SysCPUMath {
    /// Share of the elapsed ticks that were busy, 0...1, across all cores
    /// (Activity Monitor's "% user + % system" total). Nil when no tick
    /// elapsed, which happens when two reads land in the same tick.
    ///
    /// Wrapping subtraction is correct as long as fewer than 2^32 ticks
    /// pass between two reads: at 100 ticks/s per core that is months.
    static func usage(from old: SysCPUTicks, to new: SysCPUTicks) -> Double? {
        let user = UInt64(new.user &- old.user)
        let system = UInt64(new.system &- old.system)
        let nice = UInt64(new.nice &- old.nice)
        let idle = UInt64(new.idle &- old.idle)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        return Double(busy) / Double(total)
    }
}

// MARK: - Memory

/// What memory pressure macOS reports (`kern.memorystatus_vm_pressure_level`).
/// This, not "used", is what says whether the Mac is short of memory:
/// macOS fills free RAM with cache on purpose, so "used" near the total
/// is normal.
enum SysMemoryPressure: Equatable, Sendable {
    case normal
    case warning
    case critical

    /// The kernel's levels are a bit set: 1 normal, 2 warn, 4 critical.
    /// Anything unexpected reads as normal rather than raising an alarm.
    init(kernelLevel: Int32) {
        switch kernelLevel {
        case 4: self = .critical
        case 2: self = .warning
        default: self = .normal
        }
    }
}

struct SysMemory: Equatable, Sendable {
    var usedBytes: UInt64
    var totalBytes: UInt64
    var pressure: SysMemoryPressure

    var usedFraction: Double {
        totalBytes > 0 ? min(1, Double(usedBytes) / Double(totalBytes)) : 0
    }
}

enum SysMemoryMath {
    /// Activity Monitor's "Memory Used": app memory (anonymous pages that
    /// are not purgeable) + wired + compressed. File cache is left out on
    /// purpose; it is given back the moment anything asks.
    static func usedBytes(internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64,
                          compressedPages: UInt64, pageSize: UInt64) -> UInt64 {
        let app = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return (app + wiredPages + compressedPages) * pageSize
    }
}

// MARK: - Thermal

/// `ProcessInfo.ThermalState`, mirrored so the views and tests do not
/// depend on the live value. This is what umbar shows for "temperature":
/// a degree reading needs the SMC's private, per-chip sensor keys, which
/// differ between M1, M2, M3 and M4 and are undocumented. The state is
/// what the system itself acts on (throttling), so it is the honest signal.
enum SysThermalLevel: Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    /// Serious and critical mean the system is slowing itself down.
    var isElevated: Bool { self == .serious || self == .critical }
}

// MARK: - Top apps

/// One process's cumulative CPU time at the moment of a read.
struct SysProcessReading: Equatable, Sendable {
    var pid: Int32
    /// User + system CPU time in nanoseconds.
    var cpuNanos: UInt64
    /// What the process is grouped under: its app's name, or its own name.
    var group: String
}

/// CPU use of one app (all its processes together).
struct SysAppUsage: Equatable, Sendable {
    var name: String
    /// Fraction of one core, as Activity Monitor's "% CPU": 1.0 is one
    /// core fully busy; a multithreaded app can go above 1.
    var cpu: Double
}

enum SysProcessMath {
    /// Below this an app is idle noise, not a "top consumer" worth naming.
    static let minimumShown = 0.01

    /// The busiest apps over the interval between two reads, highest first.
    ///
    /// A pid that only appears in `current` started during the interval and
    /// has no baseline, so it is skipped for this one round. A pid whose CPU
    /// time went down was reused by a new process; it is skipped too.
    /// Ties break by name so the order does not flicker between equal apps.
    static func topApps(previous: [Int32: UInt64], current: [SysProcessReading],
                        interval: TimeInterval, limit: Int) -> [SysAppUsage] {
        guard interval > 0, limit > 0 else { return [] }
        var byGroup: [String: UInt64] = [:]
        for reading in current {
            guard let old = previous[reading.pid], reading.cpuNanos >= old else { continue }
            byGroup[reading.group, default: 0] += reading.cpuNanos - old
        }
        let nanos = interval * 1_000_000_000
        return byGroup
            .map { SysAppUsage(name: $0.key, cpu: Double($0.value) / nanos) }
            .filter { $0.cpu >= minimumShown }
            .sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.name < $1.name }
            .prefix(limit)
            .map { $0 }
    }
}

enum SysAppGrouping {
    /// The app a process belongs to, from its executable path: the
    /// outermost `.app` bundle, so Chrome's renderer helpers
    /// (`…/Google Chrome.app/…/Google Chrome Helper (Renderer).app/…`) all
    /// count as "Google Chrome". A process outside any bundle (a daemon, a
    /// command-line tool) is named by its executable's file name, which,
    /// unlike the kernel's process name, is not cut at 16 or 32 bytes.
    static func group(executablePath: String?, processName: String) -> String {
        guard let path = executablePath else { return processName }
        let components = path.split(separator: "/")
        for component in components where component.hasSuffix(".app") {
            let name = component.dropLast(4)
            if !name.isEmpty { return String(name) }
        }
        return components.last.map(String.init) ?? processName
    }
}

// MARK: - Snapshot

/// Everything the stats row shows. Nil fields are not known yet (CPU and
/// top apps need two reads) and are drawn as a dash.
struct SysSnapshot: Equatable, Sendable {
    var cpu: Double?
    var memory: SysMemory?
    var thermal: SysThermalLevel
    var topApps: [SysAppUsage]
}

// MARK: - Formatting

enum SysFormat {
    /// "23%" in English, "%23" in Turkish: the locale decides where the
    /// sign goes. Clamped at zero; not at 100, because an app can use more
    /// than one core.
    static func percent(_ fraction: Double, locale: Locale = .current) -> String {
        let value = max(0, fraction.isFinite ? fraction : 0)
        return value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// "12.1 / 16 GB" (Turkish "12,1 / 16 GB"). Binary gigabytes, as
    /// Activity Monitor and About This Mac count RAM, so a 16 GB Mac reads
    /// 16 and not 17.2. The total drops its decimal when it is whole.
    static func memory(used: UInt64, total: UInt64, locale: Locale = .current) -> String {
        let gib = 1024.0 * 1024 * 1024
        let usedText = (Double(used) / gib).formatted(.number.precision(.fractionLength(1)).locale(locale))
        let totalValue = Double(total) / gib
        let totalText = totalValue.formatted(
            .number.precision(.fractionLength(totalValue.rounded() == totalValue ? 0 : 1)).locale(locale))
        return "\(usedText) / \(totalText) GB"
    }
}
