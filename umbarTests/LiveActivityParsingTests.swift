//
//  LiveActivityParsingTests.swift
//  umbarTests
//
//  F19 live activities: the pure parsers and rules under
//  boringNotch/private/LiveActivities/ (DownloadParsing, PowerSourceParsing,
//  TimeMachineParsing, LiveActivityModel). No file system, no IOKit: every
//  input is a value built here.
//

import Foundation
import Testing

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ s: TimeInterval) -> Date { epoch.addingTimeInterval(s) }

// MARK: - Partial download names

@Suite("PartialDownloadName", .timeLimit(.minutes(1)))
struct PartialDownloadNameTests {
    @Test func safariBundle() {
        let p = PartialDownloadName(fileName: "Report Q3.pdf.download")
        #expect(p == PartialDownloadName(kind: .safari, finalName: "Report Q3.pdf"))
    }

    @Test func chromiumNamed() {
        let p = PartialDownloadName(fileName: "ubuntu-24.04.iso.crdownload")
        #expect(p?.kind == .chromium)
        #expect(p?.finalName == "ubuntu-24.04.iso")
    }

    @Test func chromiumUnconfirmedHasNoFinalName() {
        let p = PartialDownloadName(fileName: "Unconfirmed 482913.crdownload")
        #expect(p?.kind == .chromium)
        #expect(p?.finalName == nil)
    }

    @Test func unconfirmedPrefixWithWordsIsARealName() {
        #expect(PartialDownloadName(fileName: "Unconfirmed plans.txt.crdownload")?.finalName == "Unconfirmed plans.txt")
    }

    @Test func firefoxPart() {
        #expect(PartialDownloadName(fileName: "video.mp4.part") == PartialDownloadName(kind: .firefox, finalName: "video.mp4"))
    }

    @Test func suffixIsCaseInsensitive() {
        #expect(PartialDownloadName(fileName: "A.ZIP.CRDOWNLOAD")?.finalName == "A.ZIP")
    }

    @Test(arguments: ["report.pdf", ".hidden.download", ".download", ".crdownload", "download", "notes.partial", ""])
    func notPartial(_ name: String) {
        #expect(PartialDownloadName(fileName: name) == nil)
    }

    @Test func turkishAndEmojiNamesSurvive() {
        #expect(PartialDownloadName(fileName: "Şirket özeti 🚀.key.download")?.finalName == "Şirket özeti 🚀.key")
    }
}

// MARK: - Safari Info.plist

@Suite("SafariDownloadProgress", .timeLimit(.minutes(1)))
struct SafariDownloadProgressTests {
    @Test func knownTotal() throws {
        let p = try #require(SafariDownloadProgress.parse([
            "DownloadEntryProgressBytesSoFar": NSNumber(value: 25),
            "DownloadEntryProgressTotalToLoad": NSNumber(value: 100),
        ]))
        #expect(p.bytesSoFar == 25)
        #expect(p.totalBytes == 100)
        #expect(p.fraction == 0.25)
    }

    @Test(arguments: [0, -1])
    func unknownTotal(_ total: Int) throws {
        let p = try #require(SafariDownloadProgress.parse([
            "DownloadEntryProgressBytesSoFar": 4096, "DownloadEntryProgressTotalToLoad": total,
        ]))
        #expect(p.totalBytes == nil)
        #expect(p.fraction == nil)
    }

    @Test func missingTotalKey() {
        #expect(SafariDownloadProgress.parse(["DownloadEntryProgressBytesSoFar": 10])?.totalBytes == nil)
    }

    @Test func missingBytesIsNil() {
        #expect(SafariDownloadProgress.parse(["DownloadEntryProgressTotalToLoad": 100]) == nil)
        #expect(SafariDownloadProgress.parse([:]) == nil)
        #expect(SafariDownloadProgress.parse(["DownloadEntryProgressBytesSoFar": "12"]) == nil)
    }

    @Test func fractionClampsWhenServerLiedAboutLength() {
        let p = SafariDownloadProgress(bytesSoFar: 150, totalBytes: 100)
        #expect(p.fraction == 1)
    }

    @Test func largeFilesBeyond32Bits() throws {
        let big: Int64 = 6 * 1024 * 1024 * 1024
        let p = try #require(SafariDownloadProgress.parse([
            "DownloadEntryProgressBytesSoFar": NSNumber(value: big / 2),
            "DownloadEntryProgressTotalToLoad": NSNumber(value: big),
        ]))
        #expect(p.fraction == 0.5)
    }

    @Test(arguments: [PropertyListSerialization.PropertyListFormat.xml, .binary])
    func parsesSerializedPlist(_ format: PropertyListSerialization.PropertyListFormat) throws {
        // The shape Safari writes: the progress keys plus URL/path keys we ignore.
        let dict: [String: Any] = [
            "DownloadEntryProgressBytesSoFar": 1_048_576,
            "DownloadEntryProgressTotalToLoad": 4_194_304,
            "DownloadEntryURL": "https://example.com/a.zip",
            "DownloadEntryPath": "~/Downloads/a.zip.download/a.zip",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: format, options: 0)
        #expect(SafariDownloadProgress.parse(data: data)?.fraction == 0.25)
    }

    @Test func garbageDataIsNil() {
        #expect(SafariDownloadProgress.parse(data: Data("not a plist".utf8)) == nil)
        #expect(SafariDownloadProgress.parse(data: Data()) == nil)
    }
}

