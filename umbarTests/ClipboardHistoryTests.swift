//
//  ClipboardHistoryTests.swift
//  umbarTests
//
//  F21: what the clipboard history records, folds and evicts
//  (ClipboardHistoryCore), and how it is kept on disk
//  (ClipboardHistoryStore, in a temporary directory). No pasteboard here.
//

import Foundation
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func text(_ s: String, _ offset: TimeInterval = 0) -> ClipboardItem {
    ClipboardItem(content: .text(s), copiedAt: t0.addingTimeInterval(offset))
}

private func image(bytes: Int, digest: String) -> ClipboardItem {
    let id = UUID()
    return ClipboardItem(id: id, content: .image(.init(fileName: "\(id.uuidString).png", typeIdentifier: "public.png",
                                                       byteCount: bytes, digest: digest)),
                         copiedAt: t0)
}

private func texts(_ history: ClipboardHistory) -> [String] {
    history.items.map {
        switch $0.content {
        case .text(let s), .url(let s): s
        case .image(let ref): "img:" + ref.digest
        }
    }
}

@Suite("ClipboardHistoryPolicy", .timeLimit(.minutes(1)))
struct ClipboardHistoryPolicyTests {
    @Test func blankTextIsNotRecorded() {
        #expect(ClipboardHistoryPolicy.content(forText: "") == nil)
        #expect(ClipboardHistoryPolicy.content(forText: " \n\t ") == nil)
    }

    @Test func textIsKeptExactlyAsCopied() {
        #expect(ClipboardHistoryPolicy.content(forText: "  indented\n") == .text("  indented\n"))
    }

    @Test(arguments: ["https://example.com/a?b=1", "http://localhost:8080", " https://example.com \n"])
    func webLinksBecomeURLs(_ s: String) {
        #expect(ClipboardHistoryPolicy.content(forText: s) == .url(s))
    }

    @Test(arguments: ["example.com", "ftp://example.com", "https://", "see https://example.com", "mailto:a@b.c", "file:///etc/hosts"])
    func otherStringsStayText(_ s: String) {
        #expect(ClipboardHistoryPolicy.content(forText: s) == .text(s))
    }

    @Test func overlongTextIsNotRecorded() {
        let limit = ClipboardHistoryPolicy.maxTextLength
        #expect(ClipboardHistoryPolicy.content(forText: String(repeating: "a", count: limit)) != nil)
        #expect(ClipboardHistoryPolicy.content(forText: String(repeating: "a", count: limit + 1)) == nil)
    }

    @Test func digestIsStableAndContentBased() {
        let a = ClipboardHistoryPolicy.digest(of: Data([1, 2, 3]))
        #expect(a == ClipboardHistoryPolicy.digest(of: Data([1, 2, 3])))
        #expect(a != ClipboardHistoryPolicy.digest(of: Data([1, 2, 4])))
        #expect(a.count == 64)
    }

    @Test func limitIsClamped() {
        #expect(ClipboardHistoryPolicy.clampedLimit(0) == 1)
        #expect(ClipboardHistoryPolicy.clampedLimit(50) == 50)
        #expect(ClipboardHistoryPolicy.clampedLimit(10_000) == 100)
    }
}

@Suite("ClipboardHistory", .timeLimit(.minutes(1)))
struct ClipboardHistoryTests {
    @Test func newestFirst() {
        var h = ClipboardHistory()
        h.insert(text("a"))
        h.insert(text("b"))
        #expect(texts(h) == ["b", "a"])
    }

    @Test func repeatCopyMovesToTopInsteadOfDuplicating() {
        var h = ClipboardHistory()
        let first = text("a")
        h.insert(first)
        h.insert(text("b"))
        let removed = h.insert(text("a", 10))
        #expect(texts(h) == ["a", "b"])
        #expect(removed == [first], "the folded copy is reported so its files can go")
    }

    @Test func textAndLinkWithSameCharactersAreDistinctOnlyByKind() {
        var h = ClipboardHistory()
        h.insert(ClipboardItem(content: .url("https://a.b"), copiedAt: t0))
        h.insert(ClipboardItem(content: .text("https://a.b"), copiedAt: t0))
        #expect(h.items.count == 2)
    }

