//
//  NowPlayingAdapterProcess.swift
//  boringNotch
//

import AppKit
import Foundation

/// Owns the one `/usr/bin/perl -T mediaremote-adapter.pl <framework> stream`
/// child process that feeds system Now Playing data to the app.
///
/// The child gets an allowlisted environment, never the app's
/// (`AdapterChildEnvironment`, card #67).
///
/// Lifetime guarantees (cards #38, #57):
/// - At most one child at a time: `start` is a no-op while one is running,
///   and a new child is only started after the previous one was stopped.
/// - The child never outlives the app:
///   - normal quit (menu, AppleEvent `quit`): `willTerminate` stops it;
///   - SIGTERM, SIGKILL, crash: no app code runs, so the child watches our pid
///     itself (`UMBAR_ADAPTER_PARENT_PID`, see
///     mediaremote-adapter/Sources/umbar/UmbarParentWatchdog.m) and exits.
///
/// A child that writes more than `AdapterLineBuffer.defaultLimit` bytes
/// without a newline is terminated and reported through `onUnexpectedExit`
/// like any other failure (card #70), so app memory stays bounded.
///
/// Threading: `start`, `stop` and the callbacks' registration happen on the
/// main thread. `onLine` is invoked on a private serial queue (lines can be
/// several hundred KB of base64 artwork, so decoding stays off the main
/// thread); `onUnexpectedExit` is invoked on the main thread.
final class NowPlayingAdapterProcess {
    /// One complete stdout line, without the trailing newline.
    var onLine: ((Data) -> Void)?
    /// The child exited without `stop` having been called. Receives the exit
    /// status and the tail of its stderr (for the log).
    var onUnexpectedExit: ((Int32, String) -> Void)?

    private let ioQueue = DispatchQueue(label: "umbar.nowplaying.adapter-io")
    private var process: Process?
    /// Incremented on every start/stop so callbacks from an old child are ignored.
    private var generation = 0
    private var terminationObserver: NSObjectProtocol?

    // Touched on `ioQueue` only.
    private var stdoutLines = AdapterLineBuffer()
    private var stderrTail = Data()
    private static let stderrTailLimit = 2048

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The app is about to exit(); give the child a moment to go so a
            // quick relaunch never sees two streams.
            self?.stop(waitForExit: 0.5)
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        stop()
    }

    var isRunning: Bool { process?.isRunning ?? false }

    var processIdentifier: Int32? { isRunning ? process?.processIdentifier : nil }

    /// Launches the stream child. Throws when `/usr/bin/perl` cannot be spawned.
    func start(scriptURL: URL, frameworkPath: String) throws {
        guard process == nil else { return }

        generation += 1
        let myGeneration = generation

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // -T (taint mode) is a second layer under the environment allowlist:
        // perl then ignores PERL5LIB/PERL5OPT outright. Verified on macOS
        // 27.0.1 that the adapter still loads its framework and runs `get`
        // and `stream` under -T.
        child.arguments = ["-T", scriptURL.path, frameworkPath, "stream"]
        child.environment = AdapterChildEnvironment.current()
        child.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe

        ioQueue.sync {
            stdoutLines = AdapterLineBuffer()
            stderrTail.removeAll(keepingCapacity: false)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            // sync, not async: the next read waits until this chunk is
            // consumed, so a fast writer cannot pile chunks up in the queue
            // behind the line buffer's cap (card #70).
            self?.ioQueue.sync { self?.consumeStdout(data, generation: myGeneration) }
        }
        // Must be drained: a full stderr pipe (64 KB) would block the child.
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.ioQueue.sync { self?.consumeStderr(data) }
        }

        child.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                guard let self, self.generation == myGeneration else { return }
                self.process = nil
                let tail = self.ioQueue.sync {
                    String(decoding: self.stderrTail, as: UTF8.self)
                }
                self.onUnexpectedExit?(status, tail)
            }
        }

        do {
            try child.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process = child
    }

    /// Stops the child if one is running. Never reports an unexpected exit.
    ///
    /// - Parameter waitForExit: How long to block for the child to be gone.
    ///   0 returns immediately; a child that ignores SIGTERM is SIGKILLed
    ///   after one second either way.
    func stop(waitForExit: TimeInterval = 0) {
        generation += 1
        guard let child = process else { return }
        process = nil

        (child.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (child.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        guard child.isRunning else { return }

        let pid = child.processIdentifier
        child.terminate()

        if waitForExit > 0 {
            let deadline = Date().addingTimeInterval(waitForExit)
            while child.isRunning && Date() < deadline {
                usleep(10_000)
            }
        }
        if child.isRunning {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if child.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    // MARK: - I/O (ioQueue)

    private func consumeStdout(_ data: Data, generation childGeneration: Int) {
        let wasOverflowed = stdoutLines.hasOverflowed
        for line in stdoutLines.append(data) {
            onLine?(line)
        }
        if stdoutLines.hasOverflowed && !wasOverflowed {
            DispatchQueue.main.async { [weak self] in
                self?.terminateForOverflow(generation: childGeneration)
            }
        }
    }

    /// Main thread. Ends the child *without* bumping `generation`, so its
    /// exit reaches `onUnexpectedExit` and the supervisor treats it as a
    /// failure (backoff restart, fallback) rather than as a requested stop.
    private func terminateForOverflow(generation childGeneration: Int) {
        guard generation == childGeneration, let child = process, child.isRunning else { return }
        NSLog("[NowPlaying] adapter wrote a line over \(AdapterLineBuffer.defaultLimit) bytes; buffer dropped, terminating child")
        let pid = child.processIdentifier
        child.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            if child.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func consumeStderr(_ data: Data) {
        stderrTail.append(data)
        if stderrTail.count > Self.stderrTailLimit {
            stderrTail = stderrTail.suffix(Self.stderrTailLimit)
        }
    }
}
