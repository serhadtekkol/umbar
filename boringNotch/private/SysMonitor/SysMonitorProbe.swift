//
//  SysMonitorProbe.swift
//  boringNotch
//
//  F22 system status, the kernel reads: host CPU ticks and VM counters
//  (Mach), memory pressure (sysctl), and per-process CPU time (libproc).
//  All public, unprivileged calls: no entitlement, no helper, no SMC.
//
//  Per-process reads only succeed for this user's processes; root and
//  other users' daemons (WindowServer, kernel_task) return EPERM and are
//  left out. "Top apps" therefore means the user's own apps, which is the
//  question the row answers ("what of mine is eating the CPU").
//

import Darwin
import Foundation

enum SysProbe {
    /// `mach_host_self()` adds a send right on every call; take it once.
    private static let host = mach_host_self()

    static func cpuTicks() -> SysCPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks is indexed by CPU_STATE_USER/SYSTEM/IDLE/NICE (0...3).
        let ticks = info.cpu_ticks
        return SysCPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }

    static func memory() -> SysMemory? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let used = SysMemoryMath.usedBytes(
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count),
            compressedPages: UInt64(stats.compressor_page_count),
            pageSize: UInt64(getpagesize()))
        return SysMemory(usedBytes: used, totalBytes: ProcessInfo.processInfo.physicalMemory,
                         pressure: SysMemoryPressure(kernelLevel: pressureLevel()))
    }

    private static func pressureLevel() -> Int32 {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 1 }
        return level
    }

    static func allPIDs() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        // Headroom for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard count > 0 else { return [] }
        return Array(pids.prefix(Int(count)))
    }

    /// User + system CPU time in nanoseconds, or nil when the process is
    /// gone or not ours to read.
    static func cpuNanos(pid: pid_t) -> UInt64? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard result == 0 else { return nil }
        // ri_*_time is in Mach absolute time units, which are nanoseconds
        // on Intel but 125/3 ns ticks on Apple silicon.
        let ticks = info.ri_user_time &+ info.ri_system_time
        return ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue / UInt64(max(1, timebase.denom))
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// What `SysAppGrouping` groups the process under.
    static func group(pid: pid_t) -> String {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : nil
        var nameBuffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = nameLength > 0 ? String(cString: nameBuffer) : "\(pid)"
        return SysAppGrouping.group(executablePath: path, processName: name)
    }
}

/// Holds what one read needs from the previous one. Not thread-safe by
/// itself: `SysMonitor` only touches it on its own serial queue.
final class SysSampler: @unchecked Sendable {
    private var lastTicks: SysCPUTicks?
    private var lastCPU: [Int32: UInt64] = [:]
    private var lastTime: TimeInterval?
    /// pid → group. Paths are the expensive read, and a running process
    /// does not change its executable, so each pid is resolved once and
    /// dropped when it exits.
    private var groups: [Int32: String] = [:]

    func reset() {
        lastTicks = nil
        lastCPU = [:]
        lastTime = nil
        groups = [:]
    }

    func sample(now: TimeInterval, topLimit: Int) -> SysSnapshot {
        let ticks = SysProbe.cpuTicks()
        let cpu: Double? = {
            guard let ticks, let lastTicks else { return nil }
            return SysCPUMath.usage(from: lastTicks, to: ticks)
        }()
        lastTicks = ticks

        var readings: [SysProcessReading] = []
        var seen: [Int32: String] = [:]
        for pid in SysProbe.allPIDs() where pid > 0 {
            guard let nanos = SysProbe.cpuNanos(pid: pid) else { continue }
            // A smaller CPU time means the pid was reused: resolve again.
            let reused = (lastCPU[pid].map { nanos < $0 }) ?? false
            let group = (!reused ? groups[pid] : nil) ?? SysProbe.group(pid: pid)
            seen[pid] = group
            readings.append(SysProcessReading(pid: pid, cpuNanos: nanos, group: group))
        }
        let top: [SysAppUsage]
        if let lastTime {
            top = SysProcessMath.topApps(previous: lastCPU, current: readings, interval: now - lastTime, limit: topLimit)
        } else {
            top = []
        }
        groups = seen
        lastCPU = Dictionary(uniqueKeysWithValues: readings.map { ($0.pid, $0.cpuNanos) })
        lastTime = now

        return SysSnapshot(cpu: cpu, memory: SysProbe.memory(),
                           thermal: SysThermalLevel(ProcessInfo.processInfo.thermalState), topApps: top)
    }
}
