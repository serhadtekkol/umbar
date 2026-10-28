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
        let status: Int32
    }

    static func run(_ path: String, _ arguments: [String], timeout: Duration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice

            let lock = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resume(_ result: Result<Data, Error>) {
                let first = lock.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }

            do {
                try process.run()
            } catch {
                resume(.failure(error))
                return
            }

            // Drain stdout on its own queue: a pipe that fills
            // (system_profiler JSON can pass the 64 KB pipe buffer) would
            // otherwise block the child and it would never exit.
            DispatchQueue.global(qos: .userInitiated).async {
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let status = process.terminationStatus
                resume(status == 0 ? .success(data) : .failure(Failure(status: status)))
            }

            let nanos = timeout.components.seconds * 1_000_000_000
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(nanos))) {
                if process.isRunning { process.terminate() }
                resume(.failure(Failure(status: -1)))
            }
        }
    }
}
