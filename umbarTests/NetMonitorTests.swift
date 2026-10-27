//
//  NetMonitorTests.swift
//  umbarTests
//
//  F17 network traffic: counter deltas (resets, bad reads), smoothing, the
//  60 s history, unit formatting, and the per-network ledger (days, month,
//  retention, reset, file round trip). The sysctl/configd reads and the
//  NWPathMonitor glue (NetSystemProbe, NetMonitor) are not exercised here;
//  they were checked live against `netstat -ib`.
//

import Foundation
import Testing

private func snap(_ rx: UInt64, _ tx: UInt64, at time: TimeInterval) -> NetCounterSnapshot {
    NetCounterSnapshot(rx: rx, tx: tx, time: time)
}

private let posix = Locale(identifier: "en_US_POSIX")

@Suite("NetCounterMath")
struct NetCounterMathTests {
    @Test func deltaIsTheDifferenceOverTheInterval() throws {
        let delta = try #require(NetCounterMath.delta(from: snap(1_000, 500, at: 10), to: snap(3_000, 900, at: 12)))
        #expect(delta == NetTrafficDelta(rx: 2_000, tx: 400, interval: 2))
        #expect(delta.rxRate == 1_000)
        #expect(delta.txRate == 200)
    }

    @Test func noTimeElapsedGivesNoDelta() {
        #expect(NetCounterMath.delta(from: snap(1, 1, at: 5), to: snap(9, 9, at: 5)) == nil)
        #expect(NetCounterMath.delta(from: snap(1, 1, at: 5), to: snap(9, 9, at: 4)) == nil)
    }

    @Test func aCounterThatWentDownIsAResetAndCountsFromZero() throws {
        let delta = try #require(NetCounterMath.delta(from: snap(5_000_000, 70, at: 0), to: snap(1_200, 80, at: 1)))
        #expect(delta.rx == 1_200)
        #expect(delta.tx == 10)
    }

    @Test func aPhysicallyImpossibleJumpIsDiscarded() {
        // 13 GB in one second is above the 100 Gbit/s plausibility limit.
        #expect(NetCounterMath.delta(from: snap(0, 0, at: 0), to: snap(13_000_000_000, 0, at: 1)) == nil)
        // The same bytes over two seconds are plausible.
        #expect(NetCounterMath.delta(from: snap(0, 0, at: 0), to: snap(13_000_000_000, 0, at: 2)) != nil)
    }

    @Test func noTrafficIsAZeroDeltaNotNil() {
        #expect(NetCounterMath.delta(from: snap(7, 7, at: 0), to: snap(7, 7, at: 1)) == NetTrafficDelta(rx: 0, tx: 0, interval: 1))
    }
}

@Suite("NetRateSmoother")
struct NetRateSmootherTests {
    @Test func firstSampleIsTakenAsIs() {
        var smoother = NetRateSmoother()
        smoother.add(NetTrafficDelta(rx: 4_000, tx: 1_000, interval: 1))
        #expect(smoother.rx == 4_000)
        #expect(smoother.tx == 1_000)
    }

    @Test func convergesTowardsASteadyRate() {
        var smoother = NetRateSmoother()
        smoother.add(NetTrafficDelta(rx: 0, tx: 0, interval: 1))
        for _ in 0..<10 { smoother.add(NetTrafficDelta(rx: 1_000_000, tx: 0, interval: 1)) }
        #expect(abs(smoother.rx - 1_000_000) < 2_000)
    }

    @Test func longerSamplesMoveTheAverageFurther() {
        var oneSecond = NetRateSmoother()
        oneSecond.add(NetTrafficDelta(rx: 0, tx: 0, interval: 1))
        oneSecond.add(NetTrafficDelta(rx: 1_000, tx: 0, interval: 1))
        var fiveSeconds = NetRateSmoother()
        fiveSeconds.add(NetTrafficDelta(rx: 0, tx: 0, interval: 5))
        fiveSeconds.add(NetTrafficDelta(rx: 5_000, tx: 0, interval: 5))
        #expect(fiveSeconds.rx > oneSecond.rx)
    }