    @Test func sameImageBytesFold() {
        var h = ClipboardHistory()
        h.insert(image(bytes: 10, digest: "x"))
        h.insert(image(bytes: 10, digest: "x"))
        h.insert(image(bytes: 10, digest: "y"))
        #expect(texts(h) == ["img:y", "img:x"])
    }

    @Test func capEvictsOldest() {
        var h = ClipboardHistory(limit: 10)
        for i in 0..<12 { h.insert(text("\(i)")) }
        #expect(h.items.count == 10)
        #expect(texts(h).first == "11")
        #expect(texts(h).last == "2")
    }

    @Test func insertReportsEvictedItems() {
        var h = ClipboardHistory(limit: 1)
        let a = text("a")
        h.insert(a)
        let evicted = h.insert(text("b"))
        #expect(evicted == [a])
    }

    @Test func shorteningTheLimitEvictsAtOnce() {
        var h = ClipboardHistory(limit: 50)
        for i in 0..<30 { h.insert(text("\(i)")) }
        let evicted = h.setLimit(10)
        #expect(h.items.count == 10)
        #expect(evicted.count == 20)
        #expect(texts(h).first == "29")
    }

    @Test func imageBudgetEvictsOldestImagesButKeepsText() {
        var h = ClipboardHistory(limit: 100)
        let big = ClipboardHistoryPolicy.maxImageBytes
        let perBudget = ClipboardHistoryPolicy.maxTotalImageBytes / big
        h.insert(text("old text"))
        for i in 0...perBudget { h.insert(image(bytes: big, digest: "\(i)")) }
        #expect(h.totalImageBytes <= ClipboardHistoryPolicy.maxTotalImageBytes)
        #expect(texts(h).contains("old text"), "only images pay for the image budget")
        #expect(!texts(h).contains("img:0"), "the oldest image went first")
        #expect(texts(h).first == "img:\(perBudget)")
    }

    @Test func promoteMovesToTopWithNewDate() {
        var h = ClipboardHistory()
        let a = text("a")
        h.insert(a)
        h.insert(text("b"))
        let promoted = h.promote(id: a.id, at: t0.addingTimeInterval(60))
        #expect(promoted)
        #expect(texts(h) == ["a", "b"])
        #expect(h.items[0].copiedAt == t0.addingTimeInterval(60))
        let unknown = h.promote(id: UUID(), at: t0)
        #expect(!unknown)
    }

    @Test func removeAndRemoveAll() {
        var h = ClipboardHistory()
        let a = text("a")
        h.insert(a)
        h.insert(text("b"))
        let first = h.remove(id: a.id)
        let again = h.remove(id: a.id)
        let rest = h.removeAll()
        #expect(first == a)
        #expect(again == nil)
        #expect(rest.count == 1)
        #expect(h.items.isEmpty)
    }

    @Test func retentionChoicesMatchBR44() {
        let day: TimeInterval = 86_400
        #expect(ClipboardHistoryPolicy.retention(days: 1) == day)
        #expect(ClipboardHistoryPolicy.retention(days: 7) == 7 * day)
        #expect(ClipboardHistoryPolicy.retention(days: 30) == 30 * day)
        #expect(ClipboardHistoryPolicy.retention(days: 0) == nil, "0 is unlimited")
        #expect(ClipboardHistoryPolicy.retention(days: 3) == 7 * day, "unknown values fall back to the default, not to unlimited")
    }

    @Test func expireDropsOnlyItemsPastTheRetention() {
        let day: TimeInterval = 86_400
        var h = ClipboardHistory(limit: 100, retention: 7 * day)
        let old = text("old", 0)
        let edge = text("edge", day)
        h.insert(old)
        h.insert(edge)
        h.insert(text("new", 7 * day))
        let now = t0.addingTimeInterval(8 * day)
        let evicted = h.expire(now: now)
        #expect(evicted == [old])
        #expect(texts(h) == ["new", "edge"], "exactly 7 days old is kept; strictly older goes")
    }

