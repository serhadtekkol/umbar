//
//  SysMonitorTests.swift
//  umbarTests
//
//  F22 system status: CPU tick deltas (including the 32-bit wrap), the
//  memory "used" arithmetic, pressure levels, per-app CPU from process
//  deltas (new pids, reused pids, grouping, ordering), app grouping by
//  bundle path, and the display formats. The Mach/libproc reads
//  (SysProbe) are not exercised here; they were checked live against
//  Activity Monitor and `top`.
//

import Foundation
import Testing

private let english = Locale(identifier: "en_US")
private let turkish = Locale(identifier: "tr_TR")

@Suite("SysCPUMath", .timeLimit(.minutes(1)))
struct SysCPUMathTests {
    @Test func usageIsBusyTicksOverAllTicks() throws {
        let old = SysCPUTicks(user: 100, system: 50, idle: 800, nice: 0)
        let new = SysCPUTicks(user: 130, system: 60, idle: 860, nice: 0)
        let usage = try #require(SysCPUMath.usage(from: old, to: new))
        #expect(abs(usage - 0.4) < 1e-9)
    }

    @Test func niceCountsAsBusy() throws {
        let old = SysCPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let new = SysCPUTicks(user: 0, system: 0, idle: 50, nice: 50)
        #expect(try #require(SysCPUMath.usage(from: old, to: new)) == 0.5)
    }

    @Test func noElapsedTicksGivesNil() {
        let ticks = SysCPUTicks(user: 5, system: 5, idle: 5, nice: 5)
        #expect(SysCPUMath.usage(from: ticks, to: ticks) == nil)
    }

    @Test func wrappedCountersStillGiveTheRightDelta() throws {
        let old = SysCPUTicks(user: UInt32.max - 9, system: 0, idle: UInt32.max - 29, nice: 0)
        let new = SysCPUTicks(user: 10, system: 0, idle: 30, nice: 0)
        // 20 busy, 60 idle across the wrap.
        #expect(try #require(SysCPUMath.usage(from: old, to: new)) == 0.25)
    }
}

@Suite("SysMemory", .timeLimit(.minutes(1)))
struct SysMemoryTests {
    @Test func usedIsAppPlusWiredPlusCompressed() {
        let used = SysMemoryMath.usedBytes(internalPages: 1_000, purgeablePages: 200, wiredPages: 300,
                                           compressedPages: 100, pageSize: 16_384)
        #expect(used == 1_200 * 16_384)
    }

    @Test func purgeableAboveInternalDoesNotUnderflow() {
        let used = SysMemoryMath.usedBytes(internalPages: 10, purgeablePages: 50, wiredPages: 5,
                                           compressedPages: 0, pageSize: 4_096)
        #expect(used == 5 * 4_096)
    }

    @Test func pressureLevelsMapFromTheKernelBits() {
        #expect(SysMemoryPressure(kernelLevel: 1) == .normal)
        #expect(SysMemoryPressure(kernelLevel: 2) == .warning)
        #expect(SysMemoryPressure(kernelLevel: 4) == .critical)
        #expect(SysMemoryPressure(kernelLevel: 0) == .normal)
        #expect(SysMemoryPressure(kernelLevel: 99) == .normal)
    }

    @Test func usedFractionIsClampedAndSafeForZeroTotal() {
        #expect(SysMemory(usedBytes: 20, totalBytes: 10, pressure: .normal).usedFraction == 1)
        #expect(SysMemory(usedBytes: 5, totalBytes: 0, pressure: .normal).usedFraction == 0)
    }

    @Test func thermalElevationStartsAtSerious() {
        #expect(!SysThermalLevel(.nominal).isElevated)
        #expect(!SysThermalLevel(.fair).isElevated)
        #expect(SysThermalLevel(.serious).isElevated)
        #expect(SysThermalLevel(.critical).isElevated)
    }
}

@Suite("SysProcessMath", .timeLimit(.minutes(1)))
struct SysProcessMathTests {
    private func reading(_ pid: Int32, _ nanos: UInt64, _ group: String) -> SysProcessReading {
        SysProcessReading(pid: pid, cpuNanos: nanos, group: group)
    }

    @Test func processesOfOneAppAreSummed() {
        let previous: [Int32: UInt64] = [1: 0, 2: 0, 3: 0]
        let current = [reading(1, 300_000_000, "Chrome"), reading(2, 400_000_000, "Chrome"), reading(3, 500_000_000, "Xcode")]
        let top = SysProcessMath.topApps(previous: previous, current: current, interval: 1, limit: 5)
        #expect(top.map(\.name) == ["Chrome", "Xcode"])
        #expect(abs(top[0].cpu - 0.7) < 1e-9)
        #expect(abs(top[1].cpu - 0.5) < 1e-9)
    }

