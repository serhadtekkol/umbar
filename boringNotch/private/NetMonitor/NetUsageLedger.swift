//
//  NetUsageLedger.swift
//  boringNotch
//
//  F17 "how much traffic on this network": per-network daily totals, kept
//  locally in a small JSON file. Foundation + CryptoKit only, so umbarTests
//  can compile it.
//
//  Nothing here leaves the machine. The file holds byte counts, a one-way
//  hash of the network's router signature, and (only if the user granted Location
//  so macOS reveals it) the Wi-Fi name as a label.
//

import CryptoKit
import Foundation

/// Received/sent bytes for one bucket (a day, a session, a month).
struct NetByteTotals: Codable, Equatable {
    var rx: UInt64 = 0
    var tx: UInt64 = 0

    var sum: UInt64 { rx &+ tx }

    /// Saturating: a ledger edited by hand to near-`UInt64.max` must not
    /// crash the app on the next credit.
    mutating func add(rx: UInt64, tx: UInt64) {
        self.rx = self.rx.addingReportingOverflow(rx).overflow ? .max : self.rx + rx
        self.tx = self.tx.addingReportingOverflow(tx).overflow ? .max : self.tx + tx
    }
}

/// What kind of link a network was seen on. Stored as a string so a value
/// added later does not make older files undecodable.
enum NetLinkKind: String, Codable, Equatable {
    case wifi
    case ethernet
    case cellular
    case other
}

/// The stable identity of "this network".
///
/// The key is derived from macOS's own network signature (default router's
/// IP and hardware address, see `NetSystemProbe`) and the link kind, never
/// from the SSID. Reason: the SSID is only readable after the user grants
/// Location, so an SSID-based key would split one network's history in two
/// the moment permission is granted. The SSID is kept as a display label.
struct NetNetworkKey: Hashable, Codable, Equatable {
    let rawValue: String

    /// What the key was derived from, strongest first. The router IP alone
    /// (192.168.1.1) is shared by most home networks, so it is only used
    /// when no signature appears, scoped to the interface to reduce
    /// collisions; that is a known, accepted weakness of the fallback.
    enum Basis: Equatable {
        case systemSignature(String)
        case routerIP(String, interface: String)
        case interfaceOnly(String)
    }

