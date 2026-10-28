//
//  ClipboardHistoryModel.swift
//  umbar
//
//  F21: the app-side owner of the clipboard history. Follows the Settings
//  switch and length, turns ClipboardMonitor events into history items,
//  persists them through ClipboardHistoryStore and copies items back.
//

import AppKit
import Combine
import Defaults
import ImageIO
import os

@MainActor
final class ClipboardHistoryModel: ObservableObject {
    static let shared = ClipboardHistoryModel(store: ClipboardHistoryStore(directory: ClipboardHistoryStore.defaultDirectory()))

    /// Newest first.
    @Published private(set) var items: [ClipboardItem] = []
    /// True when the last copy could not be read because macOS asks before
    /// an app reads the pasteboard and umbar is not set to "Allow" under
    /// Privacy & Security > Paste from Other Apps (spike A2, AC-4.8).
    @Published private(set) var permissionRequired = false
    /// The item just copied back, for the card's brief confirmation.
    @Published private(set) var justCopiedID: UUID?

    private var history = ClipboardHistory()
    private let store: ClipboardHistoryStore?
    private var monitor: ClipboardMonitor?
    private var observations: Set<AnyCancellable> = []
    /// Downsampled previews, built once per image item. Not published: a
    /// miss is filled while the card is being drawn.
    private var thumbnails: [UUID: NSImage] = [:]
    private var confirmationReset: DispatchWorkItem?
    /// Hourly BR-4.4 sweep while the history is on.
    private var expiryTimer: Timer?
    private let log = Logger(subsystem: "umbar", category: "ClipboardHistory")

    /// How long a card says "Copied" after a click.
    static let confirmationDuration: TimeInterval = 1.2
    /// How often aged items are swept while umbar runs. With a 1-day
    /// retention an item outlives it by at most this much.
    static let expiryInterval: TimeInterval = 3600
    /// Longest side of a card preview, in pixels (2x the card's 120 pt).
    private static let thumbnailPixels = 240

    init(store: ClipboardHistoryStore?) {
        self.store = store
    }

    #if DEBUG
    /// For the page renderer: fixed items, no monitor, no disk.
    init(fixture: [ClipboardItem], images: [UUID: NSImage] = [:], permissionRequired: Bool = false, justCopied: UUID? = nil) {
        self.store = nil
        self.history = ClipboardHistory(items: fixture, limit: ClipboardHistoryPolicy.limitChoices.max() ?? 100)
        self.items = history.items
        self.thumbnails = images
        self.permissionRequired = permissionRequired
        self.justCopiedID = justCopied
    }
    #endif

