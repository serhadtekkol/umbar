//
//  HeadphoneConnectTests.swift
//  umbarTests
//
//  The headphone connect glance's rules: which Core Audio devices count, the
//  glyph a model gets, and which appearances are announced (launch baseline,
//  per-device debounce, sleep and wake). Pure values only; nothing here
//  touches Core Audio or plays a sound.
//

import Foundation
import Testing

private let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)
private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

private func fourCC(_ code: String) -> UInt32 {
    code.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

private let pods = HeadphoneOutput(id: "AC9085123456", name: "Serhad's AirPods Pro", model: .airPodsPro)
private let podsMax = HeadphoneOutput(id: "AC9085ABCDEF", name: "AirPods Max", model: .airPodsMax)

/// Started at `epoch` with nothing connected; `t` past the launch grace.
private func freshPolicy() -> HeadphoneGlancePolicy {
    HeadphoneGlancePolicy(baseline: [], startedAt: epoch)
}

private let afterGrace = HeadphoneGlancePolicy.launchGrace + 1

@Suite("HeadphoneModel", .timeLimit(.minutes(1)))
struct HeadphoneModelTests {
    @Test func productIDWinsOverARenamedDevice() {
        #expect(HeadphoneModel.classify(name: "Kulaklığım", productID: 0x2024) == .airPodsPro)
        #expect(HeadphoneModel.classify(name: "AirPods", productID: 0x200A) == .airPodsMax)
    }

    @Test func unknownProductIDFallsBackToTheName() {
        #expect(HeadphoneModel.classify(name: "AirPods Max", productID: 0x20FE) == .airPodsMax)
    }

    @Test(arguments: [
        ("Serhad's AirPods Pro", HeadphoneModel.airPodsPro),
        ("AirPods Max", .airPodsMax),
        ("AirPods", .airPods),
        ("Beats Fit Pro", .beatsFitPro),
        ("Beats Studio Buds +", .beatsStudioBuds),
        ("Beats Studio Pro", .beatsHeadphones),
        ("Beats Solo3", .beatsHeadphones),
        ("Beats Flex", .beatsEarphones),
        ("Powerbeats Pro", .powerbeatsPro),
        ("Beats Pill", .speaker),
        ("Bose SoundLink Flex", .speaker),
        ("Salon hoparlörü", .speaker),
        ("WH-1000XM5", .headphones),
        ("", .headphones),
    ])
    func classifiesByName(name: String, expected: HeadphoneModel) {
        #expect(HeadphoneModel.classify(name: name, productID: nil) == expected)
    }

    @Test func everyModelHasASymbol() {
        #expect(HeadphoneModel.allCases.allSatisfy { !$0.symbol.isEmpty })
        #expect(Set(HeadphoneModel.allCases.map(\.symbol)).count == HeadphoneModel.allCases.count)
    }
}

@Suite("HeadphoneDeviceInfo", .timeLimit(.minutes(1)))
struct HeadphoneDeviceInfoTests {
    @Test func transportConstantsAreCoreAudios() {
        #expect(HeadphoneDeviceInfo.bluetoothTransports == [fourCC("blue"), fourCC("blea")])
    }

    @Test func onlyBluetoothOutputsCount() {
        #expect(HeadphoneDeviceInfo.isHeadphoneOutput(transport: fourCC("blue"), outputStreams: 1))
        #expect(HeadphoneDeviceInfo.isHeadphoneOutput(transport: fourCC("blea"), outputStreams: 2))
        // A headset's separate microphone device.
        #expect(!HeadphoneDeviceInfo.isHeadphoneOutput(transport: fourCC("blue"), outputStreams: 0))
        // Built-in speakers, USB, HDMI, AirPlay, virtual devices.
        for other in ["bltn", "usb ", "hdmi", "airp", "virt"] {
            #expect(!HeadphoneDeviceInfo.isHeadphoneOutput(transport: fourCC(other), outputStreams: 1))
        }
    }

    @Test func readsTheAddressInAUID() {
        #expect(HeadphoneDeviceInfo.address(fromUID: "AC-90-85-12-34-56:output") == "AC9085123456")
        #expect(HeadphoneDeviceInfo.address(fromUID: "ac:90:85:12:34:56") == "AC9085123456")
        #expect(HeadphoneDeviceInfo.address(fromUID: "BuiltInSpeakerDevice") == nil)
        // Mixed separators are not an address.
        #expect(HeadphoneDeviceInfo.address(fromUID: "AC-90:85-12:34-56") == nil)
    }

    @Test func outputFallsBackToTheUIDAsID() {
        let output = HeadphoneDeviceInfo.output(uid: "SomeLEDevice", name: "AirPods Pro", modelUID: nil)
        #expect(output == HeadphoneOutput(id: "SomeLEDevice", name: "AirPods Pro", model: .airPodsPro))
    }

    @Test func productIDFromAModelUIDNeedsApplesVendor() {
        #expect(HeadphoneDeviceInfo.appleProductID(fromModelUID: "2024 4c") == 0x2024)
        #expect(HeadphoneDeviceInfo.appleProductID(fromModelUID: "004C:200A") == 0x200A)
        #expect(HeadphoneDeviceInfo.appleProductID(fromModelUID: "2024 54c") == nil)
        #expect(HeadphoneDeviceInfo.appleProductID(fromModelUID: "Speaker") == nil)
        #expect(HeadphoneDeviceInfo.appleProductID(fromModelUID: "") == nil)
    }

    @Test func outputUsesTheModelUIDsProductID() {
        let output = HeadphoneDeviceInfo.output(uid: "AC-90-85-12-34-56:output", name: "Kulaklık", modelUID: "2024 4c")
        #expect(output == HeadphoneOutput(id: "AC9085123456", name: "Kulaklık", model: .airPodsPro))
    }
}

@Suite("HeadphoneGlancePolicy", .timeLimit(.minutes(1)))
struct HeadphoneGlancePolicyTests {
    @Test func whatIsConnectedAtLaunchIsNeverAnnounced() {
        var policy = HeadphoneGlancePolicy(baseline: [pods], startedAt: epoch)
        #expect(policy.update([pods], at: at(afterGrace)).isEmpty)
    }

    @Test func connectsInsideTheLaunchGraceAreBaseline() {
        var policy = freshPolicy()
        #expect(policy.update([pods], at: at(HeadphoneGlancePolicy.launchGrace - 0.01)).isEmpty)
        // And it is known now: no late announcement either.
        #expect(policy.update([pods], at: at(afterGrace)).isEmpty)
    }

    @Test func connectAndDisconnectAfterLaunchAreAnnounced() {
        var policy = freshPolicy()
        #expect(policy.update([pods], at: at(afterGrace)) == [.connected(pods)])
        let later = afterGrace + HeadphoneGlancePolicy.debounce
        #expect(policy.update([], at: at(later)) == [.disconnected(pods)])
    }

    @Test func aFlappingDeviceIsAnnouncedOncePerWindow() {
        var policy = freshPolicy()
        let t = afterGrace
        #expect(policy.update([pods], at: at(t)) == [.connected(pods)])
        #expect(policy.update([], at: at(t + 2)).isEmpty)
        #expect(policy.update([pods], at: at(t + HeadphoneGlancePolicy.debounce - 0.01)).isEmpty)
        #expect(policy.update([], at: at(t + HeadphoneGlancePolicy.debounce)) == [.disconnected(pods)])
    }

    @Test func theDebounceIsPerDevice() {
        var policy = freshPolicy()
        let t = afterGrace
        #expect(policy.update([pods], at: at(t)) == [.connected(pods)])
        #expect(policy.update([pods, podsMax], at: at(t + 1)) == [.connected(podsMax)])
    }

    @Test func aSwitchReportsTheDisconnectThenTheConnect() {
        var policy = HeadphoneGlancePolicy(baseline: [pods], startedAt: epoch)
        let events = policy.update([podsMax], at: at(afterGrace))
        #expect(events == [.disconnected(pods), .connected(podsMax)])
        #expect(HeadphoneGlancePolicy.headline(events) == .connected(podsMax))
    }

    @Test func headlineFallsBackToTheLastDisconnect() {
        #expect(HeadphoneGlancePolicy.headline([]) == nil)
        #expect(HeadphoneGlancePolicy.headline([.disconnected(pods), .disconnected(podsMax)]) == .disconnected(podsMax))
    }

    @Test func aDeviceListedTwiceIsOneDevice() {
        var policy = freshPolicy()
        #expect(policy.update([pods, pods], at: at(afterGrace)) == [.connected(pods)])
    }

    @Test func nothingIsAnnouncedWhileAsleep() {
        var policy = HeadphoneGlancePolicy(baseline: [pods], startedAt: epoch)
        policy.noteSleep(at: at(100))
        #expect(policy.update([], at: at(101)).isEmpty)
        #expect(policy.update([podsMax], at: at(102)).isEmpty)
    }

    @Test func reconnectingAfterWakeIsSilentForDevicesThatWereConnected() {
        var policy = HeadphoneGlancePolicy(baseline: [pods], startedAt: epoch)
        policy.noteSleep(at: at(100))
        policy.noteWake(at: at(1_000))
        #expect(policy.update([], at: at(1_001)).isEmpty)
        #expect(policy.update([pods], at: at(1_000 + HeadphoneGlancePolicy.wakeGrace - 0.01)).isEmpty)
    }

    @Test func aNewDeviceRightAfterWakeIsStillAnnounced() {
        var policy = HeadphoneGlancePolicy(baseline: [pods], startedAt: epoch)
        policy.noteSleep(at: at(100))
        policy.noteWake(at: at(1_000))
        #expect(policy.update([pods, podsMax], at: at(1_001)) == [.connected(podsMax)])
    }

    @Test func theWakeGraceEnds() {
        var policy = HeadphoneGlancePolicy(baseline: [pods], startedAt: epoch)
        policy.noteSleep(at: at(100))
        policy.noteWake(at: at(1_000))
        #expect(policy.update([], at: at(1_000 + HeadphoneGlancePolicy.wakeGrace)) == [.disconnected(pods)])
    }

    @Test func aClockSetBackDoesNotSilenceTheDevice() {
        var policy = freshPolicy()
        #expect(policy.update([pods], at: at(afterGrace)) == [.connected(pods)])
        // An hour back: the debounce gap is negative, not "a moment ago".
        #expect(policy.update([], at: at(afterGrace - 3_600)) == [.disconnected(pods)])
    }

    @Test func durationIsClampedToTheSettingsRange() {
        #expect(HeadphoneGlancePolicy.clampedDuration(1) == 2)
        #expect(HeadphoneGlancePolicy.clampedDuration(2) == 2)
        #expect(HeadphoneGlancePolicy.clampedDuration(4.5) == 4.5)
        #expect(HeadphoneGlancePolicy.clampedDuration(6) == 6)
        #expect(HeadphoneGlancePolicy.clampedDuration(60) == 6)
        #expect(HeadphoneGlancePolicy.clampedDuration(.nan) == HeadphoneGlancePolicy.defaultDuration)
        #expect(HeadphoneGlancePolicy.clampedDuration(.infinity) == HeadphoneGlancePolicy.defaultDuration)
    }
}