// MARK: - Transfer rate

@Suite("TransferRateEstimator", .timeLimit(.minutes(1)))
struct TransferRateEstimatorTests {
    @Test func needsTwoSamplesHalfASecondApart() {
        var r = TransferRateEstimator()
        #expect(r.bytesPerSecond == nil)
        r.record(bytes: 0, at: at(0))
        #expect(r.bytesPerSecond == nil)
        r.record(bytes: 100, at: at(0.2))
        #expect(r.bytesPerSecond == nil)
        r.record(bytes: 1000, at: at(1))
        #expect(r.bytesPerSecond == 1000)
    }

    @Test func steadyRateOverWindow() {
        var r = TransferRateEstimator(window: 3)
        for s in 0...10 { r.record(bytes: Int64(s) * 2_000, at: at(TimeInterval(s))) }
        #expect(r.bytesPerSecond == 2_000)
        // Window keeps about 3 s, not the whole history.
        #expect(r.samples.count <= 5)
    }

    @Test func followsASpeedChangeWithinTheWindow() {
        var r = TransferRateEstimator(window: 3)
        var bytes: Int64 = 0
        for s in 0...5 { bytes = Int64(s) * 1_000; r.record(bytes: bytes, at: at(TimeInterval(s))) }
        for s in 6...12 { bytes += 10_000; r.record(bytes: bytes, at: at(TimeInterval(s))) }
        #expect(r.bytesPerSecond == 10_000)
    }

    @Test func restartResets() {
        var r = TransferRateEstimator()
        r.record(bytes: 5_000, at: at(0))
        r.record(bytes: 9_000, at: at(1))
        r.record(bytes: 100, at: at(2))
        #expect(r.samples.count == 1)
        #expect(r.bytesPerSecond == nil)
    }

    @Test func clockGoingBackwardsResets() {
        var r = TransferRateEstimator()
        r.record(bytes: 0, at: at(10))
        r.record(bytes: 10, at: at(5))
        #expect(r.samples.count == 1)
    }

    @Test func stalledTransferIsZero() {
        var r = TransferRateEstimator()
        r.record(bytes: 500, at: at(0))
        r.record(bytes: 500, at: at(2))
        #expect(r.bytesPerSecond == 0)
    }
}

// MARK: - Listing diff

@Suite("DownloadsListingChange", .timeLimit(.minutes(1)))
struct DownloadsListingChangeTests {
    @Test func listingSplitsPartialsAndIgnoresHidden() {
        let l = DownloadsListing(entryNames: ["a.zip.download", "b.pdf", ".DS_Store", ".com.google.Chrome.x"])
        #expect(Set(l.partials.keys) == ["a.zip.download"])
        #expect(l.others == ["b.pdf"])
    }