    @Test func decaysToExactlyZeroWhenIdle() {
        var smoother = NetRateSmoother()
        smoother.add(NetTrafficDelta(rx: 50_000, tx: 50_000, interval: 1))
        for _ in 0..<60 { smoother.add(NetTrafficDelta(rx: 0, tx: 0, interval: 1)) }
        #expect(smoother.rx == 0)
        #expect(smoother.tx == 0)
    }
}

@Suite("NetRateHistory")
struct NetRateHistoryTests {
    @Test func keepsOnlyTheLastWindowOfSeconds() {
        var history = NetRateHistory()
        for second in 0...100 { history.append(NetRatePoint(time: TimeInterval(second), rx: 1, tx: 1)) }
        #expect(history.points.first?.time == 40)
        #expect(history.points.last?.time == 100)
        #expect(history.points.count == 61)
    }

    @Test func ignoresPointsThatAreNotNewer() {
        var history = NetRateHistory()
        history.append(NetRatePoint(time: 10, rx: 1, tx: 1))
        history.append(NetRatePoint(time: 10, rx: 2, tx: 2))
        history.append(NetRatePoint(time: 9, rx: 3, tx: 3))
        #expect(history.points.count == 1)
    }

    @Test func peakIsNeverZero() {
        var history = NetRateHistory()
        #expect(history.peak == 1)
        history.append(NetRatePoint(time: 1, rx: 300, tx: 900))
        #expect(history.peak == 900)
    }
}

@Suite("NetByteFormat")
struct NetByteFormatTests {
    @Test func ratesUseDecimalUnits() {
        #expect(NetByteFormat.rate(0, locale: posix) == "0 B/s")
        #expect(NetByteFormat.rate(999, locale: posix) == "999 B/s")
        #expect(NetByteFormat.rate(1_000, locale: posix) == "1.0 KB/s")
        #expect(NetByteFormat.rate(850_000, locale: posix) == "850 KB/s")
        #expect(NetByteFormat.rate(1_234_567, locale: posix) == "1.2 MB/s")
        #expect(NetByteFormat.rate(12_340_000, locale: posix) == "12 MB/s")
    }

    @Test func neverShowsAFourDigitNumber() {
        // 999.7 KB/s would round to "1000 KB/s"; it becomes "1.0 MB/s".
        #expect(NetByteFormat.rate(999_700, locale: posix) == "1.0 MB/s")
        #expect(NetByteFormat.rate(999.6, locale: posix) == "1.0 KB/s")
    }

    @Test func badValuesShowZero() {
        #expect(NetByteFormat.rate(-5, locale: posix) == "0 B/s")
        #expect(NetByteFormat.rate(.nan, locale: posix) == "0 B/s")
        #expect(NetByteFormat.rate(.infinity, locale: posix) == "0 B/s")
    }

    @Test func totalsCarryOneMoreDigit() {
        #expect(NetByteFormat.total(0, locale: posix) == "0 B")
        #expect(NetByteFormat.total(1_240_000_000, locale: posix) == "1.24 GB")
        #expect(NetByteFormat.total(45_600_000, locale: posix) == "45.6 MB")
        #expect(NetByteFormat.total(512_000, locale: posix) == "512 KB")
    }

    @Test func decimalSeparatorFollowsTheLocale() {
        #expect(NetByteFormat.rate(1_234_567, locale: Locale(identifier: "tr_TR")) == "1,2 MB/s")
    }

    @Test func compactFormFitsTheEar() {
        #expect(NetByteFormat.compactRate(0, locale: posix) == "0")
        #expect(NetByteFormat.compactRate(512, locale: posix) == "512")
        #expect(NetByteFormat.compactRate(850_000, locale: posix) == "850K")
        #expect(NetByteFormat.compactRate(1_234_567, locale: posix) == "1.2M")
        #expect(NetByteFormat.compactRate(56_000_000, locale: posix) == "56M")
    }
}

