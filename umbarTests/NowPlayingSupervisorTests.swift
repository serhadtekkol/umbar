//
//  NowPlayingSupervisorTests.swift
//  umbarTests
//
//  Card #38 rules. Every timestamp is relative to a fixed epoch; the
//  supervisor never reads the clock itself.
//

import Foundation
import Testing

private typealias Supervisor = NowPlayingSupervisor

private let epoch = Date(timeIntervalSince1970: 1_000_000)
private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

private func switches(_ actions: [Supervisor.Action], to source: Supervisor.Source) -> Bool {
    actions.contains {
        if case .switchSource(let target, _) = $0 { return target == source }
        return false
    }
}

/// A supervisor whose adapter launched successfully at t = 0.
private func started() -> Supervisor {
    var supervisor = Supervisor()
    _ = supervisor.begin(now: at(0), unavailableReason: nil)
    _ = supervisor.adapterLaunched(now: at(0))
    return supervisor
}

@Suite("NowPlayingSupervisor", .timeLimit(.minutes(1)))
struct NowPlayingSupervisorTests {
    @Test func unavailableAdapterFallsBackAndNeverRetries() {
        var s = Supervisor()
        let actions = s.begin(now: at(0), unavailableReason: "missing")
        #expect(switches(actions, to: .fallback))
        #expect(!actions.contains(.startAdapter))
        #expect(s.nextDeadline == nil)
        #expect(s.tick(now: at(10_000)).isEmpty)
    }

    @Test func availableAdapterStartsAndIdlesWithoutDeadline() {
        var s = Supervisor()
        #expect(s.begin(now: at(0), unavailableReason: nil) == [.startAdapter])
        _ = s.adapterLaunched(now: at(0))
        #expect(s.source == .nowPlaying)
        #expect(s.nextDeadline == nil)
    }

    @Test func unexpectedExitFallsBackAndRetriesAfterFiveSeconds() {
        var s = started()
        let actions = s.adapterExited(now: at(1), status: 1)
        #expect(switches(actions, to: .fallback))
        #expect(actions.contains(.failed(.exited(status: 1), retryIn: 5)))
        #expect(!actions.contains(.stopAdapter), "an already-dead child is not stopped")
        #expect(s.nextDeadline == at(6))
        #expect(s.tick(now: at(5.9)).isEmpty, "no early restart")
        #expect(s.tick(now: at(6)) == [.startAdapter])
        #expect(s.tick(now: at(6.1)).isEmpty, "restart is requested only once")
    }

    @Test func retryBackoffDoublesAndCapsAtTenMinutes() {
        var s = started()
        var delays: [TimeInterval] = []
        var now: TimeInterval = 0
        for _ in 0..<10 {
            for action in s.adapterExited(now: at(now), status: 1) {
                if case .failed(_, let delay) = action { delays.append(delay) }
            }
            now += 10_000
            _ = s.tick(now: at(now))
            _ = s.adapterLaunched(now: at(now))
        }
        #expect(delays == [5, 10, 20, 40, 80, 160, 320, 600, 600, 600])
    }

    @Test func silentAdapterStallsEightSecondsAfterNativePlaybackStarts() {
        var s = started()
        _ = s.nativePlayback(now: at(100), startedPlaying: true)
        #expect(s.nextDeadline == at(108))
        #expect(s.tick(now: at(107.9)).isEmpty)
        let actions = s.tick(now: at(108))
        #expect(actions.first == .stopAdapter)
        #expect(actions.contains(.failed(.stalled, retryIn: 5)))
        #expect(switches(actions, to: .fallback))
        #expect(!s.isAdapterRunning, "a stalled child counts as stopped")
    }

    @Test func dataAfterNativeStartPreventsStall() {
        var s = started()
        _ = s.nativePlayback(now: at(100), startedPlaying: true)
        _ = s.adapterData(now: at(100.2))
        #expect(s.nextDeadline == nil)
        #expect(s.tick(now: at(200)).isEmpty)
        #expect(s.source == .nowPlaying)
    }