    @Test func safariStartThenFinish() {
        let empty = DownloadsListing(entryNames: ["old.txt"])
        let running = DownloadsListing(entryNames: ["old.txt", "a.zip.download"])
        let done = DownloadsListing(entryNames: ["old.txt", "a.zip"])

        #expect(DownloadsListingChange.between(empty, running).started == ["a.zip.download"])
        let change = DownloadsListingChange.between(running, done)
        #expect(change.finished == [FinishedDownload(entry: "a.zip.download", finalName: "a.zip")])
        #expect(change.appeared.isEmpty, "the finished file is not an AirDrop candidate")
        #expect(change.vanished.isEmpty)
    }

    @Test func firefoxPlaceholderIsNotAnArrival() {
        let before = DownloadsListing(entryNames: [])
        // Firefox creates the empty final name and the .part together.
        let running = DownloadsListing(entryNames: ["v.mp4", "v.mp4.part"])
        let change = DownloadsListingChange.between(before, running)
        #expect(change.started == ["v.mp4.part"])
        #expect(change.appeared.isEmpty)

        let done = DownloadsListing(entryNames: ["v.mp4"])
        #expect(DownloadsListingChange.between(running, done).finished.map(\.finalName) == ["v.mp4"])
    }

    @Test func cancelledDownloadVanishes() {
        let running = DownloadsListing(entryNames: ["a.zip.crdownload"])
        let change = DownloadsListingChange.between(running, DownloadsListing(entryNames: []))
        #expect(change.vanished == ["a.zip.crdownload"])
        #expect(change.finished.isEmpty)
    }

    @Test func chromeUnconfirmedRenameIsVanishPlusStart() {
        let a = DownloadsListing(entryNames: ["Unconfirmed 1.crdownload"])
        let b = DownloadsListing(entryNames: ["setup.dmg.crdownload"])
        let change = DownloadsListingChange.between(a, b)
        #expect(change.vanished == ["Unconfirmed 1.crdownload"])
        #expect(change.started == ["setup.dmg.crdownload"])
        #expect(change.finished.isEmpty)
    }

    @Test func plainNewFileAppears() {
        let change = DownloadsListingChange.between(
            DownloadsListing(entryNames: ["x"]), DownloadsListing(entryNames: ["x", "photo.heic", "a.pdf"]))
        #expect(change.appeared == ["a.pdf", "photo.heic"])
    }

    @Test func noChange() {
        let l = DownloadsListing(entryNames: ["a", "b.part"])
        #expect(DownloadsListingChange.between(l, l).isEmpty)
    }

    @Test func manySimultaneousDownloadsAreSorted() {
        let names = (0..<50).map { "f\($0).bin.crdownload" }
        let change = DownloadsListingChange.between(DownloadsListing(), DownloadsListing(entryNames: names.shuffled()))
        #expect(change.started == names.sorted())
    }
}

// MARK: - Quarantine

@Suite("QuarantineRecord", .timeLimit(.minutes(1)))
struct QuarantineRecordTests {
    @Test func airDropBySharingd() throws {
        let r = try #require(QuarantineRecord.parse("0082;6720f1a0;sharingd;8F7E6D5C-0000-4000-8000-000000000001"))
        #expect(r.agent == "sharingd")
        #expect(r.isAirDrop)
        #expect(r.timestamp == Date(timeIntervalSince1970: 0x6720f1a0))
        #expect(r.eventID == "8F7E6D5C-0000-4000-8000-000000000001")
    }

    @Test func airDropAgentName() {
        #expect(QuarantineRecord.parse("0082;6720f1a0;AirDrop;")?.isAirDrop == true)
    }

    @Test func browserIsNotAirDrop() throws {
        let r = try #require(QuarantineRecord.parse("0083;6720f1a0;Safari;F00"))
        #expect(!r.isAirDrop)
        #expect(QuarantineRecord.parse("0081;6720f1a0;Google Chrome;")?.isAirDrop == false)
    }

    @Test func trailingNulFromGetxattr() {
        var data = Data("0082;6720f1a0;sharingd;".utf8)
        data.append(0)
        #expect(QuarantineRecord.parse(data: data)?.isAirDrop == true)
    }