    /// Begins following Settings. Call once at launch; idempotent. Defaults
    /// publishers emit the current value first, so a history switched off
    /// while umbar was not running is wiped here too.
    func activate() {
        guard observations.isEmpty else { return }
        Defaults.publisher(.clipboardHistoryEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                MainActor.assumeIsolated { self?.setEnabled(change.newValue) }
            }
            .store(in: &observations)
        Defaults.publisher(.clipboardHistoryLimit)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                MainActor.assumeIsolated { self?.setLimit(change.newValue) }
            }
            .store(in: &observations)
        Defaults.publisher(.clipboardHistoryRetentionDays)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                MainActor.assumeIsolated { self?.setRetention(days: change.newValue) }
            }
            .store(in: &observations)
    }

    /// Waits for queued disk writes. Called at quit.
    func flush() {
        store?.flush()
    }

    // MARK: User actions

    /// Puts the item back on the general pasteboard and moves it to the top.
    func copy(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        switch item.content {
        case .text(let text):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .url(let link):
            pasteboard.clearContents()
            pasteboard.setString(link, forType: .string)
            pasteboard.setString(link, forType: .URL)
        case .image(let ref):
            guard let url = store?.imageURL(for: ref), let data = try? Data(contentsOf: url) else {
                // The file is gone (deleted by hand); the item cannot be
                // copied back, so it should not stay in the list either.
                delete(item)
                return
            }
            pasteboard.clearContents()
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(ref.typeIdentifier))
        }
        // Our own write must not come back as a new copy.
        monitor?.ignoreCurrentContents()
        history.promote(id: item.id, at: Date())
        publishAndSave()
        confirmCopy(of: item.id)
    }

    func delete(_ item: ClipboardItem) {
        guard let removed = history.remove(id: item.id) else { return }
        forget([removed])
        publishAndSave()
    }

    func clearAll() {
        forget(history.removeAll())
        publishAndSave()
    }

    /// System Settings > Privacy & Security > Paste from Other Apps. The
    /// anchor comes from the system's own plist (spike A2, E7).
    func openPasteboardPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
            NSWorkspace.shared.open(url)
        }
    }

    func thumbnail(for item: ClipboardItem) -> NSImage? {
        if let cached = thumbnails[item.id] { return cached }
        guard let ref = item.imageRef, let url = store?.imageURL(for: ref),
              let image = Self.downsampled(url: url) else { return nil }
        thumbnails[item.id] = image
        return image
    }

    // MARK: Following Settings

    private func setEnabled(_ enabled: Bool) {
        if enabled {
            guard monitor == nil else { return }
            let retention = ClipboardHistoryPolicy.retention(days: Defaults[.clipboardHistoryRetentionDays])
            history = ClipboardHistory(items: store?.load(now: Date(), retention: retention) ?? [],
                                       limit: Defaults[.clipboardHistoryLimit], retention: retention)
            items = history.items
            startExpiryTimer()
            let m = ClipboardMonitor(excludedBundleIDs: { Set(Defaults[.clipboardExcludedBundleIDs]) }) { [weak self] event in
                self?.handle(event)
            }
            monitor = m
            m.start()
            log.info("clipboard history on, \(self.items.count, privacy: .public) items")
        } else {
            monitor?.stop()
            monitor = nil
            expiryTimer?.invalidate()
            expiryTimer = nil
            history.removeAll()
            thumbnails = [:]
            items = []
            permissionRequired = false
            // Off means gone, not hidden (brief: "clear on toggle off").
            store?.wipe()
            log.info("clipboard history off, wiped")
        }
    }

    private func setLimit(_ limit: Int) {
        let evicted = history.setLimit(limit)
        guard !evicted.isEmpty else { return }
        forget(evicted)
        publishAndSave()
    }

    private func setRetention(days: Int) {
        let evicted = history.setRetention(ClipboardHistoryPolicy.retention(days: days), now: Date())
        guard !evicted.isEmpty else { return }
        forget(evicted)
        publishAndSave()
    }

    private func startExpiryTimer() {
        expiryTimer?.invalidate()
        let timer = Timer(timeInterval: Self.expiryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireAgedItems() }
        }
        // Precision does not matter for an hourly sweep; let it coalesce.
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    private func expireAgedItems() {
        let evicted = history.expire(now: Date())
        guard !evicted.isEmpty else { return }
        forget(evicted)
        publishAndSave()
        log.info("clipboard history: \(evicted.count, privacy: .public) aged items removed")
    }

    // MARK: Monitor events

    private func handle(_ event: ClipboardEvent) {
        switch event {
        case .captured(let text, _):
            permissionRequired = false
            guard let content = ClipboardHistoryPolicy.content(forText: text) else { return }
            record(ClipboardItem(content: content, copiedAt: Date()), image: nil)
        case .capturedImage(let data, let type, _):
            permissionRequired = false
            guard data.count <= ClipboardHistoryPolicy.maxImageBytes else {
                log.debug("image over the size cap, not recorded")
                return
            }
            let id = UUID()
            let uti = type == .png ? "public.png" : "public.tiff"
            let ref = ClipboardItem.ImageRef(
                fileName: "\(id.uuidString).\(ClipboardHistoryPolicy.fileExtension(forTypeIdentifier: uti))",
                typeIdentifier: uti, byteCount: data.count,
                digest: ClipboardHistoryPolicy.digest(of: data))
            record(ClipboardItem(id: id, content: .image(ref), copiedAt: Date()), image: data)
        case .permissionRequired:
            permissionRequired = true
        case .skippedSensitive, .skippedNonText, .skippedSourceApp:
            break
        }
    }

    private func record(_ item: ClipboardItem, image: Data?) {
        if let image, let ref = item.imageRef {
            store?.writeImage(image, for: ref)
            if let thumb = Self.downsampled(data: image) { thumbnails[item.id] = thumb }
        }
        forget(history.insert(item))
        publishAndSave()
    }

    // MARK: Helpers

    private func forget(_ removed: [ClipboardItem]) {
        for item in removed { thumbnails[item.id] = nil }
        store?.deleteImages(of: removed)
    }

    private func publishAndSave() {
        items = history.items
        store?.save(history.items)
    }

    private func confirmCopy(of id: UUID) {
        confirmationReset?.cancel()
        justCopiedID = id
        let reset = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                if self?.justCopiedID == id { self?.justCopiedID = nil }
            }
        }
        confirmationReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmationDuration, execute: reset)
    }

    private static func downsampled(url: URL) -> NSImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(thumbnail(from:))
    }

    private static func downsampled(data: Data) -> NSImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(thumbnail(from:))
    }

    private static func thumbnail(from source: CGImageSource) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
    }
}