    @Test func dataFromBeforeNativeStartDoesNotProveHealth() {
        var s = started()
        _ = s.adapterData(now: at(50))
        _ = s.nativePlayback(now: at(100), startedPlaying: true)
        #expect(switches(s.tick(now: at(108)), to: .fallback))
    }

    @Test func stallClockStartsAtTheLaterOfLaunchAndNativeStart() {
        var s = Supervisor()
        _ = s.begin(now: at(0), unavailableReason: nil)
        _ = s.nativePlayback(now: at(0), startedPlaying: true)
        _ = s.adapterLaunched(now: at(30))
        #expect(s.nextDeadline == at(38))
    }

    @Test func firstDataFromRestartedAdapterSwitchesBackOnce() {
        var s = started()
        _ = s.adapterExited(now: at(1), status: 1)
        _ = s.tick(now: at(6))
        _ = s.adapterLaunched(now: at(6))
        #expect(s.source == .fallback, "stays on fallback until data arrives")
        #expect(switches(s.adapterData(now: at(7)), to: .nowPlaying))
        #expect(s.adapterData(now: at(8)).isEmpty, "no repeated switch")
    }

    @Test func failureCountResetsAfterTwoHealthyMinutes() {
        var s = started()
        _ = s.adapterExited(now: at(1), status: 1)
        _ = s.tick(now: at(6))
        _ = s.adapterLaunched(now: at(6))
        _ = s.adapterData(now: at(7))
        #expect(s.consecutiveFailures == 1)
        #expect(s.nextDeadline == at(126), "healthy-reset deadline is launch + 120 s")
        _ = s.tick(now: at(126))
        #expect(s.consecutiveFailures == 0)
        #expect(s.nextDeadline == nil)
        let actions = s.adapterExited(now: at(200), status: 1)
        #expect(actions.contains(.failed(.exited(status: 1), retryIn: 5)), "backoff restarts at 5 s")
    }

    @Test func pausedNativePlayerCannotStallAdapter() {
        var s = started()
        _ = s.nativePlayback(now: at(100), startedPlaying: true)
        _ = s.nativePlayback(now: at(102), startedPlaying: false)
        #expect(s.nextDeadline == nil)
        #expect(s.tick(now: at(500)).isEmpty)
    }

    @Test func exitOfAChildWeStoppedIsIgnored() {
        var s = started()
        _ = s.tick(now: at(0))
        _ = s.nativePlayback(now: at(1), startedPlaying: true)
        _ = s.tick(now: at(9))
        #expect(s.adapterExited(now: at(9.1), status: 15).isEmpty)
        #expect(s.consecutiveFailures == 1, "the stall is counted once")
    }

    @Test func launchFailureFallsBackAndSchedulesRetry() {
        var s = Supervisor()
        _ = s.begin(now: at(0), unavailableReason: nil)
        let actions = s.adapterLaunchFailed(now: at(0), error: "ENOENT")
        #expect(switches(actions, to: .fallback))
        #expect(s.nextDeadline == at(5))
    }

    @Test func stallDuringRetryBacksOffWithoutSwitchingAgain() {
        var s = started()
        _ = s.adapterExited(now: at(1), status: 1)
        _ = s.tick(now: at(6))
        _ = s.adapterLaunched(now: at(6))
        _ = s.nativePlayback(now: at(10), startedPlaying: true)
        let actions = s.tick(now: at(18))
        #expect(actions.contains(.stopAdapter))
        #expect(actions.contains(.failed(.stalled, retryIn: 10)))
        #expect(!switches(actions, to: .fallback), "already on fallback")
    }

    @Test func lateDataFromDeadChildIsIgnored() {
        var s = started()
        _ = s.adapterExited(now: at(1), status: 1)
        #expect(s.adapterData(now: at(2)).isEmpty)
        #expect(s.source == .fallback)
    }
}