    @Test(arguments: ["", "0082", "0082;abc", ";;sharingd;"])
    func malformed(_ raw: String) {
        #expect(QuarantineRecord.parse(raw) == nil)
    }

    @Test func badHexTimeStillParses() {
        let r = QuarantineRecord.parse("0082;zz;sharingd;")
        #expect(r?.timestamp == nil)
        #expect(r?.isRecentAirDrop(now: epoch) == true)
    }

    @Test func recentWindow() {
        let stamp = UInt64(epoch.timeIntervalSince1970)
        let r = QuarantineRecord.parse("0082;\(String(stamp, radix: 16));sharingd;")!
        #expect(r.isRecentAirDrop(now: at(60)))
        #expect(r.isRecentAirDrop(now: at(600)))
        #expect(!r.isRecentAirDrop(now: at(601)), "an old AirDrop file moved back into Downloads")
        let safari = QuarantineRecord.parse("0083;\(String(stamp, radix: 16));Safari;")!
        #expect(!safari.isRecentAirDrop(now: epoch))
    }
}

// MARK: - Power source

@Suite("PowerSourceParser", .timeLimit(.minutes(1)))
struct PowerSourceParserTests {
    /// The keys and value types IOPSGetPowerSourceDescription returns for an
    /// Apple laptop battery.
    private func battery(
        state: String = "AC Power", charging: Bool = true, charged: Bool? = false,
        current: Int = 50, max: Int = 100, toFull: Int? = 141, type: String? = "InternalBattery"
    ) -> [String: Any] {
        var d: [String: Any] = [
            "Power Source State": state,
            "Is Charging": NSNumber(value: charging),
            "Current Capacity": NSNumber(value: current),
            "Max Capacity": NSNumber(value: max),
        ]
        if let charged { d["Is Charged"] = NSNumber(value: charged) }
        if let toFull { d["Time to Full Charge"] = NSNumber(value: toFull) }
        if let type { d["Type"] = type }
        return d
    }

    @Test func chargingWithEstimate() {
        #expect(PowerSourceParser.chargingStatus(from: battery()) == ChargingStatus(percent: 50, minutesToFull: 141))
    }

    @Test func stillEstimating() {
        #expect(PowerSourceParser.chargingStatus(from: battery(toFull: -1))?.minutesToFull == nil)
        #expect(PowerSourceParser.chargingStatus(from: battery(toFull: nil))?.minutesToFull == nil)
        #expect(PowerSourceParser.chargingStatus(from: battery(toFull: 0))?.minutesToFull == nil)
    }

    @Test func onBattery() {
        #expect(PowerSourceParser.chargingStatus(from: battery(state: "Battery Power", charging: false)) == nil)
    }

    @Test func pluggedInButHeld() {
        // Optimized Battery Charging holding at 80 %: on AC, not charging.
        #expect(PowerSourceParser.chargingStatus(from: battery(charging: false, current: 80)) == nil)
    }

    @Test func fullyCharged() {
        #expect(PowerSourceParser.chargingStatus(from: battery(charged: true, current: 100)) == nil)
    }

    @Test func upsIsIgnored() {
        #expect(PowerSourceParser.chargingStatus(from: battery(type: "UPS")) == nil)
    }

    @Test func missingTypeIsAccepted() {
        #expect(PowerSourceParser.chargingStatus(from: battery(type: nil)) != nil)
    }

    @Test func rawCapacityIsScaled() {
        #expect(PowerSourceParser.chargingStatus(from: battery(current: 2176, max: 4439))?.percent == 49)
    }

    @Test func zeroMaxIsNil() {
        #expect(PowerSourceParser.chargingStatus(from: battery(max: 0)) == nil)
    }

    @Test func boolAsSwiftBool() {
        var d = battery()
        d["Is Charging"] = true
        #expect(PowerSourceParser.chargingStatus(from: d) != nil)
    }
}

// MARK: - Time Machine

