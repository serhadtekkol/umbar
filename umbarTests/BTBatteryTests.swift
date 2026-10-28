//
//  BTBatteryTests.swift
//  umbarTests
//
//  F24 Bluetooth batteries: IORegistry parsing, the merge of the three
//  sources, the connect-glance rules and the system_profiler throttle.
//  Pure values only; nothing here touches the Mac's Bluetooth.
//

import Foundation
import Testing

private let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)
private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

@Suite("BTHIDBatteryParser", .timeLimit(.minutes(1)))
struct BTHIDBatteryParserTests {
    @Test func readsAppleHIDService() {
        let services: [[String: Any]] = [[
            "Product": "Magic Mouse",
            "DeviceAddress": "d4-61-9d-11-22-33",
            "BatteryPercent": NSNumber(value: 64),
            "PrimaryUsagePage": NSNumber(value: 1),
            "PrimaryUsage": NSNumber(value: 2),
        ]]
        #expect(BTHIDBatteryParser.parse(services) == [
            BTHIDBattery(id: "D4619D112233", name: "Magic Mouse", kind: .mouse, percent: 64),
        ])
    }

    @Test func skipsServicesWithoutAUsableLevel() {
        let services: [[String: Any]] = [
            ["Product": "Magic Keyboard", "DeviceAddress": "aa-bb-cc-dd-ee-ff"],  // wired, no battery
            ["Product": "Odd", "BatteryPercent": 101],
            ["Product": "Odder", "BatteryPercent": -1],
            ["Product": "Text", "BatteryPercent": "50"],
            ["BatteryPercent": 40],  // neither name nor address
        ]
        #expect(BTHIDBatteryParser.parse(services).isEmpty)
    }

    @Test func boundariesAreInclusive() {
        let services: [[String: Any]] = [
            ["Product": "Empty", "DeviceAddress": "01", "BatteryPercent": 0],
            ["Product": "Full", "DeviceAddress": "02", "BatteryPercent": 100],
        ]
        #expect(BTHIDBatteryParser.parse(services).map(\.percent) == [0, 100])
    }

    @Test func dedupesInterfacesOfOneDeviceKeepingTheFirst() {
        let services: [[String: Any]] = [
            ["Product": "Magic Keyboard", "DeviceAddress": "AA:BB:CC:DD:EE:FF", "BatteryPercent": 70],
            ["Product": "Magic Keyboard", "DeviceAddress": "aa-bb-cc-dd-ee-ff", "BatteryPercent": 69],
        ]
        let parsed = BTHIDBatteryParser.parse(services)
        #expect(parsed.count == 1)
        #expect(parsed.first?.percent == 70)
        #expect(parsed.first?.kind == .keyboard)
    }

    @Test func noAddressFallsBackToNameKey() {
        let parsed = BTHIDBatteryParser.parse([["Product": " Magic Trackpad ", "BatteryPercent": 9]])
        #expect(parsed == [BTHIDBattery(id: "name:Magic Trackpad", name: "Magic Trackpad", kind: .trackpad, percent: 9)])
    }

    @Test func classify() {
        #expect(BTDeviceKind.classify(name: "MX Master 3S", primaryUsagePage: 1, primaryUsage: 2) == .mouse)
        #expect(BTDeviceKind.classify(name: "Magic Keyboard with Touch ID", primaryUsagePage: nil, primaryUsage: nil) == .keyboard)
        #expect(BTDeviceKind.classify(name: "Magic Trackpad", primaryUsagePage: 1, primaryUsage: 2) == .trackpad)
        #expect(BTDeviceKind.classify(name: "Serhad's AirPods Pro", primaryUsagePage: nil, primaryUsage: nil) == .headphones)
        #expect(BTDeviceKind.classify(name: "Speaker", primaryUsagePage: nil, primaryUsage: nil, isAudio: true) == .headphones)
        #expect(BTDeviceKind.classify(name: "Game Controller", primaryUsagePage: 1, primaryUsage: 5) == .other)
    }
}

@Suite("BTBatteryMerge", .timeLimit(.minutes(1)))
struct BTBatteryMergeTests {
    private let airpods = BTConnectedDevice(id: "40B3FA019A7B", name: "AirPods Pro", isAudio: true)
    private let mouse = BTConnectedDevice(id: "D4619D112233", name: "Magic Mouse", isAudio: false)

