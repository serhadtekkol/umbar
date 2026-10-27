//
//  CaffeinatePolicyTests.swift
//  umbarTests
//
//  F11 caffeinate: durations, expiry and the BR-11.1 low-battery cut-off.
//  Ported from the caffeinate scratch harness; the power assertion itself
//  (CaffeinateService, IOKit) is not exercised here.
//

import Foundation
import Testing

private let epoch = Date(timeIntervalSince1970: 1_000_000)
private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

@Suite("CaffeinatePolicy", .timeLimit(.minutes(1)))
struct CaffeinatePolicyTests {
    @Test func durationsMatchTheOffer() {
        #expect(CaffeinateDuration.indefinite.interval == nil)
        #expect(CaffeinateDuration.minutes15.interval == TimeInterval(15 * 60))
        #expect(CaffeinateDuration.hour1.interval == TimeInterval(60 * 60))
        #expect(CaffeinateDuration.hours2.interval == TimeInterval(2 * 60 * 60))
    }

    @Test func expiryIsInclusiveAtTheDeadline() {
        let session = CaffeinateSession(duration: .minutes15, startedAt: epoch)
        #expect(session.deadline == at(900))
        #expect(!session.hasExpired(at: epoch))
        #expect(!session.hasExpired(at: at(899.999)))
        #expect(session.hasExpired(at: at(900)))
        #expect(session.hasExpired(at: at(5000)))
    }

    @Test func clockMovingBackwardsDoesNotExpire() {
        let session = CaffeinateSession(duration: .minutes15, startedAt: epoch)
        #expect(!session.hasExpired(at: at(-100)))
    }

    @Test func remainingIsClampedAtZero() {
        let session = CaffeinateSession(duration: .minutes15, startedAt: epoch)
        #expect(session.remaining(at: at(300)) == 600)
        #expect(session.remaining(at: at(5000)) == 0)
    }

    @Test func indefiniteNeverExpires() {
        let session = CaffeinateSession(duration: .indefinite, startedAt: epoch)
        #expect(session.deadline == nil)
        #expect(session.remaining(at: epoch) == nil)
        #expect(!session.hasExpired(at: at(1e9)))
    }

    /// BR-11.1: exactly 10 % keeps caffeinate on; 9 % on battery stops it.
    @Test(arguments: [
        (percent: 10 as Int?, pluggedIn: false, stops: false),
        (percent: 9, pluggedIn: false, stops: true),
        (percent: 0, pluggedIn: false, stops: true),
        (percent: 9, pluggedIn: true, stops: false),
        (percent: 0, pluggedIn: true, stops: false),
        (percent: nil, pluggedIn: false, stops: false),  // unusable reading never stops it
    ])
    func lowBatteryCutOff(_ row: (percent: Int?, pluggedIn: Bool, stops: Bool)) {
        #expect(CaffeinatePolicy.shouldStopForBattery(percent: row.percent, isPluggedIn: row.pluggedIn) == row.stops)
    }

    @Test func percentFromRawCapacity() {
        #expect(CaffeinatePolicy.percent(current: 9, max: 100) == 9)
        #expect(CaffeinatePolicy.percent(current: 10, max: 100) == 10)
        #expect(CaffeinatePolicy.percent(current: 1, max: 10) == 10)
        #expect(CaffeinatePolicy.percent(current: 5, max: 0) == nil, "no battery")
        #expect(CaffeinatePolicy.percent(current: -1, max: 100) == nil, "garbage reading")
    }

    @Test(arguments: [
        (seconds: 900.0, label: "15m"),
        (seconds: 899.2, label: "15m"),   // rounds up: never shows less than is left
        (seconds: 59, label: "59s"),
        (seconds: 60, label: "1m"),
        (seconds: 3900, label: "1h 05m"),
        (seconds: 7200, label: "2h 00m"),
    ])
    func remainingLabel(_ row: (seconds: TimeInterval, label: String)) {
        #expect(CaffeinatePolicy.remainingLabel(row.seconds) == row.label)
    }
}