    static func make(_ basis: Basis, kind: NetLinkKind) -> NetNetworkKey {
        let material: String
        switch basis {
        case .systemSignature(let signature): material = "sig|\(signature.lowercased())"
        case .routerIP(let ip, let interface): material = "ip|\(ip)|\(interface)"
        case .interfaceOnly(let interface): material = "if|\(interface)"
        }
        // Hashed so the file does not hold the router's hardware address in
        // the clear. 16 bytes is far beyond any collision risk for the
        // handful of networks one Mac sees.
        let digest = SHA256.hash(data: Data("\(kind.rawValue)|\(material)".utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return NetNetworkKey(rawValue: hex)
    }
}

/// Calendar-day keys ("2026-10-27") in the user's current time zone.
///
/// A day is credited when the bytes are counted, in local time, so "today"
/// matches the user's day even after travel. Traffic counted at 23:59:58
/// and read at 00:00:01 belongs to yesterday, which is correct.
enum NetDayKey {
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "2026-10", the prefix shared by every day key of that month.
    static func monthPrefix(for date: Date, calendar: Calendar = .current) -> String {
        String(key(for: date, calendar: calendar).prefix(7))
    }
}

/// Everything the ledger file holds.
struct NetUsageLedger: Codable, Equatable {
    struct Network: Codable, Equatable {
        var kind: NetLinkKind
        /// The Wi-Fi name, only when macOS revealed it (Location granted).
        var label: String?
        /// Day key → totals for that day.
        var days: [String: NetByteTotals] = [:]
    }

    /// Bumped on an incompatible change; a file with another version is
    /// discarded rather than misread (it only holds statistics).
    static let currentVersion = 1

    var version = NetUsageLedger.currentVersion
    var networks: [String: Network] = [:]

    // MARK: Writing

    mutating func credit(_ key: NetNetworkKey, kind: NetLinkKind, day: String, rx: UInt64, tx: UInt64) {
        guard rx > 0 || tx > 0 else { return }
        var network = networks[key.rawValue] ?? Network(kind: kind)
        network.kind = kind
        network.days[day, default: NetByteTotals()].add(rx: rx, tx: tx)
        networks[key.rawValue] = network
    }

    mutating func setLabel(_ label: String?, for key: NetNetworkKey, kind: NetLinkKind) {
        guard let label, !label.isEmpty else { return }
        var network = networks[key.rawValue] ?? Network(kind: kind)
        network.label = label
        networks[key.rawValue] = network
    }

    /// Forgets one network entirely (the "reset" button).
    mutating func reset(_ key: NetNetworkKey) {
        networks.removeValue(forKey: key.rawValue)
    }

    mutating func removeAll() {
        networks.removeAll()
    }

    /// Drops days that are both older than `retentionDays` and outside the
    /// current month. The second condition keeps "this month" complete on
    /// the 31st, when the 30-day window alone would already have dropped
    /// the 1st. Networks left with no days are removed.
    mutating func prune(now: Date, retentionDays: Int = 30, calendar: Calendar = .current) {
        guard let cutoffDate = calendar.date(byAdding: .day, value: -retentionDays, to: now) else { return }
        // Day keys are zero-padded ISO dates, so string order is date order.
        let cutoff = NetDayKey.key(for: cutoffDate, calendar: calendar)
        let month = NetDayKey.monthPrefix(for: now, calendar: calendar)
        for (id, var network) in networks {
            network.days = network.days.filter { day, _ in day > cutoff || day.hasPrefix(month) }
            networks[id] = network.days.isEmpty ? nil : network
        }
    }

    // MARK: Reading

    func today(_ key: NetNetworkKey, now: Date, calendar: Calendar = .current) -> NetByteTotals {
        networks[key.rawValue]?.days[NetDayKey.key(for: now, calendar: calendar)] ?? NetByteTotals()
    }

    func month(_ key: NetNetworkKey, now: Date, calendar: Calendar = .current) -> NetByteTotals {
        let prefix = NetDayKey.monthPrefix(for: now, calendar: calendar)
        var totals = NetByteTotals()
        for (day, value) in networks[key.rawValue]?.days ?? [:] where day.hasPrefix(prefix) {
            totals.add(rx: value.rx, tx: value.tx)
        }
        return totals
    }

    func label(_ key: NetNetworkKey) -> String? {
        networks[key.rawValue]?.label
    }
}

/// Reads and writes the ledger file. Failures are reported, not thrown past
/// the monitor: losing traffic statistics must never affect the notch.
struct NetUsageFile {
    let url: URL

    /// `~/Library/Application Support/<bundle id>/NetMonitor/usage.json`,
    /// keyed by bundle id for the same reason as the shelf (card #40): a
    /// QA identity root must not share the user's file.
    static func defaultURL(fileManager: FileManager = .default, bundleID: String? = Bundle.main.bundleIdentifier) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent(bundleID ?? "com.serhadbahadir.umbar", isDirectory: true)
            .appendingPathComponent("NetMonitor", isDirectory: true)
            .appendingPathComponent("usage.json")
    }

    /// The stored ledger, or an empty one when the file is missing,
    /// unreadable or from another version.
    func load() -> NetUsageLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(NetUsageLedger.self, from: data),
              ledger.version == NetUsageLedger.currentVersion
        else { return NetUsageLedger() }
        return ledger
    }

    /// Atomic write (temp file + rename), so a crash mid-write leaves the
    /// previous file rather than half a JSON document.
    func save(_ ledger: NetUsageLedger, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ledger).write(to: url, options: [.atomic])
    }
}
