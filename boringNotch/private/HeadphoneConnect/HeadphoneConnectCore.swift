//
//  HeadphoneConnectCore.swift
//  boringNotch
//
//  The rules behind the headphone connect glance (the closed island widening
//  for a few seconds with the device glyph and its battery when AirPods or
//  other Bluetooth headphones connect, iPhone-style): which Core Audio
//  devices count, what glyph a model gets, and which appearances are real
//  connects worth showing. Foundation-only so umbarTests compiles it by
//  membership; the Core Audio and NSWorkspace side is HeadphoneConnectMonitor.
//
//  Why Core Audio and not IOBluetooth: a Bluetooth output device appearing
//  in `kAudioHardwarePropertyDevices` is readable without the Bluetooth
//  permission (IOBluetooth is behind TCC, see BTBatteryMonitor), and it only
//  ever contains audio devices, so a Magic Mouse or keyboard connecting can
//  never trigger the glance.
//

import Foundation

/// The Bluetooth headphone families with their own SF Symbol.
enum HeadphoneModel: Equatable, Sendable, CaseIterable {
    case airPods
    case airPodsGen3
    case airPodsGen4
    case airPodsPro
    case airPodsMax
    case beatsHeadphones
    case beatsEarphones
    case powerbeatsPro
    case beatsStudioBuds
    case beatsFitPro
    /// Any other Bluetooth output that does not look like a speaker.
    case headphones
    case speaker

    /// SF Symbols names; all exist on the deployment target (macOS 27).
    var symbol: String {
        switch self {
        case .airPods: return "airpods"
        case .airPodsGen3: return "airpods.gen3"
        case .airPodsGen4: return "airpods.gen4"
        case .airPodsPro: return "airpods.pro"
        case .airPodsMax: return "airpods.max"
        case .beatsHeadphones: return "beats.headphones"
        case .beatsEarphones: return "beats.earphones"
        case .powerbeatsPro: return "beats.powerbeats.pro"
        case .beatsStudioBuds: return "beats.studiobuds"
        case .beatsFitPro: return "beats.fitpro"
        case .headphones: return "headphones"
        case .speaker: return "hifispeaker"
        }
    }

    /// Apple's Bluetooth product ids (vendor 0x004C). Only the ids that are
    /// well established are listed; anything else falls back to the name.
    /// 0x2024 was confirmed on the dev Mac's AirPods Pro 2 (USB-C) through
    /// system_profiler's `device_productID`.
    static let appleProductIDs: [Int: HeadphoneModel] = [
        0x2002: .airPods, 0x200F: .airPods,
        0x2013: .airPodsGen3,
        0x2019: .airPodsGen4, 0x201B: .airPodsGen4,
        0x200E: .airPodsPro, 0x2014: .airPodsPro, 0x2024: .airPodsPro,
        0x200A: .airPodsMax, 0x201F: .airPodsMax,
        0x2006: .beatsHeadphones, 0x2009: .beatsHeadphones, 0x200C: .beatsHeadphones,
        0x2005: .beatsEarphones, 0x2010: .beatsEarphones,
        0x200B: .powerbeatsPro,
        0x2011: .beatsStudioBuds, 0x2016: .beatsStudioBuds,
        0x2012: .beatsFitPro,
    ]

    /// The product id wins because AirPods are routinely renamed ("Serhad's
    /// kulaklık"); the name is the fallback, checked most specific first so
    /// "AirPods Pro" is not read as plain "AirPods".
    static func classify(name: String, productID: Int?) -> HeadphoneModel {
        if let productID, let model = appleProductIDs[productID] { return model }
        let lower = name.lowercased()
        if lower.contains("airpods") {
            if lower.contains("max") { return .airPodsMax }
            if lower.contains("pro") { return .airPodsPro }
            // macOS names 3rd and 4th generation buds just "AirPods"; only a
            // user-typed name could say which, so plain buds are the default.
            return .airPods
        }
        if lower.contains("beats") {
            if lower.contains("pill") { return .speaker }
            if lower.contains("fit pro") { return .beatsFitPro }
            if lower.contains("studio buds") { return .beatsStudioBuds }
            if lower.contains("flex") || lower.contains("beatsx") { return .beatsEarphones }
            if lower.contains("solo") || lower.contains("studio") { return .beatsHeadphones }
        }
        if lower.contains("powerbeats") { return .powerbeatsPro }
        if lower.contains("beats") { return .beatsHeadphones }
        for word in ["speaker", "hoparlör", "soundbar", "soundlink"] where lower.contains(word) {
            return .speaker
        }
        return .headphones
    }
}

