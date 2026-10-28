//
//  ClipboardHistoryCore.swift
//  umbar
//
//  F21 clipboard history: the rules, with no AppKit, no Defaults and no
//  disk, so umbarTests can compile and exercise them directly. What gets
//  recorded, how a repeat copy is folded into the earlier one, and what is
//  evicted when the history is full all live here.
//

import CryptoKit
import Foundation

/// One remembered copy.
struct ClipboardItem: Codable, Identifiable, Equatable, Sendable {
    enum Content: Codable, Equatable, Sendable {
        /// Plain text, exactly as copied (not trimmed: the copy back must be
        /// byte-for-byte what the user copied).
        case text(String)
        /// A single http(s) link. Stored as the copied string, not a parsed
        /// `URL`, for the same reason.
        case url(String)
        /// An image whose bytes live in their own file next to the index
        /// (`ClipboardHistoryStore`). `digest` is the SHA-256 of the bytes,
        /// used to fold repeat copies of the same image.
        case image(ImageRef)
    }

    struct ImageRef: Codable, Equatable, Sendable {
        /// File name inside the store directory, `<item id>.<ext>`.
        var fileName: String
        /// Uniform type identifier of the bytes, `public.png` or `public.tiff`.
        var typeIdentifier: String
        var byteCount: Int
        var digest: String
    }

    let id: UUID
    var content: Content
    /// When it was last copied (a repeat copy moves it to the top and
    /// refreshes this).
    var copiedAt: Date

    init(id: UUID = UUID(), content: Content, copiedAt: Date) {
        self.id = id
        self.content = content
        self.copiedAt = copiedAt
    }

    /// Two items with the same key are the same copy for dedupe purposes.
    var dedupeKey: String {
        switch content {
        case .text(let s): "t:" + s
        case .url(let s): "u:" + s
        case .image(let ref): "i:" + ref.digest
        }
    }

    var imageRef: ImageRef? {
        if case .image(let ref) = content { ref } else { nil }
    }
}

/// Limits and classification shared by the monitor's consumer and the tests.
enum ClipboardHistoryPolicy {
    /// History lengths offered in Settings; the default is the brief's 50.
    static let limitChoices = [10, 25, 50, 100]
    static let defaultLimit = 50

    /// An image above this is not recorded at all, in memory or on disk. A
    /// full-screen Retina screenshot as PNG is 3–8 MB; as TIFF (what Preview
    /// and many apps put on the pasteboard) it is 30 MB and more. 8 MB keeps
    /// the common PNG cases and drops the raw TIFFs, which are the ones that
    /// would fill the disk.
    static let maxImageBytes = 8 * 1024 * 1024
    /// All recorded images together. Past this the oldest images are evicted
    /// first, even when the item count is under the limit.
    static let maxTotalImageBytes = 64 * 1024 * 1024
    /// Text above this is not recorded: it is almost always a log or a file
    /// pasted whole, the index is rewritten on every copy, and the card can
    /// show only its first lines anyway.
    static let maxTextLength = 200_000

    /// Retention choices offered in Settings, in days; 0 means unlimited.
    /// BR-4.4: 1 / 7 / 30 days / unlimited, 7 when the user never chose.
    static let retentionChoices = [1, 7, 30, 0]
    static let defaultRetentionDays = 7

    /// The retention for a stored day count, or `nil` for unlimited. An
    /// unknown stored value (edited by hand) falls back to the default
    /// rather than to "unlimited": the safe direction for BR-4.4.
    static func retention(days: Int) -> TimeInterval? {
        let days = retentionChoices.contains(days) ? days : defaultRetentionDays
        return days == 0 ? nil : TimeInterval(days) * 86_400
    }

    /// True when `item` is older than `retention` at `now`. An item dated in
    /// the future (the clock was set back) is not expired; it ages out once
    /// the clock passes its date plus the retention.
    static func isExpired(_ item: ClipboardItem, now: Date, retention: TimeInterval?) -> Bool {
        guard let retention else { return false }
        return now.timeIntervalSince(item.copiedAt) > retention
    }

    /// Clamps a stored setting to one of the offered lengths' range.
    static func clampedLimit(_ value: Int) -> Int {
        min(max(value, 1), limitChoices.max() ?? defaultLimit)
    }

    /// What a captured string becomes, or `nil` when it is not worth
    /// recording (empty, whitespace only, too long).
    static func content(forText text: String) -> ClipboardItem.Content? {
        guard text.utf16.count <= maxTextLength else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return isWebLink(trimmed) ? .url(text) : .text(text)
    }