    @Test func insertExpiresAgainstTheNewCopysDate() {
        let day: TimeInterval = 86_400
        var h = ClipboardHistory(limit: 100, retention: day)
        let old = text("old", 0)
        h.insert(old)
        let evicted = h.insert(text("next", 2 * day))
        #expect(evicted == [old])
    }

    @Test func unlimitedRetentionKeepsEverything() {
        var h = ClipboardHistory(limit: 100, retention: nil)
        h.insert(text("ancient", -10_000 * 86_400))
        #expect(h.expire(now: t0).isEmpty)
        #expect(h.items.count == 1)
    }

    @Test func shorteningTheRetentionExpiresAtOnce() {
        var h = ClipboardHistory(limit: 100, retention: nil)
        h.insert(text("a", 0))
        h.insert(text("b", 3 * 86_400))
        let evicted = h.setRetention(86_400, now: t0.addingTimeInterval(3 * 86_400))
        #expect(evicted.count == 1)
        #expect(texts(h) == ["b"])
    }

    @Test func initFromLoadedItemsAppliesTheLimit() {
        let loaded = (0..<20).map { text("\($0)") }
        #expect(ClipboardHistory(items: loaded, limit: 10).items.count == 10)
    }
}

@Suite("ClipboardHistoryStore", .timeLimit(.minutes(1)))
struct ClipboardHistoryStoreTests {
    private let root: URL
    private let store: ClipboardHistoryStore

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbarTests.clipboard.\(UUID().uuidString)", isDirectory: true)
        store = ClipboardHistoryStore(directory: root.appendingPathComponent("ClipboardHistory", isDirectory: true))
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func roundTripsWithOwnerOnlyPermissions() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let img = image(bytes: 3, digest: "d")
        let items = [text("hello"), ClipboardItem(content: .url("https://a.b"), copiedAt: t0), img]
        store.writeImage(Data([1, 2, 3]), for: img.imageRef!)
        store.save(items)
        store.flush()