/// One Bluetooth audio output as Core Audio lists it.
struct HeadphoneOutput: Equatable, Sendable {
    /// Normalised Bluetooth address (`AABBCCDDEEFF`, the id BTBatteryMonitor
    /// keys batteries by) when the device UID carries one, else the UID.
    let id: String
    let name: String
    let model: HeadphoneModel
}

enum HeadphoneDeviceInfo {
    /// Core Audio 4CCs: `kAudioDeviceTransportTypeBluetooth` ('blue') and
    /// `kAudioDeviceTransportTypeBluetoothLE` ('blea'). Spelled out so this
    /// file stays Foundation-only.
    static let bluetoothTransports: Set<UInt32> = [0x626C_7565, 0x626C_6561]

    /// Whether a Core Audio device is one the glance is about: a Bluetooth
    /// (classic or LE) device with at least one output stream. An input-only
    /// entry (some headsets publish their microphone as its own device) is
    /// left out so it does not announce the same headset twice.
    static func isHeadphoneOutput(transport: UInt32, outputStreams: Int) -> Bool {
        bluetoothTransports.contains(transport) && outputStreams > 0
    }

    /// The Bluetooth address in a Core Audio device UID. Bluetooth devices
    /// publish UIDs like `AC-90-85-12-34-56:output`; the address is what
    /// links the device to BTBatteryMonitor's battery rows.
    static func address(fromUID uid: String) -> String? {
        let pattern = #"[0-9A-Fa-f]{2}([-:])[0-9A-Fa-f]{2}(\1[0-9A-Fa-f]{2}){4}"#
        guard let range = uid.range(of: pattern, options: .regularExpression) else { return nil }
        return QuickBluetoothAddress.normalize(String(uid[range]))
    }

    /// Best effort: a Core Audio model UID that names Apple's vendor id
    /// (0x4C) next to a 0x20xx product id yields that product id. The exact
    /// layout of a Bluetooth device's model UID is undocumented and was not
    /// observed on hardware (no Bluetooth audio was connected while this was
    /// built), so anything else returns nil and the name decides.
    static func appleProductID(fromModelUID modelUID: String) -> Int? {
        let tokens = modelUID.split(whereSeparator: { !$0.isHexDigit }).compactMap { Int($0, radix: 16) }
        guard tokens.contains(0x4C) else { return nil }
        return tokens.first { (0x2000...0x20FF).contains($0) }
    }

    static func output(uid: String, name: String, modelUID: String?) -> HeadphoneOutput {
        let productID = modelUID.flatMap(appleProductID(fromModelUID:))
        return HeadphoneOutput(
            id: address(fromUID: uid) ?? uid,
            name: name,
            model: HeadphoneModel.classify(name: name, productID: productID))
    }
}

/// Something worth a glance.
enum HeadphoneGlanceEvent: Equatable, Sendable {
    case connected(HeadphoneOutput)
    case disconnected(HeadphoneOutput)

    var output: HeadphoneOutput {
        switch self {
        case .connected(let o), .disconnected(let o): return o
        }
    }
}

/// What the closed island draws while a glance is up.
struct HeadphoneGlance: Equatable, Identifiable, Sendable {
    enum Phase: Equatable, Sendable {
        case connected
        case disconnected
    }

    /// Increases with every glance, so a second connect of the same device
    /// replays the animation instead of being an in-place update.
    let id: Int
    let phase: Phase
    let output: HeadphoneOutput
    /// Connected only, when BTBatteryMonitor has a level for the device. It
    /// can arrive while the glance is up (AirPods publish their levels a
    /// second or two after the audio route comes up).
    var battery: QuickBattery?
}

