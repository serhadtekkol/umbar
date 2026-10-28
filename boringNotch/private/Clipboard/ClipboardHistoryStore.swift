//
//  ClipboardHistoryStore.swift
//  umbar
//
//  F21: the clipboard history on disk. Foundation only, so umbarTests can
//  run it against a temporary directory.
//
//  Why on disk and not memory-only: a history that empties at every
//  relaunch, update or login loses the one thing a clipboard history is for
//  ("what did I copy this morning?"). What makes the disk copy acceptable:
//  - sensitive copies are never read in the first place (ClipboardMonitor:
//    nspasteboard.org markers, password-manager apps), so they cannot reach
//    this file;
//  - the directory is 0700 and every file 0600, so other local users and
//    processes running as other users cannot read it;
//  - the directory is excluded from Time Machine, so the history does not
//    outlive "Clear all" inside a backup;
//  - turning the feature off and "Clear all" delete the files, not only the
//    in-memory list;
//  - items older than the retention (BR-4.4, default 7 days) are dropped
//    at load and hourly, image files included;
//  - images over `ClipboardHistoryPolicy.maxImageBytes` are never written.
//  It is not encrypted at rest: anything running as the user can read the
//  user's files anyway, and FileVault covers the stolen-disk case.
//

import Foundation
import os

/// Reads and writes the history index (`index.json`) and one file per image.
///
/// Threading: `load()` is synchronous and meant for launch. Every write is
/// queued on one serial queue in call order, so an image file is always
/// written before the index that names it, and a wipe cannot be overtaken
/// by a save queued before it.
final class ClipboardHistoryStore: Sendable {
    let directory: URL
    private let queue = DispatchQueue(label: "umbar.clipboard-history.store", qos: .utility)
    private let log = Logger(subsystem: "umbar", category: "ClipboardHistory")

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/<bundle id>/ClipboardHistory`.
    static func defaultDirectory(bundleID: String = Bundle.main.bundleIdentifier ?? "umbar") -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("ClipboardHistory", isDirectory: true)
    }

    /// Where an image's bytes live, or `nil` when `ref.fileName` is not a
    /// name this store writes. Every path to an image goes through here, so
    /// an index edited to say `""`, `".."` or `"../x"` can never make a
    /// read, write or delete land on the store directory itself or outside
    /// it.
    func imageURL(for ref: ClipboardItem.ImageRef) -> URL? {
        guard Self.isValidImageFileName(ref.fileName) else { return nil }
        return directory.appendingPathComponent(ref.fileName)
    }

    /// `<UUID>.png` or `<UUID>.tiff`, as `ClipboardHistoryModel` names them
    /// (`UUID.uuidString` is upper-case hex).
    static func isValidImageFileName(_ name: String) -> Bool {
        name.wholeMatch(of: /[0-9A-F-]{36}\.(png|tiff)/) != nil
    }

    /// The saved items, newest first, without the ones that must not come
    /// back:
    /// - older than `retention` at `now` (BR-4.4), so a history left alone
    ///   while umbar was not running still ages out at the next launch;
    /// - naming an image file that is gone, or whose `fileName` is not one
    ///   this store writes (`isValidImageFileName`; a tampered index);
    /// Image files no surviving item names are deleted, which is how an
    /// expired image's file goes with it. When anything was dropped the
    /// survivors are saved back, so the expired text does not linger in
    /// `index.json` until the next copy.
    ///
    /// Returns `[]` when there is no index, it cannot be decoded (a corrupt
    /// index is not worth a launch failure; it is replaced on the next
    /// save), or the store directory is a symlink.
    func load(now: Date = Date(), retention: TimeInterval? = nil) -> [ClipboardItem] {
        let fm = FileManager.default
        guard !Self.isSymlink(directory) else {
            log.error("clipboard store is a symlink, not loading")
            return []
        }
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoded: [ClipboardItem]
        do {
            decoded = try JSONDecoder().decode([ClipboardItem].self, from: data)
        } catch {
            log.error("clipboard index unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let items = decoded.filter { item in
            if ClipboardHistoryPolicy.isExpired(item, now: now, retention: retention) { return false }
            guard let ref = item.imageRef else { return true }
            guard let url = imageURL(for: ref) else { return false }
            return fm.fileExists(atPath: url.path)
        }
        let named = Set(items.compactMap(\.imageRef?.fileName))
        let present = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in present where name != indexURL.lastPathComponent && !named.contains(name) {
            removeOwnFile(directory.appendingPathComponent(name))
        }
        if items.count != decoded.count { save(items) }
        return items
    }

    func save(_ items: [ClipboardItem]) {
        queue.async { [self] in
            do {
                try prepareDirectory()
                let data = try JSONEncoder().encode(items)
                try writeProtected(data, to: indexURL)
            } catch {
                log.error("clipboard index save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func writeImage(_ data: Data, for ref: ClipboardItem.ImageRef) {
        queue.async { [self] in
            do {
                guard let url = imageURL(for: ref) else { return }
                try prepareDirectory()
                try writeProtected(data, to: url)
            } catch {
                log.error("clipboard image save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Deletes the image files of items that left the history.
    func deleteImages(of items: [ClipboardItem]) {
        let urls = items.compactMap { $0.imageRef.flatMap(imageURL(for:)) }
        guard !urls.isEmpty else { return }
        queue.async { [self] in
            for url in urls { removeOwnFile(url) }
        }
    }

    /// Removes the whole directory: index, images and anything else in it.
    func wipe() {
        queue.async { [self] in
            removeOwnFile(directory)
        }
    }

    /// The store's only delete. Refuses anything outside `directory`, so a
    /// crafted `fileName` in a tampered index ("../../Documents") cannot make
    /// umbar delete a user file. This is the call ShelfDeletionRuleTests
    /// allows for this file.
    private func removeOwnFile(_ url: URL) {
        let base = directory.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        guard target == base || target.hasPrefix(base + "/") else {
            log.error("refused to delete outside the clipboard store")
            return
        }
        try? FileManager.default.removeItem(atPath: target)
    }

    /// Blocks until every queued write has finished. For tests and for
    /// app termination.
    func flush() {
        queue.sync {}
    }

    enum StoreError: Error {
        /// The store path is a symlink; writing through it could put the
        /// history wherever the link points.
        case symlinkedDirectory
    }

    /// Creates the directory if needed and re-asserts its protections on
    /// every write: owner-only mode and the Time Machine exclusion (an older
    /// build, a restore or a hand `chmod` may have dropped either).
    private func prepareDirectory() throws {
        let fm = FileManager.default
        if Self.isSymlink(directory) { throw StoreError.symlinkedDirectory }
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
    }

    /// `lstat`, so a symlink is seen as itself and not as its target.
    static func isSymlink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    /// Atomic write with owner-only permissions from the first byte: a
    /// temporary file is created 0600 with `O_CREAT | O_EXCL` (never
    /// following or reusing an existing name), filled, and renamed over the
    /// target. `Data.write(options: .atomic)` would create it with the
    /// umask's mode and leave a window before a later chmod.
    private func writeProtected(_ data: Data, to url: URL) throws {
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            removeOwnFile(temporary)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            removeOwnFile(temporary)
            throw POSIXError(code)
        }
    }
}
