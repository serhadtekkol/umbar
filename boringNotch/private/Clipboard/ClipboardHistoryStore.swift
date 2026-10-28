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

    func imageURL(for ref: ClipboardItem.ImageRef) -> URL {
        directory.appendingPathComponent(ref.fileName)
    }

    /// The saved items, newest first. Items whose image file is gone are
    /// dropped, and image files no item names are deleted. Returns `[]` when
    /// there is no index or it cannot be decoded (a corrupt index is not
    /// worth a launch failure; it is replaced on the next save).
    func load() -> [ClipboardItem] {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoded: [ClipboardItem]
        do {
            decoded = try JSONDecoder().decode([ClipboardItem].self, from: data)
        } catch {
            log.error("clipboard index unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            return []
        }
        let items = decoded.filter { item in
            guard let ref = item.imageRef else { return true }
            return fm.fileExists(atPath: imageURL(for: ref).path)
        }
        let named = Set(items.compactMap(\.imageRef?.fileName))
        let present = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in present where name != indexURL.lastPathComponent && !named.contains(name) {
            removeOwnFile(directory.appendingPathComponent(name))
        }
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
                try prepareDirectory()
                try writeProtected(data, to: imageURL(for: ref))
            } catch {
                log.error("clipboard image save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Deletes the image files of items that left the history.
    func deleteImages(of items: [ClipboardItem]) {
        let names = items.compactMap(\.imageRef?.fileName)
        guard !names.isEmpty else { return }
        queue.async { [self] in
            for name in names { removeOwnFile(directory.appendingPathComponent(name)) }
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

    private func prepareDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            var dir = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        // Also on every write: a directory created by an older build, or
        // chmod-ed by hand, is brought back to owner-only.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Atomic write, then owner-only permissions. The temporary file the
    /// atomic write renames into place briefly has the default mode, but it
    /// sits inside the 0700 directory, which nobody else can enter.
    private func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
