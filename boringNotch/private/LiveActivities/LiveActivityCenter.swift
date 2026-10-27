//
//  LiveActivityCenter.swift
//  boringNotch
//
//  F19 live activities: owns the four sources, follows their Settings
//  toggles, and publishes what the closed island and the "Şimdi" page show.
//

import AppKit
import Combine
import Defaults
import os

/// Where the downloads source stands, for Settings.
enum DownloadsAccessState: Equatable {
    /// The user has not pressed "Allow access" yet; ~/Downloads is untouched.
    case notRequested
    case watching
    /// macOS refused to open the folder.
    case denied
    /// Both download and AirDrop toggles are off.
    case off
}

@MainActor
final class LiveActivityCenter: ObservableObject {
    static let shared = LiveActivityCenter()

    /// Everything alive, in display order.
    @Published private(set) var panelItems: [LiveActivity] = []
    /// The subset the closed island shows; the first one is drawn.
    @Published private(set) var stripItems: [LiveActivity] = []
    @Published private(set) var downloadsAccess: DownloadsAccessState = .notRequested
    @Published private(set) var timeMachineConfigured = false

    private var items: [String: LiveActivity] = [:]
    private var downloads: DownloadsWatcher?
    private var power: PowerSourceMonitor?
    private var timeMachine: TimeMachineMonitor?
    private var observations: [AnyCancellable] = []
    private var expiryTask: Task<Void, Never>?
    private var wasCharging = false
    private let log = Logger(subsystem: "umbar", category: "LiveActivities")

    private init() {}

