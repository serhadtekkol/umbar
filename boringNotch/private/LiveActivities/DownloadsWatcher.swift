//
//  DownloadsWatcher.swift
//  boringNotch
//
//  F19 live activities: follows one folder (normally ~/Downloads) for
//  unfinished browser downloads, finished downloads and AirDrop arrivals.
//
//  Two triggers, because the folder's own vnode events only cover entries
//  being added, removed or renamed:
//  - a DispatchSource on the folder rescans the listing on every change;
//  - while at least one download is unfinished, a 1 s timer re-reads its
//    size (Chrome, Firefox) or Info.plist (Safari), which change inside the
//    entry and fire nothing on the folder. With no download running the
//    timer is off and the watcher costs nothing.
//

import Darwin
import Foundation
import os

/// An unfinished download as last read.
struct RunningDownload: Equatable, Sendable {
    let entry: String
    let kind: PartialDownloadKind
    /// The final file name, or nil while Chrome still calls it "Unconfirmed".
    let finalName: String?
    var bytesSoFar: Int64?
    var totalBytes: Int64?
    var bytesPerSecond: Double?
    let startedAt: Date

    var fraction: Double? {
        guard let bytesSoFar, let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesSoFar) / Double(totalBytes)))
    }
}

enum DownloadsWatcherEvent: Sendable {
    /// Every unfinished download, replacing the previous list.
    case running([RunningDownload])
    case finished(URL)
    case airDropReceived(URL)
    /// The folder could not be opened. For ~/Downloads that means the user
    /// declined (or later removed) umbar's Files and Folders access.
    case accessDenied
}

/// Owns its state on a private serial queue; the callback is delivered on
/// the main queue.
final class DownloadsWatcher: @unchecked Sendable {
    private let folder: URL
    private let watchAirDrop: Bool
    private let onEvent: @MainActor (DownloadsWatcherEvent) -> Void
    private let queue = DispatchQueue(label: "umbar.liveactivities.downloads", qos: .utility)
    private let log = Logger(subsystem: "umbar", category: "LiveActivities")

    // Queue-confined state.
    private var source: DispatchSourceFileSystemObject?
    private var progressTimer: DispatchSourceTimer?
    private var listing = DownloadsListing()
    private var running: [String: RunningDownload] = [:]
    private var rates: [String: TransferRateEstimator] = [:]

    init(folder: URL, watchAirDrop: Bool, onEvent: @escaping @MainActor (DownloadsWatcherEvent) -> Void) {
        self.folder = folder
        self.watchAirDrop = watchAirDrop
        self.onEvent = onEvent
    }

    func start() {
        queue.async { self.startOnQueue() }
    }

    func stop() {
        queue.async {
            self.source?.cancel()
            self.source = nil
            self.progressTimer?.cancel()
            self.progressTimer = nil
            self.running = [:]
            self.rates = [:]
        }
    }

    // MARK: - Queue

    private func startOnQueue() {
        guard source == nil else { return }
        // O_EVTONLY: watch without keeping the volume busy (it can still be
        // ejected). This open() or the listing below is what raises the
        // Downloads-folder TCC prompt, which is why start() runs only after
        // the user asked for the feature. TCC blocks the calling thread while
        // the prompt is up; that is this queue, never main.
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else {
            let err = errno
            log.error("downloads watch could not open folder: errno \(err, privacy: .public)")
            emit(.accessDenied)
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        src.setEventHandler { [weak self] in self?.rescan() }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()

        // The first listing is the baseline: whatever is already there is
        // not news. Downloads already in progress are shown, though.
        guard let names = listNames() else {
            emit(.accessDenied)
            return
        }
        listing = DownloadsListing(entryNames: names)
        let now = Date()
        for (entry, partial) in listing.partials {
            track(entry, partial, now: now)
        }
        refreshProgress()
    }

    private func listNames() -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    private func rescan() {
        guard let names = listNames() else {
            emit(.accessDenied)
            return
        }
        let next = DownloadsListing(entryNames: names)
        let change = DownloadsListingChange.between(listing, next)
        listing = next
        guard !change.isEmpty else { return }

        let now = Date()
        for entry in change.started {
            if let partial = next.partials[entry] { track(entry, partial, now: now) }
        }
        for entry in change.vanished {
            running[entry] = nil
            rates[entry] = nil
        }
        for done in change.finished {
            running[done.entry] = nil
            rates[done.entry] = nil
            emit(.finished(folder.appendingPathComponent(done.finalName)))
        }
        if watchAirDrop {
            for name in change.appeared {
                let url = folder.appendingPathComponent(name)
                if let record = Self.quarantine(of: url), record.isRecentAirDrop(now: now) {
                    emit(.airDropReceived(url))
                }
            }
        }
        refreshProgress()
    }

    private func track(_ entry: String, _ partial: PartialDownloadName, now: Date) {
        running[entry] = RunningDownload(
            entry: entry, kind: partial.kind, finalName: partial.finalName, startedAt: now)
        rates[entry] = TransferRateEstimator()
    }

    /// Re-reads every running download, publishes the list, and keeps the
    /// timer on exactly while something is running.
    private func refreshProgress() {
        let now = Date()
        for (entry, var download) in running {
            let url = folder.appendingPathComponent(entry)
            switch download.kind {
            case .safari:
                let info = (try? Data(contentsOf: url.appendingPathComponent("Info.plist")))
                    .flatMap(SafariDownloadProgress.parse(data:))
                download.bytesSoFar = info?.bytesSoFar
                download.totalBytes = info?.totalBytes
            case .chromium, .firefox:
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
                download.bytesSoFar = size?.int64Value
                download.totalBytes = nil
            }
            if let bytes = download.bytesSoFar {
                rates[entry, default: TransferRateEstimator()].record(bytes: bytes, at: now)
            }
            download.bytesPerSecond = rates[entry]?.bytesPerSecond
            running[entry] = download
        }
        emit(.running(running.values.sorted { $0.entry < $1.entry }))

        if running.isEmpty {
            progressTimer?.cancel()
            progressTimer = nil
        } else if progressTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            // 1 s matches what a person reads off a progress number; the
            // leeway lets the system coalesce the wake-ups.
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.refreshProgress() }
            progressTimer = timer
            timer.resume()
        }
    }

    private func emit(_ event: DownloadsWatcherEvent) {
        let onEvent = self.onEvent
        DispatchQueue.main.async { MainActor.assumeIsolated { onEvent(event) } }
    }

    static func quarantine(of url: URL) -> QuarantineRecord? {
        let name = "com.apple.quarantine"
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size > 0, size < 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(url.path, name, &buffer, size, 0, 0)
        guard read > 0 else { return nil }
        return QuarantineRecord.parse(data: Data(buffer.prefix(read)))
    }
}
