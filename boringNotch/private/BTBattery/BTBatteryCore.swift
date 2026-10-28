//
//  BTBatteryCore.swift
//  boringNotch
//
//  F24 Bluetooth device batteries: the device model, the IORegistry HID
//  parser, the merge of the three public sources, and the rules for when a
//  connect is announced on the closed island and when system_profiler may
//  run. Foundation-only so umbarTests compiles it by membership; it reuses
//  `QuickBattery` / `QuickBluetoothAddress` / `QuickBatteryParser` from
//  QuickTogglesCore.swift (also in the test target) instead of a second copy.
//
//  Sources, all public:
//  - IORegistry `AppleDeviceManagementHIDEventService` (Magic Mouse,
//    Keyboard, Trackpad and other Apple HID): `BatteryPercent`, `Product`,
//    `DeviceAddress`. Needs no Bluetooth permission.
//  - IOBluetooth paired devices: which are connected, their names, whether
//    they are audio. Only read once the Bluetooth permission is granted.
//  - `system_profiler -json SPBluetoothDataType`: the only public place the
//    AirPods left / right / case levels appear (IOBluetoothDevice's
//    batteryPercent* selectors are undocumented SPI, so they are not used).
//

import Foundation

/// What kind of device a row is, for its glyph and its sort position.
enum BTDeviceKind: Equatable, Sendable {
    case headphones
    case mouse
    case keyboard
    case trackpad
    case other

    /// Names Apple ships ("Magic Trackpad", "Magic Keyboard with Touch ID",
    /// "MX Master 3S" reports as a mouse through PrimaryUsage only), so the
    /// HID usage wins when present and the name is the fallback.
    static func classify(name: String, primaryUsagePage: Int?, primaryUsage: Int?, isAudio: Bool = false) -> BTDeviceKind {
        if isAudio { return .headphones }
        let lower = name.lowercased()
        if lower.contains("trackpad") { return .trackpad }
        // Generic Desktop page (0x01): 0x02 mouse, 0x06 keyboard.
        if primaryUsagePage == 1 {
            if primaryUsage == 2 { return .mouse }
            if primaryUsage == 6 { return .keyboard }
        }
        if lower.contains("mouse") { return .mouse }
        if lower.contains("keyboard") { return .keyboard }
        if lower.contains("airpods") || lower.contains("beats") || lower.contains("headphone") { return .headphones }
        return .other
    }
}

/// One connected device that reported at least one battery level.
struct BTBatteryDevice: Equatable, Identifiable, Sendable {
    /// Normalised Bluetooth address, or `name:<product>` for a HID service
    /// that publishes no address.
    let id: String
    let name: String
    let kind: BTDeviceKind
    var battery: QuickBattery
}

/// One HID battery as IORegistry publishes it.
struct BTHIDBattery: Equatable, Sendable {
    let id: String
    let name: String
    let kind: BTDeviceKind
    let percent: Int
}

/// A connected device as IOBluetooth reports it (no battery there).
struct BTConnectedDevice: Equatable, Sendable {
    let id: String
    let name: String
    let isAudio: Bool
}

enum BTHIDBatteryParser {
    /// Reads the property dictionaries of the
    /// `AppleDeviceManagementHIDEventService` entries. Entries without a
    /// `BatteryPercent` in 0...100 are skipped (a USB-wired keyboard
    /// publishes the service with no battery). When two services describe
    /// the same device (a Magic Keyboard exposes one per HID interface),
    /// the first one wins: they carry the same value.
    static func parse(_ services: [[String: Any]]) -> [BTHIDBattery] {
        var seen = Set<String>()
        var result: [BTHIDBattery] = []
        for props in services {
            guard let percent = int(props["BatteryPercent"]), (0...100).contains(percent) else { continue }
            let name = (props["Product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let address = (props["DeviceAddress"] as? String).map(QuickBluetoothAddress.normalize) ?? ""
            guard !name.isEmpty || !address.isEmpty else { continue }
            let id = address.isEmpty ? "name:\(name)" : address
            guard seen.insert(id).inserted else { continue }
            let kind = BTDeviceKind.classify(
                name: name, primaryUsagePage: int(props["PrimaryUsagePage"]), primaryUsage: int(props["PrimaryUsage"]))
            result.append(BTHIDBattery(id: id, name: name.isEmpty ? address : name, kind: kind, percent: percent))
        }
        return result
    }

    /// IORegistry numbers arrive as NSNumber; tests pass Int.
    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let n as NSNumber: return n.intValue
        default: return nil
        }
    }
}