    @Test func airPodsGetEarAndCaseLevelsFromTheProfiler() {
        let rows = BTBatteryMerge.merge(
            connected: [airpods],
            profiler: ["40B3FA019A7B": QuickBattery(left: 100, right: 98, caseLevel: 73)],
            hid: [])
        #expect(rows == [BTBatteryDevice(id: "40B3FA019A7B", name: "AirPods Pro", kind: .headphones,
                                         battery: QuickBattery(left: 100, right: 98, caseLevel: 73))])
    }

    @Test func liveHIDLevelReplacesTheProfilersSingleValue() {
        let rows = BTBatteryMerge.merge(
            connected: [mouse],
            profiler: ["D4619D112233": QuickBattery(single: 70)],
            hid: [BTHIDBattery(id: "D4619D112233", name: "Magic Mouse 2", kind: .mouse, percent: 64)])
        #expect(rows.count == 1)
        #expect(rows.first?.battery == QuickBattery(single: 64))
        #expect(rows.first?.name == "Magic Mouse", "IOBluetooth's name is the one the user set")
    }

    @Test func profilerLevelsOfDisconnectedDevicesAreIgnored() {
        let rows = BTBatteryMerge.merge(
            connected: [],
            profiler: ["40B3FA019A7B": QuickBattery(left: 100, right: 100, caseLevel: 73)],
            hid: [])
        #expect(rows.isEmpty)
    }

    @Test func withoutBluetoothPermissionHIDStillShows() {
        let rows = BTBatteryMerge.merge(
            connected: [], profiler: [:],
            hid: [BTHIDBattery(id: "AA", name: "Magic Trackpad", kind: .trackpad, percent: 40)])
        #expect(rows.map(\.name) == ["Magic Trackpad"])
    }

    @Test func connectedDevicesWithNoLevelAreLeftOut() {
        let rows = BTBatteryMerge.merge(connected: [airpods, mouse], profiler: [:], hid: [])
        #expect(rows.isEmpty)
    }

    @Test func headphonesFirstThenByName() {
        let rows = BTBatteryMerge.merge(
            connected: [airpods], profiler: ["40B3FA019A7B": QuickBattery(single: 50)],
            hid: [
                BTHIDBattery(id: "2", name: "Magic Trackpad", kind: .trackpad, percent: 1),
                BTHIDBattery(id: "1", name: "Magic Keyboard", kind: .keyboard, percent: 1),
            ])
        #expect(rows.map(\.name) == ["AirPods Pro", "Magic Keyboard", "Magic Trackpad"])
    }

    @Test func emptyInputs() {
        #expect(BTBatteryMerge.merge(connected: [], profiler: [:], hid: []).isEmpty)
    }
}

@Suite("BTConnectGlancePolicy", .timeLimit(.minutes(1)))
struct BTConnectGlancePolicyTests {
    @Test func devicesAlreadyConnectedAtStartAreSilent() {
        var policy = BTConnectGlancePolicy(startedAt: epoch)
        let r1 = policy.shouldAnnounce("A", at: at(0))
        #expect(!r1)
        let r2 = policy.shouldAnnounce("A", at: at(4.9))
        #expect(!r2)
        let r3 = policy.shouldAnnounce("A", at: at(5))
        #expect(r3, "the baseline window ends exactly at 5 s")
    }

    @Test func oneGlancePerDevicePerMinute() {
        var policy = BTConnectGlancePolicy(startedAt: epoch)
        let r4 = policy.shouldAnnounce("A", at: at(10))
        #expect(r4)
        let r5 = policy.shouldAnnounce("A", at: at(11))
        #expect(!r5, "IOBluetooth and HID report the same connect")
        let r6 = policy.shouldAnnounce("A", at: at(69.9))
        #expect(!r6)
        let r7 = policy.shouldAnnounce("A", at: at(70))
        #expect(r7)
    }

    @Test func devicesAreIndependent() {
        var policy = BTConnectGlancePolicy(startedAt: epoch)
        let r8 = policy.shouldAnnounce("A", at: at(10))
        #expect(r8)
        let r9 = policy.shouldAnnounce("B", at: at(10))
        #expect(r9)
    }

    @Test func suppressedConnectsDoNotStartTheCooldown() {
        var policy = BTConnectGlancePolicy(startedAt: epoch)
        _ = policy.shouldAnnounce("A", at: at(1))
        let r10 = policy.shouldAnnounce("A", at: at(6))
        #expect(r10)
    }

    @Test func glanceIsAThreeSecondStripItemThatSkipsThePanel() {
        let glance = LiveActivity.bluetoothConnected(
            id: "A", name: "AirPods Pro", battery: QuickBattery(left: 80, right: 60, caseLevel: 30), now: epoch)
        #expect(glance.kind == .bluetooth)
        #expect(glance.title == "AirPods Pro")
        #expect(glance.percent == 60, "the headline is the lower bud")
        #expect(LiveActivityRanking.stripItems([glance], now: at(2.9)).count == 1)
        #expect(LiveActivityRanking.stripItems([glance], now: at(3)).isEmpty)
        #expect(LiveActivityRanking.panelItems([glance], now: at(3)).isEmpty)
    }

    @Test func emptyBatteryIsDroppedSoTheGlanceSaysConnected() {
        let glance = LiveActivity.bluetoothConnected(id: "A", name: "JBL", battery: QuickBattery(), now: epoch)
        #expect(glance.battery == nil)
        #expect(glance.percent == nil)
    }

    @Test func glanceOutranksARunningDownload() {
        let download = LiveActivity(id: "d", kind: .download, phase: .running, title: "x", startedAt: at(100))
        let glance = LiveActivity.bluetoothConnected(id: "A", name: "Mouse", battery: QuickBattery(single: 5), now: epoch)
        #expect(LiveActivityRanking.stripItems([download, glance], now: at(1)).first?.kind == .bluetooth)
    }
}

@Suite("BTProfilerPolicy", .timeLimit(.minutes(1)))
struct BTProfilerPolicyTests {
    @Test func neverWithoutAudio() {
        #expect(!BTProfilerPolicy.shouldRun(hasConnectedAudio: false, lastRun: nil, now: epoch, forced: true))
    }

    @Test func throttledToOncePerMinuteUnlessForced() {
        #expect(BTProfilerPolicy.shouldRun(hasConnectedAudio: true, lastRun: nil, now: epoch, forced: false))
        #expect(!BTProfilerPolicy.shouldRun(hasConnectedAudio: true, lastRun: epoch, now: at(59.9), forced: false))
        #expect(BTProfilerPolicy.shouldRun(hasConnectedAudio: true, lastRun: epoch, now: at(60), forced: false))
        #expect(BTProfilerPolicy.shouldRun(hasConnectedAudio: true, lastRun: epoch, now: at(1), forced: true))
    }
}
