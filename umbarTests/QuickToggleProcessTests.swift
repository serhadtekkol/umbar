//
//  QuickToggleProcessTests.swift
//  umbarTests
//
//  L8: the subprocess runner stops what it started. Runs /bin/echo,
//  /bin/sh and /bin/sleep only; nothing touches Bluetooth or Shortcuts.
//

import Foundation
import Testing

/// Collects the runner's `onExit` report and lets a test await it.
private final class ExitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var exit: QuickToggleProcess.Exit?
    private var waiter: CheckedContinuation<QuickToggleProcess.Exit, Never>?

    func report(_ value: QuickToggleProcess.Exit) {
        lock.lock()
        let waiter = self.waiter
        if waiter == nil { exit = value }
        self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: value)
    }

    func wait() async -> QuickToggleProcess.Exit {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let exit {
                lock.unlock()
                continuation.resume(returning: exit)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

@Suite("QuickToggleProcess", .timeLimit(.minutes(1)))
struct QuickToggleProcessTests {
    @Test func returnsStdout() async throws {
        let data = try await QuickToggleProcess.run("/bin/echo", ["hi"], timeout: .seconds(10))
        #expect(String(decoding: data, as: UTF8.self) == "hi\n")
    }

    @Test func nonZeroExitThrowsItsStatus() async {
        await #expect(throws: QuickToggleProcess.Failure.self) {
            try await QuickToggleProcess.run("/bin/sh", ["-c", "exit 3"], timeout: .seconds(10))
        }
    }

    @Test func timeoutStopsTheChildWithSIGTERM() async {
        let probe = ExitProbe()
        let started = ContinuousClock.now
        await #expect(throws: QuickToggleProcess.Failure.self) {
            try await QuickToggleProcess.run("/bin/sleep", ["30"], timeout: .milliseconds(300),
                                             onExit: probe.report)
        }
        #expect(ContinuousClock.now - started < .seconds(10), "a sub-second timeout is honoured")
        let exit = await probe.wait()
        #expect(exit == .init(reason: .uncaughtSignal, status: SIGTERM))
    }

    /// A child that ignores SIGTERM (ignored signals survive exec) is
    /// SIGKILLed after the grace period instead of living on.
    @Test func aChildIgnoringSIGTERMIsKilled() async {
        let probe = ExitProbe()
        await #expect(throws: QuickToggleProcess.Failure.self) {
            try await QuickToggleProcess.run("/bin/sh", ["-c", "trap '' TERM; exec /bin/sleep 30"],
                                             timeout: .milliseconds(300), killGrace: .milliseconds(300),
                                             onExit: probe.report)
        }
        let exit = await probe.wait()
        #expect(exit == .init(reason: .uncaughtSignal, status: SIGKILL))
    }

    @Test func cancellingTheTaskStopsARunningChild() async {
        let probe = ExitProbe()
        let launched = ExitProbe()
        let task = Task {
            try await QuickToggleProcess.run("/bin/sleep", ["30"], timeout: .seconds(50),
                                             onLaunch: { launched.report(.init(reason: .exit, status: 0)) },
                                             onExit: probe.report)
        }
        _ = await launched.wait()
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        let exit = await probe.wait()
        #expect(exit == .init(reason: .uncaughtSignal, status: SIGTERM))
    }

    @Test func aTaskCancelledBeforehandNeverLaunches() async {
        let launches = OSAllocatedCounter()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await QuickToggleProcess.run("/bin/sleep", ["30"], timeout: .seconds(50),
                                                    onLaunch: { launches.increment() })
        }
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(launches.value == 0)
    }
}

private final class OSAllocatedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