@Suite("TimeMachinePlistParser", .timeLimit(.minutes(1)))
struct TimeMachinePlistParserTests {
    @Test func notConfigured() {
        // What both test Macs have on macOS 27.0.1.
        let plist: [String: Any] = ["PreferencesVersion": 6]
        #expect(!TimeMachinePlistParser.hasDestinations(plist))
        #expect(TimeMachinePlistParser.latestBackupDate(plist) == nil)
    }

    @Test func newestAcrossDestinations() {
        let plist: [String: Any] = [
            "Destinations": [
                ["DestinationID": "A", "SnapshotDates": [at(0), at(100)]],
                ["DestinationID": "B", "SnapshotDates": [at(50)]],
                ["DestinationID": "C"],
            ],
        ]
        #expect(TimeMachinePlistParser.hasDestinations(plist))
        #expect(TimeMachinePlistParser.latestBackupDate(plist) == at(100))
    }

    @Test func parsesSerialized() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["Destinations": [["SnapshotDates": [at(7)]]]], format: .binary, options: 0)
        let plist = try #require(TimeMachinePlistParser.parse(data: data))
        #expect(TimeMachinePlistParser.latestBackupDate(plist) == at(7))
    }

    @Test func finishDetection() {
        #expect(!TimeMachinePlistParser.didFinishBackup(previous: nil, current: at(5), isBaseline: true))
        #expect(TimeMachinePlistParser.didFinishBackup(previous: nil, current: at(5), isBaseline: false))
        #expect(TimeMachinePlistParser.didFinishBackup(previous: at(1), current: at(5), isBaseline: false))
        #expect(!TimeMachinePlistParser.didFinishBackup(previous: at(5), current: at(5), isBaseline: false))
        #expect(!TimeMachinePlistParser.didFinishBackup(previous: at(5), current: at(1), isBaseline: false))
        #expect(!TimeMachinePlistParser.didFinishBackup(previous: at(5), current: nil, isBaseline: false))
    }
}

// MARK: - Ranking

@Suite("LiveActivityRanking", .timeLimit(.minutes(1)))
struct LiveActivityRankingTests {
    private func item(
        _ id: String, _ kind: LiveActivityKind, _ phase: LiveActivity.Phase = .running,
        started: TimeInterval = 0, strip: TimeInterval? = nil, expires: TimeInterval? = nil
    ) -> LiveActivity {
        LiveActivity(id: id, kind: kind, phase: phase, title: id, startedAt: at(started),
                     stripUntil: strip.map(at), expiresAt: expires.map(at))
    }

    @Test func runningDownloadBeatsEverything() {
        let items = [
            item("c", .charging), item("t", .timeMachine, .finished),
            item("d", .download), item("a", .airDrop, .finished), item("f", .download, .finished),
        ]
        #expect(LiveActivityRanking.panelItems(items, now: epoch).map(\.id) == ["d", "a", "f", "t", "c"])
    }

    @Test func newestFirstWithinPriorityThenId() {
        let items = [item("x", .download, started: 1), item("y", .download, started: 5),
                     item("b", .download, started: 5)]
        #expect(LiveActivityRanking.panelItems(items, now: epoch).map(\.id) == ["b", "y", "x"])
    }

    @Test func expiry() {
        let items = [item("old", .download, .finished, strip: 8, expires: 120), item("c", .charging, strip: 8)]
        #expect(LiveActivityRanking.stripItems(items, now: at(7)).map(\.id) == ["old", "c"])
        #expect(LiveActivityRanking.stripItems(items, now: at(8)).isEmpty, "the strip boundary is exclusive")
        #expect(LiveActivityRanking.panelItems(items, now: at(119)).map(\.id) == ["old", "c"])
        #expect(LiveActivityRanking.panelItems(items, now: at(120)).map(\.id) == ["c"])
    }

    @Test func nextExpiry() {
        let items = [item("a", .download, .finished, strip: 8, expires: 120), item("d", .download)]
        #expect(LiveActivityRanking.nextExpiry(items, after: epoch) == at(8))
        #expect(LiveActivityRanking.nextExpiry(items, after: at(8)) == at(120))
        #expect(LiveActivityRanking.nextExpiry(items, after: at(120)) == nil)
        #expect(LiveActivityRanking.nextExpiry([], after: epoch) == nil)
    }
}