enum BTBatteryMerge {
    /// Combines the three sources into the rows the UI shows.
    ///
    /// - `connected`: IOBluetooth's connected devices; empty without the
    ///   Bluetooth permission, in which case only HID devices appear.
    /// - `profiler`: system_profiler levels by normalised address. Used only
    ///   for devices that are connected now, because system_profiler keeps
    ///   the last levels of a disconnected device and those are stale.
    /// - `hid`: IORegistry levels; for the same device they replace the
    ///   profiler's single value, since IORegistry is read live each time
    ///   while the profiler reading may be up to a minute old.
    ///
    /// Devices with no level from any source are left out: the row is about
    /// batteries, and the Bluetooth device strip already lists the rest.
    /// Order: headphones first (their levels change fastest), then by name.
    static func merge(connected: [BTConnectedDevice], profiler: [String: QuickBattery], hid: [BTHIDBattery]) -> [BTBatteryDevice] {
        var rows: [String: BTBatteryDevice] = [:]
        let hidByID = Dictionary(hid.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for device in connected {
            var battery = profiler[device.id] ?? QuickBattery()
            let live = hidByID[device.id]
            if let live { battery.single = live.percent }
            guard !battery.isEmpty else { continue }
            let kind = live?.kind ?? BTDeviceKind.classify(
                name: device.name, primaryUsagePage: nil, primaryUsage: nil, isAudio: device.isAudio)
            rows[device.id] = BTBatteryDevice(id: device.id, name: device.name, kind: kind, battery: battery)
        }
        for entry in hid where rows[entry.id] == nil {
            rows[entry.id] = BTBatteryDevice(id: entry.id, name: entry.name, kind: entry.kind, battery: QuickBattery(single: entry.percent))
        }
        return rows.values.sorted { a, b in
            if (a.kind == .headphones) != (b.kind == .headphones) { return a.kind == .headphones }
            let byName = a.name.localizedStandardCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.id < b.id
        }
    }
}

/// Decides which connects get the closed-island glance. Time comes in from
/// the caller so the rules are tested without waiting.
struct BTConnectGlancePolicy: Equatable {
    /// How long the name and level stay under the notch.
    static let duration: TimeInterval = 3
    /// IOBluetooth and the IOKit matching notification both report devices
    /// that were already connected when they are registered; anything in
    /// this window after `start` is that baseline, not a new connection.
    static let baselineGrace: TimeInterval = 5
    /// AirPods drop and re-link when moved between ears and case; one glance
    /// per device per minute is enough. Also dedupes the IOBluetooth and HID
    /// notifications for the same Magic device.
    static let cooldown: TimeInterval = 60

    private(set) var startedAt: Date
    private(set) var lastShown: [String: Date] = [:]

    init(startedAt: Date) { self.startedAt = startedAt }

    /// True when a connect of `id` at `now` should be shown; records it.
    mutating func shouldAnnounce(_ id: String, at now: Date) -> Bool {
        guard now.timeIntervalSince(startedAt) >= Self.baselineGrace else { return false }
        if let last = lastShown[id], now.timeIntervalSince(last) < Self.cooldown { return false }
        lastShown[id] = now
        return true
    }
}

/// When the monitor may run system_profiler. It is a subprocess that walks
/// the whole Bluetooth stack (~0.3-1 s), so it only runs when an audio
/// device is connected (nothing else needs it: HID levels come from
/// IORegistry) and at most once per `minimumInterval`, unless a connect or
/// disconnect just happened. Even then at most once per
/// `forcedMinimumInterval`: a device that flaps (or a burst of connect
/// notifications) must not turn into a system_profiler per event.
enum BTProfilerPolicy {
    static let minimumInterval: TimeInterval = 60
    static let forcedMinimumInterval: TimeInterval = 5

    static func shouldRun(hasConnectedAudio: Bool, lastRun: Date?, now: Date, forced: Bool) -> Bool {
        guard hasConnectedAudio else { return false }
        guard let lastRun else { return true }
        let elapsed = now.timeIntervalSince(lastRun)
        // A negative gap means the clock was set back; waiting for it to
        // catch up could postpone the read by hours.
        return elapsed < 0 || elapsed >= (forced ? forcedMinimumInterval : minimumInterval)
    }

    /// For a forced read that `shouldRun` refused because of the floor:
    /// how long until it may run, so the caller can retry then instead of
    /// losing the connect's fresh reading. `nil` when no retry is needed.
    static func forcedRetryDelay(hasConnectedAudio: Bool, lastRun: Date?, now: Date) -> TimeInterval? {
        guard hasConnectedAudio, let lastRun else { return nil }
        let elapsed = now.timeIntervalSince(lastRun)
        guard elapsed >= 0, elapsed < forcedMinimumInterval else { return nil }
        return forcedMinimumInterval - elapsed
    }
}

// MARK: - Closed-island glance

extension LiveActivity {
    /// The "device connected" glance: a live-activity strip item that lives
    /// `BTConnectGlancePolicy.duration` under the closed notch and never
    /// reaches the Şimdi row (`expiresAt` equals `stripUntil`); the Araçlar
    /// page already lists the device.
    ///
    /// The id is per device, so a second connect of the same device replaces
    /// the first glance instead of stacking a "+1".
    static func bluetoothConnected(id: String, name: String, battery: QuickBattery?, now: Date) -> LiveActivity {
        let until = now.addingTimeInterval(BTConnectGlancePolicy.duration)
        return LiveActivity(
            id: "bluetooth:\(id)", kind: .bluetooth, phase: .finished, title: name,
            percent: battery?.headline, startedAt: now, stripUntil: until, expiresAt: until,
            battery: battery.flatMap { $0.isEmpty ? nil : $0 })
    }
}
