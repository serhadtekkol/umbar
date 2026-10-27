//
//  DownloadParsing.swift
//  boringNotch
//
//  F19 live activities: the pure rules for reading a Downloads folder.
//  Which entries are unfinished downloads, how far a Safari download has
//  got, how fast a transfer is going, what changed between two listings,
//  and whether a file arrived over AirDrop.
//
//  Foundation-only and free of file I/O so umbarTests can compile it on its
//  own (see umbarTests/LiveActivityParsingTests.swift). DownloadsWatcher does
//  the reading and feeds the results in.
//

import Foundation

// MARK: - Unfinished downloads by name

/// The browser convention an unfinished entry in the Downloads folder follows.
enum PartialDownloadKind: String, Equatable, Sendable {
    /// Safari: a `<name>.download` bundle holding the partial file and an
    /// `Info.plist` with byte counts.
    case safari
    /// Chrome and the Chromium browsers (Edge, Brave, Arc): `<name>.crdownload`,
    /// which grows in place. No total size is written anywhere public.
    case chromium
    /// Firefox: `<name>.part` next to an empty placeholder `<name>`.
    case firefox
}

/// An entry name recognised as an unfinished download.
struct PartialDownloadName: Equatable, Sendable {
    let kind: PartialDownloadKind
    /// The name the file will have when it finishes (`report.pdf`), or nil
    /// while the browser has not decided yet. Chrome starts some downloads as
    /// `Unconfirmed 123456.crdownload` and renames them once the user confirms.
    let finalName: String?

    private static let suffixes: [(String, PartialDownloadKind)] = [
        (".download", .safari),
        (".crdownload", .chromium),
        (".part", .firefox),
    ]

    init(kind: PartialDownloadKind, finalName: String?) {
        self.kind = kind
        self.finalName = finalName
    }

    /// Returns nil for anything that is not an unfinished download, including
    /// hidden files and a bare suffix with no name in front of it.
    init?(fileName: String) {
        guard !fileName.hasPrefix(".") else { return nil }
        for (suffix, kind) in Self.suffixes where fileName.count > suffix.count
            && fileName.lowercased().hasSuffix(suffix)
        {
            let stem = String(fileName.dropLast(suffix.count))
            self.kind = kind
            if kind == .chromium, Self.isUnconfirmedChromiumStem(stem) {
                self.finalName = nil
            } else {
                self.finalName = stem
            }
            return
        }
        return nil
    }

    /// `Unconfirmed 123456`: Chrome's placeholder before the real name is known.
    private static func isUnconfirmedChromiumStem(_ stem: String) -> Bool {
        let prefix = "Unconfirmed "
        guard stem.hasPrefix(prefix) else { return false }
        let digits = stem.dropFirst(prefix.count)
        return !digits.isEmpty && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
    }
}

// MARK: - Safari's Info.plist

/// Byte counts Safari keeps in `<name>.download/Info.plist`.
struct SafariDownloadProgress: Equatable, Sendable {
    let bytesSoFar: Int64
    /// nil when the server did not send a length (Safari writes 0 or -1).
    let totalBytes: Int64?

    /// 0...1, or nil when the total is unknown.
    var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesSoFar) / Double(totalBytes)))
    }

    static let bytesSoFarKey = "DownloadEntryProgressBytesSoFar"
    static let totalKey = "DownloadEntryProgressTotalToLoad"

    /// Parses the plist dictionary. Returns nil when the byte count is missing,
    /// which is how a bundle looks in the instant before Safari first writes it.
    static func parse(_ plist: [String: Any]) -> SafariDownloadProgress? {
        guard let soFar = int64(plist[bytesSoFarKey]), soFar >= 0 else { return nil }
        let total = int64(plist[totalKey]).flatMap { $0 > 0 ? $0 : nil }
        return SafariDownloadProgress(bytesSoFar: soFar, totalBytes: total)
    }

    /// Parses raw `Info.plist` bytes (XML or binary).
    static func parse(data: Data) -> SafariDownloadProgress? {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = object as? [String: Any]
        else { return nil }
        return parse(dict)
    }

    private static func int64(_ value: Any?) -> Int64? {
        // Bridged plist numbers arrive as NSNumber; Int/Double cover the
        // dictionaries tests build by hand.
        switch value {
        case let n as NSNumber: return n.int64Value
        case let i as Int: return Int64(i)
        case let d as Double where d.isFinite: return Int64(d)
        default: return nil
        }
    }
}

// MARK: - Transfer rate