@Suite("NetUsageLedger")
struct NetUsageLedgerTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private let home = NetNetworkKey.make(.systemSignature("IPv4.Router=192.168.1.1;IPv4.RouterHardwareAddress=aa:bb:cc:dd:ee:ff"), kind: .wifi)
    private let office = NetNetworkKey.make(.systemSignature("IPv4.Router=10.0.0.1;IPv4.RouterHardwareAddress=11:22:33:44:55:66"), kind: .ethernet)

    @Test func dayKeysAreLocalCalendarDays() {
        // 23:30 in Istanbul is 20:30 UTC: still the same local day.
        #expect(NetDayKey.key(for: date(2026, 10, 27, hour: 23), calendar: calendar) == "2026-10-27")
        #expect(NetDayKey.key(for: date(2026, 10, 28, hour: 0), calendar: calendar) == "2026-10-28")
        #expect(NetDayKey.monthPrefix(for: date(2026, 3, 5), calendar: calendar) == "2026-03")
    }

    @Test func creditsAddUpPerNetworkAndDay() {
        var ledger = NetUsageLedger()
        let now = date(2026, 10, 27)
        ledger.credit(home, kind: .wifi, day: "2026-10-27", rx: 100, tx: 10)
        ledger.credit(home, kind: .wifi, day: "2026-10-27", rx: 50, tx: 5)
        ledger.credit(home, kind: .wifi, day: "2026-10-26", rx: 1_000, tx: 100)
        ledger.credit(office, kind: .ethernet, day: "2026-10-27", rx: 7, tx: 7)
        #expect(ledger.today(home, now: now, calendar: calendar) == NetByteTotals(rx: 150, tx: 15))
        #expect(ledger.month(home, now: now, calendar: calendar) == NetByteTotals(rx: 1_150, tx: 115))
        #expect(ledger.today(office, now: now, calendar: calendar) == NetByteTotals(rx: 7, tx: 7))
    }

    @Test func monthExcludesThePreviousMonth() {
        var ledger = NetUsageLedger()
        ledger.credit(home, kind: .wifi, day: "2026-09-30", rx: 999, tx: 999)
        ledger.credit(home, kind: .wifi, day: "2026-10-01", rx: 1, tx: 2)
        #expect(ledger.month(home, now: date(2026, 10, 1), calendar: calendar) == NetByteTotals(rx: 1, tx: 2))
    }

    @Test func zeroCreditsDoNotCreateANetwork() {
        var ledger = NetUsageLedger()
        ledger.credit(home, kind: .wifi, day: "2026-10-27", rx: 0, tx: 0)
        #expect(ledger.networks.isEmpty)
    }

    @Test func pruneDropsOldDaysButKeepsTheWholeCurrentMonth() {
        var ledger = NetUsageLedger()
        ledger.credit(home, kind: .wifi, day: "2026-12-01", rx: 1, tx: 1)   // 30 days before the 31st, same month
        ledger.credit(home, kind: .wifi, day: "2026-11-15", rx: 1, tx: 1)   // older than 30 days, last month
        ledger.credit(home, kind: .wifi, day: "2026-12-31", rx: 1, tx: 1)
        ledger.credit(office, kind: .ethernet, day: "2026-10-01", rx: 1, tx: 1)
        ledger.prune(now: date(2026, 12, 31), calendar: calendar)
        #expect(ledger.networks[home.rawValue]?.days.keys.sorted() == ["2026-12-01", "2026-12-31"])
        #expect(ledger.networks[office.rawValue] == nil)
    }

    @Test func pruneKeepsTheLastThirtyDaysAcrossAMonthBoundary() {
        var ledger = NetUsageLedger()
        ledger.credit(home, kind: .wifi, day: "2026-10-05", rx: 1, tx: 1)   // 27 days before
        ledger.credit(home, kind: .wifi, day: "2026-10-01", rx: 1, tx: 1)   // 31 days before
        ledger.prune(now: date(2026, 11, 1), calendar: calendar)
        #expect(ledger.networks[home.rawValue]?.days.keys.sorted() == ["2026-10-05"])
    }

    @Test func resetForgetsOnlyThatNetwork() {
        var ledger = NetUsageLedger()
        ledger.credit(home, kind: .wifi, day: "2026-10-27", rx: 1, tx: 1)
        ledger.credit(office, kind: .ethernet, day: "2026-10-27", rx: 1, tx: 1)
        ledger.reset(home)
        #expect(ledger.networks[home.rawValue] == nil)
        #expect(ledger.networks[office.rawValue] != nil)
        ledger.removeAll()
        #expect(ledger.networks.isEmpty)
    }

    @Test func totalsSaturateInsteadOfTrapping() {
        var totals = NetByteTotals(rx: .max - 1, tx: 0)
        totals.add(rx: 10, tx: 1)
        #expect(totals.rx == .max)
        #expect(totals.tx == 1)
    }

    @Test func labelIsKeptAndEmptyLabelsIgnored() {
        var ledger = NetUsageLedger()
        ledger.credit(home, kind: .wifi, day: "2026-10-27", rx: 1, tx: 1)
        ledger.setLabel("Ev", for: home, kind: .wifi)
        ledger.setLabel("", for: home, kind: .wifi)
        ledger.setLabel(nil, for: home, kind: .wifi)
        #expect(ledger.label(home) == "Ev")
    }
}

