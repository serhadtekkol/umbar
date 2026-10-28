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

    init(items: [ClipboardItem] = [], limit: Int = ClipboardHistoryPolicy.defaultLimit) {
        self.limit = ClipboardHistoryPolicy.clampedLimit(limit)
        self.items = items
        _ = enforceLimits()
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
        return removed + enforceLimits()
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
        return enforceLimits()
    }

    /// Drops from the bottom until both the count and the image budget fit.
    private mutating func enforceLimits() -> [ClipboardItem] {
        var evicted: [ClipboardItem] = []
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