/// Bytes per second over a short sliding window.
///
/// A window rather than the last two samples, because Safari rewrites its
/// Info.plist in bursts and a two-sample rate swings between 0 and twice the
/// real speed. Three seconds is short enough that the number follows a real
/// change of speed within a glance.
struct TransferRateEstimator: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        let at: Date
        let bytes: Int64
    }

    var window: TimeInterval = 3
    private(set) var samples: [Sample] = []

    init(window: TimeInterval = 3) {
        self.window = window
    }

    mutating func record(bytes: Int64, at time: Date) {
        // A smaller count means the download restarted (or Chrome replaced
        // the file); the old samples describe a different transfer.
        if let last = samples.last, bytes < last.bytes || time < last.at {
            samples.removeAll()
        }
        samples.append(Sample(at: time, bytes: bytes))
        // Keep one sample older than the window so the span stays ~window long.
        while samples.count > 2, let second = samples.dropFirst().first,
              time.timeIntervalSince(second.at) >= window
        {
            samples.removeFirst()
        }
    }

    /// nil until two samples at least half a second apart exist.
    var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= 0.5 else { return nil }
        return Double(last.bytes - first.bytes) / span
    }
}

// MARK: - Listing diff

/// One listing of the watched folder, reduced to what the diff needs.
struct DownloadsListing: Equatable, Sendable {
    /// Unfinished downloads, keyed by entry name (`a.zip.download`).
    var partials: [String: PartialDownloadName] = [:]
    /// Every other visible entry name.
    var others: Set<String> = []

    init(partials: [String: PartialDownloadName] = [:], others: Set<String> = []) {
        self.partials = partials
        self.others = others
    }

    /// Splits raw entry names. Hidden entries are ignored.
    init(entryNames: [String]) {
        for name in entryNames where !name.hasPrefix(".") {
            if let partial = PartialDownloadName(fileName: name) {
                partials[name] = partial
            } else {
                others.insert(name)
            }
        }
    }
}

/// A download whose partial entry was replaced by its finished file.
struct FinishedDownload: Equatable, Sendable {
    let entry: String
    let finalName: String
}

/// What changed between two listings.
struct DownloadsListingChange: Equatable, Sendable {
    /// Entry names of unfinished downloads that were not there before.
    var started: [String] = []
    /// Downloads that finished: the partial entry went away and the file it
    /// was going to become is present.
    var finished: [FinishedDownload] = []
    /// Partial entries that went away without leaving their file: cancelled,
    /// or Chrome renaming `Unconfirmed N.crdownload` to the real name.
    var vanished: [String] = []
    /// New plain files that are not the result of a tracked download. These
    /// are the AirDrop candidates.
    var appeared: [String] = []

    var isEmpty: Bool { started.isEmpty && finished.isEmpty && vanished.isEmpty && appeared.isEmpty }

    /// Results are sorted by name so the outcome does not depend on the
    /// order the file system returned entries in.
    static func between(_ old: DownloadsListing, _ new: DownloadsListing) -> DownloadsListingChange {
        var change = DownloadsListingChange()
        change.started = new.partials.keys.filter { old.partials[$0] == nil }.sorted()

        var produced: Set<String> = []
        for entry in old.partials.keys.sorted() where new.partials[entry] == nil {
            let partial = old.partials[entry]!
            if let finalName = partial.finalName, new.others.contains(finalName) {
                change.finished.append(FinishedDownload(entry: entry, finalName: finalName))
                produced.insert(finalName)
            } else {
                change.vanished.append(entry)
            }
        }

        change.appeared = new.others.subtracting(old.others).subtracting(produced)
            // A file that has a partial twin is a Firefox placeholder or a
            // Safari temporary, not a finished arrival.
            .filter { name in !new.partials.values.contains { $0.finalName == name } }
            .sorted()
        return change
    }
}

// MARK: - Quarantine (AirDrop)

/// The `com.apple.quarantine` extended attribute: `flags;hex-time;agent;uuid`.
///
/// AirDrop receives are written by `sharingd`, so the agent field is the only
/// public, no-permission signal that a file came over AirDrop. Some releases
/// write `AirDrop` instead; both are accepted. Best effort by nature: a file
/// copied out of an AirDrop folder keeps the attribute.
struct QuarantineRecord: Equatable, Sendable {
    let flags: String
    let timestamp: Date?
    let agent: String
    let eventID: String?

    var isAirDrop: Bool {
        let a = agent.lowercased()
        return a == "sharingd" || a.contains("airdrop")
    }

    /// How old a quarantine stamp may be and still count as "just received".
    /// Guards against announcing a months-old AirDrop file that the user
    /// merely moved back into Downloads.
    static let recentWindow: TimeInterval = 10 * 60

    /// An AirDrop file stamped within `recentWindow` of `now`. A record with
    /// no readable time is accepted: the stamp is best effort, and the file
    /// did just appear in the folder.
    func isRecentAirDrop(now: Date) -> Bool {
        guard isAirDrop else { return false }
        guard let timestamp else { return true }
        return abs(now.timeIntervalSince(timestamp)) <= Self.recentWindow
    }

    static func parse(_ raw: String) -> QuarantineRecord? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        let fields = trimmed.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 3, !fields[0].isEmpty else { return nil }
        let time = UInt64(fields[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let event = fields.count >= 4 && !fields[3].isEmpty ? fields[3] : nil
        return QuarantineRecord(flags: fields[0], timestamp: time, agent: fields[2], eventID: event)
    }

    static func parse(data: Data) -> QuarantineRecord? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        return parse(s)
    }
}