@Suite("NetNetworkKey")
struct NetNetworkKeyTests {
    @Test func sameSignatureSameKeyRegardlessOfCase() {
        let a = NetNetworkKey.make(.systemSignature("IPv4.Router=192.168.1.1;IPv4.RouterHardwareAddress=AA:BB:CC:DD:EE:FF"), kind: .wifi)
        let b = NetNetworkKey.make(.systemSignature("ipv4.router=192.168.1.1;ipv4.routerhardwareaddress=aa:bb:cc:dd:ee:ff"), kind: .wifi)
        #expect(a == b)
        #expect(a.rawValue.count == 32)
    }

    @Test func kindAndBasisSeparateNetworks() {
        let signature = NetNetworkKey.Basis.systemSignature("IPv4.Router=192.168.1.1;IPv4.RouterHardwareAddress=aa:bb:cc:dd:ee:ff")
        #expect(NetNetworkKey.make(signature, kind: .wifi) != NetNetworkKey.make(signature, kind: .ethernet))
        #expect(NetNetworkKey.make(.routerIP("192.168.1.1", interface: "en0"), kind: .wifi)
            != NetNetworkKey.make(.routerIP("192.168.1.1", interface: "en1"), kind: .wifi))
        #expect(NetNetworkKey.make(.interfaceOnly("en0"), kind: .wifi)
            != NetNetworkKey.make(.routerIP("192.168.1.1", interface: "en0"), kind: .wifi))
    }

    @Test func keyDoesNotContainTheHardwareAddress() {
        let key = NetNetworkKey.make(.systemSignature("IPv4.Router=192.168.1.1;IPv4.RouterHardwareAddress=aa:bb:cc:dd:ee:ff"), kind: .wifi)
        #expect(!key.rawValue.contains("aa:bb"))
        #expect(key.rawValue.allSatisfy { $0.isHexDigit })
    }
}

@Suite("NetUsageFile")
struct NetUsageFileTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NetUsageFileTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("NetMonitor", isDirectory: true)
            .appendingPathComponent("usage.json")
    }

    @Test func roundTripsAndCreatesTheFolder() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        var ledger = NetUsageLedger()
        let key = NetNetworkKey.make(.interfaceOnly("en0"), kind: .ethernet)
        ledger.credit(key, kind: .ethernet, day: "2026-10-27", rx: 123_456_789_012, tx: 42)
        try NetUsageFile(url: url).save(ledger)
        #expect(NetUsageFile(url: url).load() == ledger)
    }

    @Test func missingOrCorruptFileLoadsEmpty() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(NetUsageFile(url: url).load() == NetUsageLedger())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        #expect(NetUsageFile(url: url).load() == NetUsageLedger())
    }

    @Test func otherVersionLoadsEmpty() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":99,"networks":{}}"#.utf8).write(to: url)
        #expect(NetUsageFile(url: url).load() == NetUsageLedger())
    }

    @Test func defaultLocationIsKeyedByBundleID() {
        let url = NetUsageFile.defaultURL(bundleID: "com.emrullah.qanet")
        #expect(url.path.hasSuffix("Application Support/com.emrullah.qanet/NetMonitor/usage.json"))
    }
}