        #expect(store.load() == items)
        #expect(try mode(store.directory) == 0o700)
        #expect(try mode(store.directory.appendingPathComponent("index.json")) == 0o600)
        #expect(try mode(store.imageURL(for: img.imageRef!)!) == 0o600)
        let excluded = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
    }

    @Test func itemsWhoseImageIsGoneAreDroppedAndOrphansDeleted() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = image(bytes: 1, digest: "k")
        let lost = image(bytes: 1, digest: "l")
        store.writeImage(Data([1]), for: kept.imageRef!)
        store.writeImage(Data([2]), for: image(bytes: 1, digest: "orphan").imageRef!)
        store.save([kept, lost])
        store.flush()

        #expect(store.load() == [kept])
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted()
        #expect(files == ["index.json", kept.imageRef!.fileName].sorted())
    }

    @Test func deleteImagesRemovesTheirFiles() {
        defer { try? FileManager.default.removeItem(at: root) }
        let img = image(bytes: 1, digest: "x")
        store.writeImage(Data([1]), for: img.imageRef!)
        store.deleteImages(of: [img, text("no file")])
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: store.imageURL(for: img.imageRef!)!.path))
    }

    /// A tampered index must not turn "delete this image" into "delete a
    /// file of the user's".
    @Test func neverDeletesOutsideItsDirectory() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let victim = root.appendingPathComponent("victim.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: victim)
        let hostile = ClipboardItem(content: .image(.init(fileName: "../victim.txt", typeIdentifier: "public.png",
                                                          byteCount: 1, digest: "h")), copiedAt: t0)
        store.save([])
        store.deleteImages(of: [hostile])
        store.flush()
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    @Test func wipeRemovesEverything() {
        defer { try? FileManager.default.removeItem(at: root) }
        store.save([text("secret")])
        store.wipe()
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
        #expect(store.load().isEmpty)
    }

    @Test func corruptIndexLoadsEmpty() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.directory.appendingPathComponent("index.json"))
        #expect(store.load().isEmpty)
    }

    /// BR-4.4 at launch: an index left alone for longer than the retention
    /// comes back without the aged items, and an aged image's file goes too.
    @Test func agedItemsAreNotLoadedAndTheirFilesAreRemoved() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let now = t0.addingTimeInterval(8 * 86_400)
        let agedImage = image(bytes: 1, digest: "aged")
        let agedText = text("aged secret")
        let fresh = text("fresh", 8 * 86_400 - 60)
        store.writeImage(Data([9]), for: agedImage.imageRef!)
        store.save([fresh, agedText, agedImage])
        store.flush()

        #expect(store.load(now: now, retention: 7 * 86_400) == [fresh])
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: store.imageURL(for: agedImage.imageRef!)!.path))
        let index = try String(contentsOf: store.directory.appendingPathComponent("index.json"), encoding: .utf8)
        #expect(!index.contains("aged secret"), "the index is rewritten without the aged text")
        #expect(store.load(now: now, retention: 7 * 86_400) == [fresh])
    }

    @Test(arguments: ["", ".", "..", "../victim.txt", "index.json", "abc.png",
                      "00000000-0000-0000-0000-000000000000.jpg",
                      "00000000-0000-0000-0000-00000000000a.png",
                      "00000000-0000-0000-0000-000000000000.png/../x"])
    func invalidImageFileNamesNeverResolve(_ name: String) {
        let ref = ClipboardItem.ImageRef(fileName: name, typeIdentifier: "public.png", byteCount: 1, digest: "x")
        #expect(store.imageURL(for: ref) == nil)
    }

    @Test func validImageFileNamesResolveInsideTheStore() {
        let name = "\(UUID().uuidString).tiff"
        let ref = ClipboardItem.ImageRef(fileName: name, typeIdentifier: "public.tiff", byteCount: 1, digest: "x")
        #expect(store.imageURL(for: ref) == store.directory.appendingPathComponent(name))
    }

    /// L7: a tampered index whose image names the store itself (empty name)
    /// or the index is dropped on load, and nothing is deleted for it.
    @Test func itemsWithInvalidFileNamesAreDroppedOnLoad() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let good = text("good")
        store.save([good])
        store.flush()
        let hostile = [
            ClipboardItem(content: .image(.init(fileName: "", typeIdentifier: "public.png", byteCount: 1, digest: "e")), copiedAt: t0),
            ClipboardItem(content: .image(.init(fileName: "index.json", typeIdentifier: "public.png", byteCount: 1, digest: "i")), copiedAt: t0),
        ]
        try JSONEncoder().encode([good] + hostile).write(to: store.directory.appendingPathComponent("index.json"))

        #expect(store.load() == [good])
        store.flush()
        #expect(FileManager.default.fileExists(atPath: store.directory.path))
        #expect(store.load() == [good])
    }

    @Test func writesLeaveNoTemporaryFiles() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        store.save([text("x")])
        store.flush()
        #expect(try mode(store.directory.appendingPathComponent("index.json")) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        #expect(leftovers == ["index.json"], "no temporary file is left behind")
    }

    @Test func backupExclusionIsRestoredOnEveryWrite() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        store.save([text("a")])
        store.flush()
        var dir = store.directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try dir.setResourceValues(values)
        store.save([text("b")])
        store.flush()
        dir.removeAllCachedResourceValues()
        #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func aSymlinkedStoreIsNeitherReadNorWritten() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try JSONEncoder().encode([text("planted")]).write(to: elsewhere.appendingPathComponent("index.json"))
        try FileManager.default.createSymbolicLink(at: store.directory, withDestinationURL: elsewhere)

        #expect(store.load().isEmpty)
        store.save([text("secret")])
        store.flush()
        let planted = try String(contentsOf: elsewhere.appendingPathComponent("index.json"), encoding: .utf8)
        #expect(!planted.contains("secret"))
    }

    @Test func missingDirectoryLoadsEmpty() {
        #expect(store.load().isEmpty)
    }
}
