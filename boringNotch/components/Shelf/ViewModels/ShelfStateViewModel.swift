//
//  ShelfStateViewModel.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-09.

import Foundation
import AppKit
import SwiftUI

@MainActor
final class ShelfStateViewModel: ObservableObject {
    static let shared = ShelfStateViewModel()

    @Published private(set) var items: [ShelfItem] = [] {
        didSet { ShelfPersistenceService.shared.save(items) }
    }

    @Published var isLoading: Bool = false

    var isEmpty: Bool { items.isEmpty }

    // Queue for deferred bookmark updates to avoid publishing during view updates
    private var pendingBookmarkUpdates: [ShelfItem.ID: Data] = [:]
    private var updateTask: Task<Void, Never>?

    /// Confirms moves out of the shelf before their items are removed.
    private let moveWatcher = ShelfMoveOutcomeWatcher()

    /// Items moved out of the shelf a moment ago, with their Undo (card #100).
    /// The "Taşındı · Geri al" chip (card #101) observes this.
    let moveUndo = ShelfMoveUndoModel()

    private var pendingMoveNames: [String] = []
    private var moveAnnouncement: Task<Void, Never>?

    private init() {
        items = ShelfPersistenceService.shared.load()
        moveUndo.onRestore = { [weak self] item, index in self?.restore(item, at: index) }
    }


    func add(_ newItems: [ShelfItem]) {
        guard !newItems.isEmpty else { return }
        var merged = items
        // Deduplicate by identityKey while preserving order (existing first)
        var seen: Set<String> = Set(merged.map { $0.identityKey })
        for it in newItems {
            let key = it.identityKey
            if !seen.contains(key) {
                merged.append(it)
                seen.insert(key)
            }
        }
        items = merged
    }

    func remove(_ item: ShelfItem) {
        moveWatcher.cancel(item.id)
        item.cleanupStoredData()
        items.removeAll { $0.id == item.id }
    }

    /// Takes items off the shelf after they were dropped somewhere else
    /// (BR-3.5), according to `action`.
    ///
    /// Unlike `remove(_:)`, this never deletes an item's temporary file. After
    /// a copy the destination may still be reading it: a browser upload field
    /// reads the file when the form is sent, not when the file is dropped. The
    /// file stays in $TMPDIR, which macOS purges of long-unused files on its
    /// own. After a move the file is no longer ours to delete.
    ///
    /// After a confirmed move the item leaves the shelf and becomes a ghost
    /// in `moveUndo`, which offers Undo for a few seconds (card #100).
    ///
    /// - Parameters:
    ///   - sources: each item's file when the drag started, used to confirm a
    ///     move and to find where it went. An item without an entry is kept.
    ///   - recorder: the drag's FSEvents recording of the other volumes, if
    ///     one could start. Stopped here once nothing needs it any more.
    func handleDragEnd(_ action: ShelfDragEndAction, for dragged: [ShelfItem], sources: [ShelfItem.ID: ShelfDragSource], recorder: ShelfMoveDestinationRecorder?) {
        switch action {
        case .keep:
            recorder?.stop()
        case .remove:
            recorder?.stop()
            let ids = Set(dragged.map(\.id))
            ids.forEach(moveWatcher.cancel)
            items.removeAll { ids.contains($0.id) }
        case .removeOnceSourceLeaves:
            var watches: [Task<Void, Never>] = []
            for item in dragged {
                guard let source = sources[item.id] else { continue }
                watches.append(moveWatcher.watch(id: item.id, path: source.path, original: source.identity) { [weak self] in
                    self?.moveConfirmed(item, source: source, recorder: recorder)
                })
            }
            guard let recorder else { return }
            let ids = dragged.map(\.id)
            Task { [weak self] in
                for watch in watches { await watch.value }
                for id in ids { await self?.moveUndo.locateTask(for: id)?.value }
                recorder.stop()
            }
        }
    }