/// Turns successive snapshots of the Bluetooth outputs into the connects and
/// disconnects worth showing. Time comes in from the caller so the rules are
/// tested without waiting.
struct HeadphoneGlancePolicy: Equatable {
    /// Bluetooth headphones auto-reconnect a few seconds after login; a
    /// device appearing this soon after `start` is that, not the user
    /// putting AirPods in.
    static let launchGrace: TimeInterval = 5
    /// One announcement per device per window: AirPods drop and re-link when
    /// moved between ears and case, and a route change can remove and re-add
    /// the device within a second.
    static let debounce: TimeInterval = 10
    /// After wake, headphones that were connected before the Mac slept drop
    /// and come back as the Bluetooth stack restarts. Inside this window
    /// those devices are re-linking, not being connected by the user.
    static let wakeGrace: TimeInterval = 10

    /// The connect glance's on-screen time from Settings is clamped to this.
    static let durationRange: ClosedRange<Double> = 2...6
    static let defaultDuration: Double = 3
    /// The disconnect notice is plainer and shorter than the connect glance.
    static let disconnectDuration: TimeInterval = 1.5

    private(set) var known: [String: HeadphoneOutput]
    private(set) var startedAt: Date
    private(set) var lastAnnounced: [String: Date] = [:]
    private(set) var isAsleep = false
    private(set) var wokeAt: Date?
    private(set) var presentAtSleep: Set<String> = []

    /// `baseline` is what is connected at start; it is never announced.
    init(baseline: [HeadphoneOutput], startedAt: Date) {
        known = Dictionary(baseline.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.startedAt = startedAt
    }

    static func clampedDuration(_ seconds: Double) -> TimeInterval {
        guard seconds.isFinite else { return defaultDuration }
        return min(max(seconds, durationRange.lowerBound), durationRange.upperBound)
    }

    mutating func noteSleep(at now: Date) {
        isAsleep = true
        presentAtSleep = Set(known.keys)
    }

    mutating func noteWake(at now: Date) {
        isAsleep = false
        wokeAt = now
    }

    /// Diffs `present` against the last snapshot and returns the changes to
    /// show, connects after disconnects (a switch from one headset to another
    /// ends on the one now in use). Every change updates the snapshot, shown
    /// or not.
    mutating func update(_ present: [HeadphoneOutput], at now: Date) -> [HeadphoneGlanceEvent] {
        let current = Dictionary(present.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let gone = known.keys.filter { current[$0] == nil }.sorted().compactMap { known[$0] }
        let added = current.keys.filter { known[$0] == nil }.sorted().compactMap { current[$0] }
        known = current

        var events: [HeadphoneGlanceEvent] = []
        for output in gone where shouldAnnounce(output.id, at: now) {
            events.append(.disconnected(output))
        }
        for output in added where shouldAnnounce(output.id, at: now) {
            events.append(.connected(output))
        }
        return events
    }

    /// The one event to draw from a batch: the last connect, else the last
    /// disconnect.
    static func headline(_ events: [HeadphoneGlanceEvent]) -> HeadphoneGlanceEvent? {
        events.last { if case .connected = $0 { return true } else { return false } } ?? events.last
    }

    private mutating func shouldAnnounce(_ id: String, at now: Date) -> Bool {
        if isAsleep { return false }
        // A negative gap means the clock went back; treat it as "just now"
        // rather than suppressing for however long it takes to catch up.
        let sinceStart = now.timeIntervalSince(startedAt)
        if sinceStart >= 0, sinceStart < Self.launchGrace { return false }
        if let wokeAt, presentAtSleep.contains(id) {
            let sinceWake = now.timeIntervalSince(wokeAt)
            if sinceWake >= 0, sinceWake < Self.wakeGrace { return false }
        }
        if let last = lastAnnounced[id] {
            let gap = now.timeIntervalSince(last)
            if gap >= 0, gap < Self.debounce { return false }
        }
        lastAnnounced[id] = now
        return true
    }
}
