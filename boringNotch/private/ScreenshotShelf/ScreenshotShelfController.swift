//
//  ScreenshotShelfController.swift
//  umbar
//
//  F16: app-side owner of the screenshot watcher. Follows the Defaults
//  switches and the system screenshot location, and puts new captures on
//  the shelf as ordinary file items (a bookmark to the original; the file
//  stays where macOS saved it).
//

import AppKit
import Combine
import Defaults
import Foundation
import os

@MainActor
final class ScreenshotShelfController: ObservableObject {
    static let shared = ScreenshotShelfController()

    enum State: Equatable {
        case off
        case watching(URL)
        /// macOS denied access to the folder. Not retried automatically.
        case accessDenied(URL)
        case missing(URL)
    }

    @Published private(set) var state: State = .off

    /// Called after a capture reached the shelf, so the app can flash the
    /// notch. Set once at launch.
    private var onArrival: (() -> Void)?
    private var watcher: ScreenshotFolderWatcher?
    private var observations = Set<AnyCancellable>()
    private var locationTimer: Timer?
    private var started = false
    private let log = Logger(subsystem: "umbar", category: "ScreenshotShelf")

    private init() {}

    /// Begins following the settings. Call once at launch; idempotent.
    func start(onArrival: @escaping () -> Void) {
        guard !started else { return }
        started = true
        self.onArrival = onArrival
        Publishers.Merge3(
            Defaults.publisher(.screenshotShelfEnabled).map { _ in () },
            Defaults.publisher(.screenshotShelfIncludeRecordings).map { _ in () },
            Defaults.publisher(.screenshotShelfWatchPath).map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in MainActor.assumeIsolated { self?.reconfigure() } }
        .store(in: &observations)

        // The user can change the location (⌘⇧5 > Options) while umbar runs;
        // com.apple.screencapture has no change notification, so re-read it
        // now and then. A re-read that yields the same folder is a no-op.
        locationTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.locationMayHaveChanged() }
        }
    }

    /// The "Try again" button in Settings, after the user granted access.
    func retry() {
        stopWatcher()
        reconfigure()
    }

    /// The folder currently in effect, whether or not it can be read.
    var effectiveDirectory: URL {
        let override = Defaults[.screenshotShelfWatchPath]
        let configured = override.isEmpty
            ? UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            : override
        return ScreenshotShelfPolicy.resolveLocation(configured: configured, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    private func locationMayHaveChanged() {
        guard case .watching(let current) = state, current != effectiveDirectory else { return }
        reconfigure()
    }

    private func reconfigure() {
        stopWatcher()
        guard Defaults[.screenshotShelfEnabled] else {
            state = .off
            return
        }
        let dir = effectiveDirectory
        let watcher = ScreenshotFolderWatcher(directory: dir, includeRecordings: Defaults[.screenshotShelfIncludeRecordings])
        watcher.onNewFile = { [weak self] url in
            Task { @MainActor in self?.arrived(url) }
        }
        watcher.onFailure = { [weak self] failure in
            Task { @MainActor in
                guard let self, self.watcher === watcher else { return }
                self.state = failure == .accessDenied ? .accessDenied(dir) : .missing(dir)
            }
        }
        self.watcher = watcher
        state = .watching(dir)
        watcher.start()
    }

    private func stopWatcher() {
        watcher?.stop()
        watcher = nil
    }

    private func arrived(_ url: URL) {
        guard Defaults[.boringShelf] else { return }
        // The same file can be reported again after a restart or a rename;
        // ShelfStateViewModel.add de-duplicates on identity.
        guard let bookmark = try? Bookmark(url: url) else {
            log.error("could not bookmark a new capture")
            return
        }
        ShelfStateViewModel.shared.add([ShelfItem(kind: .file(bookmark: bookmark.data), isTemporary: false)])
        onArrival?()
    }
}