    /// The file of `item` has left its path: take the item off the shelf and
    /// leave a ghost that can undo the move.
    private func moveConfirmed(_ item: ShelfItem, source: ShelfDragSource, recorder: ShelfMoveDestinationRecorder?) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let current = items[index]
        items.remove(at: index)
        var bookmark: Data?
        if case .file(let data) = current.kind { bookmark = data }
        announceMove(source.name)
        moveUndo.recordMove(of: current, at: index, source: source) { [bookmark] in
            await ShelfMoveDestinationLocator.locate(
                source: source,
                bookmark: bookmark,
                recordedPaths: { recorder?.recordedPaths() ?? [] }
            )
        }
    }

    /// Says "Taşındı: …" once per drag, whether or not the Raf page is on
    /// screen (the panel often closes as the pointer reaches Finder). A
    /// multi-item move confirms item by item, so names arriving within a
    /// moment of each other are said together.
    private func announceMove(_ name: String) {
        pendingMoveNames.append(name)
        moveAnnouncement?.cancel()
        moveAnnouncement = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            let names = self.pendingMoveNames
            self.pendingMoveNames = []
            let subject = names.count == 1
                ? names[0]
                : String(localized: "shelf.undo.items", defaultValue: "\(names.count) items")
            AccessibilityNotification.Announcement(String(
                localized: "shelf.undo.moved.announcement",
                defaultValue: "Moved: \(subject). Undo is on the Shelf page."
            )).post()
        }
    }

    /// Puts an item back after Undo, at its old position or the end. An item
    /// for the same file that was added again in the meantime wins.
    private func restore(_ item: ShelfItem, at index: Int) {
        let key = item.identityKey
        guard !items.contains(where: { $0.id == item.id || $0.identityKey == key }) else { return }
        items.insert(item, at: min(max(index, 0), items.count))
    }

    func updateBookmark(for item: ShelfItem, bookmark: Data) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if case .file = items[idx].kind {
            items[idx].kind = .file(bookmark: bookmark)
        }
    }

    private func scheduleDeferredBookmarkUpdate(for item: ShelfItem, bookmark: Data) {
        pendingBookmarkUpdates[item.id] = bookmark
        
        // Cancel existing task and schedule a new one
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await Task.yield()
            
            guard let self = self else { return }
            
            for (itemID, bookmarkData) in self.pendingBookmarkUpdates {
                if let idx = self.items.firstIndex(where: { $0.id == itemID }),
                   case .file = self.items[idx].kind {
                    self.items[idx].kind = .file(bookmark: bookmarkData)
                }
            }
            
            self.pendingBookmarkUpdates.removeAll()
        }
    }


    func load(_ providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        isLoading = true
        Task { [weak self] in
            let dropped = await ShelfDropService.items(from: providers)
            await MainActor.run {
                self?.add(dropped)
                self?.isLoading = false
            }
        }
    }

    func cleanupInvalidItems() {
        Task { [weak self] in
            guard let self else { return }
            var keep: [ShelfItem] = []
            for item in self.items {
                switch item.kind {
                case .file(let data):
                    let bookmark = Bookmark(data: data)
                    if await bookmark.validate() {
                        keep.append(item)
                    } else {
                        item.cleanupStoredData()
                    }
                }
            }
            await MainActor.run { self.items = keep }
        }
    }


    func resolveFileURL(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            scheduleDeferredBookmarkUpdate(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveAndUpdateBookmark(for item: ShelfItem) -> URL? {
        guard case .file(let bookmarkData) = item.kind else { return nil }
        let bookmark = Bookmark(data: bookmarkData)
        let result = bookmark.resolve()
        if let refreshed = result.refreshedData, refreshed != bookmarkData {
            NSLog("Bookmark for \(item) stale; refreshing")
            updateBookmark(for: item, bookmark: refreshed)
        }
        return result.url
    }

    func resolveFileURLs(for items: [ShelfItem]) -> [URL] {
        var urls: [URL] = []
        for it in items {
            if let u = resolveFileURL(for: it) { urls.append(u) }
        }
        return urls
    }
}