    /// One token, http or https, with a host. "example.com" alone stays text:
    /// guessing a scheme would change what is copied back.
    static func isWebLink(_ s: String) -> Bool {
        guard !s.contains(where: \.isWhitespace),
              let components = URLComponents(string: s),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return false }
        return true
    }

    /// Hex SHA-256 of image bytes, for `ImageRef.digest`.
    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// File extension for a stored image's type identifier.
    static func fileExtension(forTypeIdentifier uti: String) -> String {
        uti == "public.png" ? "png" : "tiff"
    }
}

/// The ordered history, newest first. A value type: the app-side model owns
/// one and publishes it; the store persists snapshots of it.
struct ClipboardHistory: Equatable, Sendable {
    private(set) var items: [ClipboardItem] = []
    private(set) var limit: Int
    /// BR-4.4 maximum age, `nil` for unlimited. Enforced by `expire(now:)`,
    /// on insert (against the new copy's date) and when it is changed.
    private(set) var retention: TimeInterval?

    init(items: [ClipboardItem] = [], limit: Int = ClipboardHistoryPolicy.defaultLimit,
         retention: TimeInterval? = nil, now: Date? = nil) {
        self.limit = ClipboardHistoryPolicy.clampedLimit(limit)
        self.retention = retention
        self.items = items
        _ = enforceLimits(now: now)
    }

    var totalImageBytes: Int {
        items.reduce(0) { $0 + ($1.imageRef?.byteCount ?? 0) }
    }

    /// Puts `item` on top. A previous copy with the same content is removed
    /// (BR-4.2: one entry per distinct content, at the position of its latest
    /// copy). Returns every item that left the history, the folded duplicate
    /// included, so the caller can delete their image files.
    @discardableResult
    mutating func insert(_ item: ClipboardItem) -> [ClipboardItem] {
        var removed: [ClipboardItem] = []
        let key = item.dedupeKey
        items.removeAll { existing in
            guard existing.dedupeKey == key else { return false }
            removed.append(existing)
            return true
        }
        items.insert(item, at: 0)
        return removed + enforceLimits(now: item.copiedAt)
    }

    /// Moves an existing item to the top with a fresh date (it was copied
    /// back from the history). Returns false when `id` is not in the history.
    @discardableResult
    mutating func promote(id: UUID, at date: Date) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        var item = items.remove(at: index)
        item.copiedAt = date
        items.insert(item, at: 0)
        return true
    }

    @discardableResult
    mutating func remove(id: UUID) -> ClipboardItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    @discardableResult
    mutating func removeAll() -> [ClipboardItem] {
        defer { items = [] }
        return items
    }

    /// Shortening the limit evicts the oldest items right away.
    @discardableResult
    mutating func setLimit(_ newLimit: Int) -> [ClipboardItem] {
        limit = ClipboardHistoryPolicy.clampedLimit(newLimit)
        return enforceLimits(now: nil)
    }

    /// Changes the retention and drops whatever it makes too old at `now`.
    @discardableResult
    mutating func setRetention(_ newRetention: TimeInterval?, now: Date) -> [ClipboardItem] {
        retention = newRetention
        return enforceLimits(now: now)
    }

    /// Drops items older than the retention at `now` (BR-4.4). The app
    /// calls it hourly, so an idle history still ages out without a copy.
    @discardableResult
    mutating func expire(now: Date) -> [ClipboardItem] {
        enforceLimits(now: now)
    }

    /// Drops expired items (when `now` is given), then from the bottom
    /// until both the count and the image budget fit.
    private mutating func enforceLimits(now: Date?) -> [ClipboardItem] {
        var evicted: [ClipboardItem] = []
        if let now, retention != nil {
            // Not just the tail: `promote` keeps order by last copy, but a
            // future-dated item (clock set back) can sit below older ones.
            items.removeAll { item in
                guard ClipboardHistoryPolicy.isExpired(item, now: now, retention: retention) else { return false }
                evicted.append(item)
                return true
            }
        }
        if items.count > limit {
            evicted.append(contentsOf: items[limit...])
            items.removeSubrange(limit...)
        }
        var imageBytes = totalImageBytes
        // Oldest image first; the newest item always stays, since a single
        // image is already capped at `maxImageBytes`, below the budget.
        var index = items.count - 1
        while imageBytes > ClipboardHistoryPolicy.maxTotalImageBytes, index > 0 {
            if let ref = items[index].imageRef {
                imageBytes -= ref.byteCount
                evicted.append(items.remove(at: index))
            }
            index -= 1
        }
        return evicted
    }
}