    /// Begins following the toggles. Call once at launch; idempotent. Nothing
    /// here touches ~/Downloads unless the user granted it earlier.
    func start() {
        guard observations.isEmpty else { return }
        let keys: [Defaults._AnyKey] = [
            .liveActivityChargingEnabled, .liveActivityDownloadsEnabled, .liveActivityAirDropEnabled,
            .liveActivityTimeMachineEnabled, .liveActivityDownloadsAccessRequested, .liveActivityDebugWatchPath,
        ]
        // Emits once at subscription, which applies the persisted state.
        observations.append(
            Defaults.publisher(keys: keys, options: [.initial])
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.reconfigure() } }
        )
    }

    /// Settings' "Allow access": the next reconfigure opens the folder, which
    /// is what makes macOS ask.
    func requestDownloadsAccess() {
        guard Defaults[.liveActivityDownloadsAccessRequested] else {
            // The Defaults observer sees the change and starts the watcher.
            Defaults[.liveActivityDownloadsAccessRequested] = true
            return
        }
        // A second press after a denial retries: macOS will not ask again,
        // but if access was granted meanwhile in System Settings the state
        // goes back to watching.
        restartDownloads(force: true)
    }

    /// Adds a finished file to the shelf (the alternative to dragging it).
    func addToShelf(_ url: URL) {
        guard let bookmark = try? Bookmark(url: url) else { return }
        ShelfStateViewModel.shared.add([ShelfItem(kind: .file(bookmark: bookmark.data))])
    }

    // MARK: - Sources

    private func reconfigure() {
        if Defaults[.liveActivityChargingEnabled] {
            if power == nil {
                let monitor = PowerSourceMonitor { [weak self] status in self?.chargingChanged(status) }
                power = monitor
                monitor.start()
            }
        } else {
            power?.stop()
            power = nil
            wasCharging = false
            remove(kind: .charging)
        }

        if Defaults[.liveActivityTimeMachineEnabled] {
            if timeMachine == nil {
                let monitor = TimeMachineMonitor { [weak self] date in self?.backupFinished(date) }
                timeMachine = monitor
                monitor.start()
            }
            timeMachineConfigured = timeMachine?.isConfigured ?? false
        } else {
            timeMachine?.stop()
            timeMachine = nil
            timeMachineConfigured = false
            remove(kind: .timeMachine)
        }

        restartDownloads()
    }

    /// What the downloads watcher was started with; a toggle change that
    /// leaves this unchanged (charging, Time Machine) must not restart it,
    /// because a restart re-baselines the folder and could miss an arrival.
    private struct DownloadsConfig: Equatable {
        var folder: URL?
        var downloads: Bool
        var airDrop: Bool
    }

    private var downloadsConfig: DownloadsConfig?
    private var downloadsGeneration = 0

    private func currentDownloadsConfig() -> DownloadsConfig {
        let wantsDownloads = Defaults[.liveActivityDownloadsEnabled]
        let wantsAirDrop = Defaults[.liveActivityAirDropEnabled]
        guard wantsDownloads || wantsAirDrop else {
            return DownloadsConfig(folder: nil, downloads: false, airDrop: false)
        }
        let debugPath = Defaults[.liveActivityDebugWatchPath]
        let folder: URL?
        if !debugPath.isEmpty {
            folder = URL(fileURLWithPath: (debugPath as NSString).expandingTildeInPath, isDirectory: true)
        } else if Defaults[.liveActivityDownloadsAccessRequested] {
            folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        } else {
            folder = nil
        }
        return DownloadsConfig(folder: folder, downloads: wantsDownloads, airDrop: wantsAirDrop)
    }

    private func restartDownloads(force: Bool = false) {
        let config = currentDownloadsConfig()
        guard force || config != downloadsConfig else { return }
        downloadsConfig = config

        downloads?.stop()
        downloads = nil
        downloadsGeneration &+= 1
        // The new watcher re-reports anything still running.
        remove { $0.kind == .download && $0.phase == .running }
        if !config.downloads { remove(kind: .download) }
        if !config.airDrop { remove(kind: .airDrop) }
        guard config.downloads || config.airDrop else {
            downloadsAccess = .off
            return
        }
        guard let folder = config.folder else {
            downloadsAccess = .notRequested
            return
        }

        downloadsAccess = .watching
        let showDownloads = config.downloads
        // A stopped watcher can still have events queued for main; the
        // generation (bumped above) drops them so a restart never
        // resurrects stale rows.
        let generation = downloadsGeneration
        let watcher = DownloadsWatcher(folder: folder, watchAirDrop: config.airDrop) { [weak self] event in
            guard let self, generation == self.downloadsGeneration else { return }
            self.handle(event, showDownloads: showDownloads)
        }
        downloads = watcher
        watcher.start()
    }

    private func handle(_ event: DownloadsWatcherEvent, showDownloads: Bool) {
        let now = Date()
        switch event {
        case .running(let list):
            guard showDownloads else { return }
            let live = Set(list.map { "download:\($0.entry)" })
            for (id, item) in items where item.kind == .download && item.phase == .running && !live.contains(id) {
                items[id] = nil
            }
            for d in list {
                let id = "download:\(d.entry)"
                items[id] = LiveActivity(
                    id: id, kind: .download, phase: .running,
                    title: d.finalName ?? "", fraction: d.fraction, bytesSoFar: d.bytesSoFar,
                    bytesPerSecond: d.bytesPerSecond, fileURL: nil,
                    startedAt: items[id]?.startedAt ?? d.startedAt)
            }
        case .finished(let url):
            guard showDownloads else { return }
            insertFinished(kind: .download, url: url, now: now)
        case .airDropReceived(let url):
            insertFinished(kind: .airDrop, url: url, now: now)
        case .accessDenied:
            downloadsAccess = .denied
            downloads?.stop()
            downloads = nil
        }
        publish()
    }

    private func insertFinished(kind: LiveActivityKind, url: URL, now: Date) {
        let id = "\(kind.rawValue)-done:\(url.lastPathComponent)"
        items[id] = LiveActivity(
            id: id, kind: kind, phase: .finished, title: url.lastPathComponent, fileURL: url,
            startedAt: now,
            stripUntil: now.addingTimeInterval(LiveActivityRanking.finishedLinger),
            expiresAt: now.addingTimeInterval(LiveActivityRanking.finishedPanelLinger))
    }

    private func chargingChanged(_ status: ChargingStatus?) {
        let now = Date()
        guard let status else {
            wasCharging = false
            remove(kind: .charging)
            return
        }
        let previous = items["charging"]
        items["charging"] = LiveActivity(
            id: "charging", kind: .charging, phase: .running, title: "",
            percent: status.percent, minutesRemaining: status.minutesToFull,
            startedAt: previous?.startedAt ?? now,
            // Under the notch only right after plugging in; the panel row stays.
            stripUntil: wasCharging
                ? (previous?.stripUntil ?? now)
                : now.addingTimeInterval(LiveActivityRanking.chargingStripLinger))
        wasCharging = true
        publish()
    }

    private func backupFinished(_ date: Date) {
        let now = Date()
        timeMachineConfigured = true
        items["timeMachine"] = LiveActivity(
            id: "timeMachine", kind: .timeMachine, phase: .finished, title: "",
            startedAt: now,
            stripUntil: now.addingTimeInterval(LiveActivityRanking.finishedLinger),
            expiresAt: now.addingTimeInterval(LiveActivityRanking.finishedPanelLinger))
        publish()
    }

    private func remove(kind: LiveActivityKind) {
        remove { $0.kind == kind }
    }

    private func remove(where shouldRemove: (LiveActivity) -> Bool) {
        let before = items.count
        items = items.filter { !shouldRemove($0.value) }
        if items.count != before { publish() }
    }

    // MARK: - Publishing

    private func publish() {
        let now = Date()
        let all = Array(items.values)
        // Drop what is gone for good so the dictionary does not grow.
        for item in all where item.expiresAt.map({ $0 <= now }) ?? false { items[item.id] = nil }
        let panel = LiveActivityRanking.panelItems(all, now: now)
        let strip = LiveActivityRanking.stripItems(all, now: now)
        if panel != panelItems { panelItems = panel }
        if strip != stripItems { stripItems = strip }
        scheduleExpiry(after: now)
    }

    /// One wake-up at the next disappearance instead of a ticking timer.
    private func scheduleExpiry(after now: Date) {
        expiryTask?.cancel()
        guard let next = LiveActivityRanking.nextExpiry(Array(items.values), after: now) else { return }
        let delay = next.timeIntervalSince(now)
        expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay + 0.05))
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }
}
