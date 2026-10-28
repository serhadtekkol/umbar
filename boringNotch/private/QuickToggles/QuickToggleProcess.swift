//
//  QuickToggleProcess.swift
//  boringNotch
//
//  F20/F22: the subprocess runner behind the quick toggles (shortcuts,
//  system_profiler) and the Bluetooth battery monitor. Foundation and os
//  only, so umbarTests compiles it hostless (membershipExceptions).
//

import Foundation
import os

/// Runs a system tool with a hard timeout and returns stdout. Arguments go
/// straight to execve, never through a shell, so a Shortcut name cannot
/// inject anything.
enum QuickToggleProcess {
    struct Failure: Error {
        /// The child's exit status, or -1 when it was stopped on timeout.
        let status: Int32
    }

    /// How a finished child ended. Reported to `onExit`, for tests.
    struct Exit: Sendable, Equatable {
        var reason: Process.TerminationReason
        var status: Int32
    }

    /// How long a child stopped with SIGTERM gets before SIGKILL. A stuck
    /// system_profiler (Bluetooth stack wedged) or a Shortcut that ignores
    /// SIGTERM would otherwise outlive its caller indefinitely, and the
    /// next refresh would start another one next to it.
    static let killGrace: Duration = .seconds(2)

    /// Starts `path`, returns its stdout when it exits 0.
    ///
    /// - Throws: `Failure(status:)` on a non-zero exit, `Failure(status: -1)`
    ///   when `timeout` passes first, `CancellationError` when the calling
    ///   task is cancelled. In the last two cases the child is sent SIGTERM
    ///   and, if it is still running after `killGrace`, SIGKILL.
    /// - Parameters:
    ///   - onLaunch: Called once the child is running. Tests only.
    ///   - onExit: Called once on a background queue when the child has
    ///     exited, however that happened. Tests only.
    static func run(_ path: String, _ arguments: [String], timeout: Duration,
                    killGrace: Duration = killGrace,
                    onLaunch: (@Sendable () -> Void)? = nil,
                    onExit: (@Sendable (Exit) -> Void)? = nil) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let call = Call()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard call.attach(continuation) else { return }
                do {
                    try process.run()
                } catch {
                    call.finish(.failure(error))
                    return
                }
                call.launched(process, killGrace: killGrace)
                onLaunch?()

                // Drain stdout on its own queue: a pipe that fills
                // (system_profiler JSON can pass the 64 KB pipe buffer) would
                // otherwise block the child and it would never exit.
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let status = process.terminationStatus
                    onExit?(Exit(reason: process.terminationReason, status: status))
                    call.finish(status == 0 ? .success(data) : .failure(Failure(status: status)))
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout.timeInterval) {
                    call.stop(with: Failure(status: -1))
                }
            }
        } onCancel: {
            call.stop(with: CancellationError())
        }
    }

    /// One run's shared state: the continuation (resumed exactly once), the
    /// launched process, and whether it was stopped before it launched.
    /// Every path (exit, timeout, cancellation) goes through the lock, so
    /// cancellation that races the launch neither leaks the child nor
    /// resumes twice.
    private final class Call: @unchecked Sendable {
        private struct State {
            var continuation: CheckedContinuation<Data, Error>?
            var process: Process?
            var killGrace: Duration = .zero
            var finished = false
            var stopError: Error?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        /// False when the run was stopped (cancelled) before it started; the
        /// continuation has then been resumed already.
        func attach(_ continuation: CheckedContinuation<Data, Error>) -> Bool {
            let stopped = state.withLock { s -> Error? in
                s.continuation = continuation
                return s.stopError
            }
            if let stopped { finish(.failure(stopped)); return false }
            return true
        }

        func launched(_ process: Process, killGrace: Duration) {
            let stopNow = state.withLock { s -> Bool in
                s.process = process
                s.killGrace = killGrace
                return s.stopError != nil
            }
            if stopNow { Self.terminate(process, grace: killGrace) }
        }

        func finish(_ result: Result<Data, Error>) {
            let continuation = state.withLock { s -> CheckedContinuation<Data, Error>? in
                // Without a continuation yet (cancelled before the body
                // ran), `attach` sees `stopError` and finishes then.
                guard !s.finished, s.continuation != nil else { return nil }
                s.finished = true
                defer { s.continuation = nil }
                return s.continuation
            }
            continuation?.resume(with: result)
        }

        /// Timeout or cancellation: ends the call with `error` and stops the
        /// child if it is running. A no-op once the child has exited.
        func stop(with error: Error) {
            let (process, grace, alreadyFinished) = state.withLock { s in
                if s.stopError == nil { s.stopError = error }
                return (s.process, s.killGrace, s.finished)
            }
            guard !alreadyFinished else { return }
            if let process { Self.terminate(process, grace: grace) }
            finish(.failure(error))
        }

        private static func terminate(_ process: Process, grace: Duration) {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + grace.timeInterval) {
                // isRunning turns false once Foundation has reaped the
                // child, and a pid is only reused after the reap; the
                // remaining window is the check-to-kill gap below.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}

private extension Duration {
    /// Whole duration in seconds. `components.seconds` alone drops the
    /// fraction, which turned a 0.5 s timeout into an immediate one.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
