//
//  ScreenshotFolderWatcher.swift
//  umbar
//
//  F16: watches one folder for newly finished screenshot files.
//

import Foundation
import os

/// Watches a directory with a DispatchSource and reports files that appear
/// after the watch began and look like finished screenshots.
///
/// Why a directory vnode source and not FSEvents: we watch a single flat
/// folder, and a vnode source needs no stream setup. The rename from
/// ".Screenshot ...png" to "Screenshot ...png" is a write to the directory,
/// so it fires the same event as a plain create.
///
/// All state lives on `queue`; callbacks are delivered on it too.
final class ScreenshotFolderWatcher: @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// macOS refused access (Files & Folders privacy). We do not retry on
        /// our own: every attempt would raise the system prompt again.
        case accessDenied
        case missing
    }

    let directory: URL
    var includeRecordings: Bool

    /// Called on `queue` with each finished screenshot.
    var onNewFile: (@Sendable (URL) -> Void)?
    /// Called on `queue` at most once, when the folder cannot be read.
    var onFailure: (@Sendable (Failure) -> Void)?

    let queue = DispatchQueue(label: "umbar.screenshotshelf.watcher")
    private var source: DispatchSourceFileSystemObject?
    private var pollTimer: DispatchSourceTimer?
    private var known = Set<String>()
    private var pending = Set<String>()
    private var tracker = ScreenshotStabilityTracker()
    private let log = Logger(subsystem: "umbar", category: "ScreenshotShelf")

    init(directory: URL, includeRecordings: Bool) {
        self.directory = directory
        self.includeRecordings = includeRecordings
    }

    func start() {
        queue.async { [self] in
            // Reading the listing is what triggers the TCC check, so do it
            // before opening the descriptor and fail cleanly on denial.
            switch listing() {
            case .failure(let failure):
                onFailure?(failure)
                return
            case .success(let names):
                known = Set(names)
            }
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else {
                onFailure?(errno == EPERM || errno == EACCES ? .accessDenied : .missing)
                return
            }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
            src.setEventHandler { [weak self] in self?.directoryChanged() }
            src.setCancelHandler { close(fd) }
            source = src
            src.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            source?.cancel()
            source = nil
            pollTimer?.cancel()
            pollTimer = nil
            pending.removeAll()
        }
    }

    private func listing() -> Result<[String], Failure> {
        do {
            return .success(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        } catch let error as NSError {
            let denied = error.code == NSFileReadNoPermissionError
                || (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code == Int(EPERM)
            return .failure(denied ? .accessDenied : .missing)
        }
    }

    private func directoryChanged() {
        guard case .success(let names) = listing() else {
            // Folder deleted or revoked mid-watch: report once, stop quietly.
            source?.cancel()
            source = nil
            onFailure?(.missing)
            return
        }
        for name in names where !known.contains(name) {
            known.insert(name)
            // Hidden temp names are remembered as known; their final name is
            // a different entry and shows up as new.
            if ScreenshotShelfPolicy.isTemporaryName(name) { continue }
            pending.insert(name)
        }
        if !pending.isEmpty { startPolling() }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.4, repeating: 0.4)
        timer.setEventHandler { [weak self] in self?.pollPending() }
        pollTimer = timer
        timer.resume()
    }

    private func pollPending() {
        for name in pending {
            let url = directory.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let snapshot = values.flatMap { v in
                v.fileSize.flatMap { size in
                    v.contentModificationDate.map { ScreenshotStabilityTracker.Snapshot(size: Int64(size), modified: $0) }
                }
            }
            switch tracker.observe(name, snapshot: snapshot) {
            case .pending:
                continue
            case .giveUp:
                pending.remove(name)
            case .stable:
                pending.remove(name)
                let verdict = ScreenshotShelfPolicy.classify(
                    name: name,
                    hasCaptureAttribute: Self.hasCaptureAttribute(url),
                    includeRecordings: includeRecordings
                )
                if verdict == .accept { onNewFile?(url) }
            }
        }
        if pending.isEmpty {
            pollTimer?.cancel()
            pollTimer = nil
        }
    }

    /// `true` when the capture xattr is present, `nil` when it is not.
    static func hasCaptureAttribute(_ url: URL) -> Bool? {
        let size = getxattr(url.path, ScreenshotShelfPolicy.captureAttributeName, nil, 0, 0, XATTR_NOFOLLOW)
        return size >= 0 ? true : nil
    }
}