    @Test func moreThanOneCoreIsAboveOne() throws {
        let top = SysProcessMath.topApps(previous: [7: 1_000], current: [reading(7, 1_000 + 3_000_000_000, "Render")],
                                         interval: 1, limit: 1)
        #expect(try #require(top.first).cpu == 3)
    }

    @Test func cpuIsPerSecondOfInterval() throws {
        let top = SysProcessMath.topApps(previous: [1: 0], current: [reading(1, 1_000_000_000, "A")], interval: 2, limit: 1)
        #expect(try #require(top.first).cpu == 0.5)
    }

    @Test func newPidsWithoutBaselineAreSkipped() {
        let top = SysProcessMath.topApps(previous: [:], current: [reading(9, 5_000_000_000, "New")], interval: 1, limit: 3)
        #expect(top.isEmpty)
    }

    @Test func reusedPidWithSmallerTimeIsSkipped() {
        let top = SysProcessMath.topApps(previous: [4: 9_000_000_000], current: [reading(4, 100, "Reused")], interval: 1, limit: 3)
        #expect(top.isEmpty)
    }

    @Test func idleAppsAreNotNamed() {
        let top = SysProcessMath.topApps(previous: [1: 0], current: [reading(1, 5_000_000, "Idle")], interval: 1, limit: 3)
        #expect(top.isEmpty)
    }

    @Test func limitAndTieOrderAreStable() {
        let previous: [Int32: UInt64] = [1: 0, 2: 0, 3: 0]
        let current = [reading(1, 200_000_000, "Beta"), reading(2, 200_000_000, "Alpha"), reading(3, 100_000_000, "Gamma")]
        let top = SysProcessMath.topApps(previous: previous, current: current, interval: 1, limit: 2)
        #expect(top.map(\.name) == ["Alpha", "Beta"])
    }

    @Test func zeroIntervalOrLimitGivesNothing() {
        let current = [reading(1, 900_000_000, "A")]
        #expect(SysProcessMath.topApps(previous: [1: 0], current: current, interval: 0, limit: 2).isEmpty)
        #expect(SysProcessMath.topApps(previous: [1: 0], current: current, interval: 1, limit: 0).isEmpty)
    }
}

@Suite("SysAppGrouping", .timeLimit(.minutes(1)))
struct SysAppGroupingTests {
    @Test func helpersGroupUnderTheOutermostApp() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
        #expect(SysAppGrouping.group(executablePath: path, processName: "Google Chrome He") == "Google Chrome")
    }

    @Test func plainAppIsItsBundleName() {
        #expect(SysAppGrouping.group(executablePath: "/Applications/Xcode.app/Contents/MacOS/Xcode", processName: "Xcode") == "Xcode")
    }

    @Test func nonBundleProcessUsesItsName() {
        #expect(SysAppGrouping.group(executablePath: "/usr/libexec/trustd", processName: "trustd") == "trustd")
        #expect(SysAppGrouping.group(executablePath: nil, processName: "mds") == "mds")
        #expect(SysAppGrouping.group(executablePath: "/", processName: "mds") == "mds")
    }

    @Test func executableNameBeatsTheTruncatedKernelName() {
        let path = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"
        #expect(SysAppGrouping.group(executablePath: path, processName: "com.apple.Virtua") == "com.apple.Virtualization.VirtualMachine")
    }

    @Test func dotAppAloneIsNotAName() {
        #expect(SysAppGrouping.group(executablePath: "/tmp/.app/run", processName: "run") == "run")
    }
}

@Suite("SysFormat", .timeLimit(.minutes(1)))
struct SysFormatTests {
    @Test func percentFollowsTheLocale() {
        #expect(SysFormat.percent(0.234, locale: english) == "23%")
        #expect(SysFormat.percent(0.234, locale: turkish) == "%23")
    }

    @Test func percentIsNotCappedAtOneCoreButIsAtZero() {
        #expect(SysFormat.percent(6.12, locale: english) == "612%")
        #expect(SysFormat.percent(-0.5, locale: english) == "0%")
        #expect(SysFormat.percent(.nan, locale: english) == "0%")
    }

    @Test func memoryIsInBinaryGigabytes() {
        let gib: UInt64 = 1_073_741_824
        #expect(SysFormat.memory(used: gib * 121 / 10, total: 16 * gib, locale: english) == "12.1 / 16 GB")
        #expect(SysFormat.memory(used: gib * 121 / 10, total: 16 * gib, locale: turkish) == "12,1 / 16 GB")
        #expect(SysFormat.memory(used: 0, total: gib * 3 / 2, locale: english) == "0.0 / 1.5 GB")
    }
}
