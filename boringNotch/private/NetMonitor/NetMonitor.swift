//
//  NetMonitor.swift
//  boringNotch
//
//  F17 network traffic: follows the primary network interface, samples its
//  byte counters, and keeps the per-network totals.
//
//  Cadence. 1 s while something on screen shows the numbers (the Şimdi
//  column or the closed-notch ear call `beginObserving`), 5 s otherwise.
//  The background cadence only exists for the totals: the counters are
//  cumulative, so totals are exact at any cadence; 5 s bounds how much
//  traffic can be credited to the wrong network or day around a switch.
//  Each sample is one sysctl; the 1 s cost that matters is the redraw.
//
//  Threading. Everything is main-actor. NWPathMonitor runs on its own queue
//  and hands a Sendable summary over; the ledger write is a value copy
//  written on a utility queue.
//

import AppKit
import Combine
import Defaults
import Network
import os

@MainActor
final class NetMonitor: ObservableObject {
    static let shared = NetMonitor()

    /// The interface being measured and what the UI calls it.
    struct CurrentNetwork: Equatable {
        var interfaceName: String
        var kind: NetLinkKind
        /// The Wi-Fi name when the user opted in; otherwise nil and the UI
        /// says "This network (Wi-Fi)".
        var wifiName: String?
    }

    // MARK: Published state

    @Published private(set) var isActive = false
    @Published private(set) var network: CurrentNetwork?
    /// Smoothed bytes per second.
    @Published private(set) var rxRate: Double = 0
    @Published private(set) var txRate: Double = 0
    @Published private(set) var history = NetRateHistory()
    /// Since this network became the current one (or since launch).
    @Published private(set) var session = NetByteTotals()
    @Published private(set) var today = NetByteTotals()
    @Published private(set) var month = NetByteTotals()

    // MARK: Private state

    private struct Link: Equatable, Sendable {
        var name: String
        var index: Int32
        var kind: NetLinkKind
    }

    /// Who the counted bytes belong to.
    private enum Owner {
        /// Waiting for configd's network signature. Bytes are held here and
        /// credited once the key is known, so a network never gets a
        /// provisional key that later splits its history.
        case pending(since: TimeInterval, held: NetByteTotals, day: String)
        case resolved(NetNetworkKey)
    }

    private let visibleInterval: TimeInterval = 1
    private let backgroundInterval: TimeInterval = 5
    /// The signature normally appears within a second of joining; after this
    /// long without one the network is keyed by its router IP instead.
    private let signatureWait: TimeInterval = 20
    /// How often the ledger is written while traffic flows. A crash loses at
    /// most this much of the totals; a quit loses nothing (flushed on
    /// terminate).
    private let saveInterval: TimeInterval = 60

    private var link: Link?
    private var owner: Owner?
    private var lastSnapshot: NetCounterSnapshot?
    private var smoother = NetRateSmoother()
    private var ledger = NetUsageLedger()
    private var ledgerLoaded = false
    private var dirty = false
    private var lastSave: TimeInterval = 0
    private var lastPruneDay = ""
    private var observerCount = 0
    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var cancellables = Set<AnyCancellable>()
    private var terminateObserver: NSObjectProtocol?

    private let file = NetUsageFile(url: NetUsageFile.defaultURL())
    private let saveQueue = DispatchQueue(label: "umbar.NetMonitor.save", qos: .utility)
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "umbar", category: "NetMonitor")

    private init() {}

    // MARK: Lifecycle

    /// Call once at launch. With the feature off there is no timer and no
    /// path monitor, only the Defaults subscription (AC-1.13 / C1).
    func start() {
        guard cancellables.isEmpty else { return }
        Defaults.publisher(.netMonitorEnabled)
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated { enabled ? self?.activate() : self?.deactivate() }
            }
            .store(in: &cancellables)
        Defaults.publisher(.netMonitorShowWiFiName)
            .map(\.newValue)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.relabel() }
            }
            .store(in: &cancellables)
        NetLocationAccess.shared.onChange = { [weak self] in self?.relabel() }
        if Defaults[.netMonitorShowWiFiName] { NetLocationAccess.shared.refresh() }
    }

    /// A view that displays live numbers appeared. Balanced by
    /// `endObserving`; the 1 s cadence runs while the count is above zero.
    func beginObserving() {
        observerCount += 1
        if observerCount == 1, isActive {
            sample()
            scheduleTimer()
        }
    }

    func endObserving() {
        observerCount = max(0, observerCount - 1)
        if observerCount == 0, isActive { scheduleTimer() }
    }

    /// Forgets the current network's history and restarts its session.
    func resetCurrentNetwork() {
        if case .resolved(let key) = owner { ledger.reset(key) }
        if case .pending(let since, _, let day) = owner { owner = .pending(since: since, held: NetByteTotals(), day: day) }
        session = NetByteTotals()
        dirty = true
        saveNow()
        refreshTotals()
    }

    /// Deletes every stored total (Settings).
    func resetAll() {
        ledger.removeAll()
        if case .pending(let since, _, let day) = owner { owner = .pending(since: since, held: NetByteTotals(), day: day) }
        session = NetByteTotals()
        dirty = true
        saveNow()
        refreshTotals()
    }

    private func activate() {
        guard !isActive else { return }
        if !ledgerLoaded {
            ledger = file.load()
            ledgerLoaded = true
        }
        prune(force: true)
        isActive = true

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let chosen = Self.primaryLink(of: path)
            Task { @MainActor in self?.pathChanged(to: chosen) }
        }
        monitor.start(queue: DispatchQueue(label: "umbar.NetMonitor.path", qos: .utility))
        pathMonitor = monitor

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSynchronously() }
        }
        scheduleTimer()
        log.info("activated")
    }

    private func deactivate() {
        guard isActive else { return }
        sample()
        flushSynchronously()
        pathMonitor?.cancel()
        pathMonitor = nil
        timer?.invalidate()
        timer = nil
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
        link = nil
        owner = nil
        lastSnapshot = nil
        smoother.reset()
        history.removeAll()
        isActive = false
        network = nil
        rxRate = 0
        txRate = 0
        log.info("deactivated")
    }

    // MARK: Path

    /// The interface the traffic actually leaves on. `availableInterfaces`
    /// is in preference order; with a VPN up the first entry is the tunnel
    /// (`utun`, type `.other`), whose bytes are also counted, encapsulated,
    /// on the physical link. The physical link is what "this network"
    /// means, so it wins.
    nonisolated private static func primaryLink(of path: NWPath) -> Link? {
        guard path.status == .satisfied else { return nil }
        let interfaces = path.availableInterfaces.filter { $0.type != .loopback }
        let physical = interfaces.first { [.wifi, .wiredEthernet, .cellular].contains($0.type) }
        guard let chosen = physical ?? interfaces.first else { return nil }
        let kind: NetLinkKind
        switch chosen.type {
        case .wifi: kind = .wifi
        case .wiredEthernet: kind = .ethernet
        case .cellular: kind = .cellular
        default: kind = .other
        }
        return Link(name: chosen.name, index: Int32(chosen.index), kind: kind)
    }

    private func pathChanged(to newLink: Link?) {
        guard isActive else { return }
        // Credit what the old link carried up to now to the old owner
        // before anything changes.
        sample()
        if newLink != link {
            // Bytes held for a signature that never came belong to the old
            // link's network, not to whatever comes next.
            if let oldLink = link { tryResolve(on: oldLink, now: ProcessInfo.processInfo.systemUptime, force: true) }
            lastSnapshot = nil
            smoother.reset()
            rxRate = 0
            txRate = 0
            link = newLink
        }
        guard let newLink else {
            owner = nil
            network = nil
            refreshTotals()
            return
        }
        // Re-resolve even on the same interface: joining another Wi-Fi
        // network keeps en0 and changes everything else.
        if case .pending = owner {} else {
            owner = .pending(since: ProcessInfo.processInfo.systemUptime, held: NetByteTotals(), day: NetDayKey.key(for: Date()))
        }
        if network?.interfaceName != newLink.name {
            network = CurrentNetwork(interfaceName: newLink.name, kind: newLink.kind, wifiName: nil)
        }
        if lastSnapshot == nil {
            lastSnapshot = NetSystemProbe.counters(interfaceIndex: newLink.index)
        }
        tryResolve(on: newLink, now: ProcessInfo.processInfo.systemUptime, force: false)
        refreshTotals()
    }

    /// Looks for the network signature; called on a path change and on each
    /// tick while pending. `force` settles on the best fallback at once
    /// instead of waiting for the signature.
    private func tryResolve(on link: Link, now: TimeInterval, force: Bool) {
        guard case .pending(let since, let held, let day) = owner else { return }
        let info = NetSystemProbe.serviceInfo(interfaceName: link.name)
        let basis: NetNetworkKey.Basis
        if let signature = info?.signature {
            basis = .systemSignature(signature)
        } else if !force, now - since < signatureWait {
            return
        } else if let router = info?.router {
            basis = .routerIP(router, interface: link.name)
        } else {
            basis = .interfaceOnly(link.name)
        }
        let key = NetNetworkKey.make(basis, kind: link.kind)
        // A path flap back onto the same network (sleep/wake, DHCP renew)
        // keeps the session running; a different network starts a new one
        // with the bytes counted while it was being identified.
        if key != lastResolvedKey { session = held }
        lastResolvedKey = key
        ledger.credit(key, kind: link.kind, day: day, rx: held.rx, tx: held.tx)
        owner = .resolved(key)
        dirty = true
        let wifiName = link.kind == .wifi ? NetWiFiName.current(interfaceName: link.name) : nil
        ledger.setLabel(wifiName, for: key, kind: link.kind)
        network = CurrentNetwork(interfaceName: link.name, kind: link.kind, wifiName: wifiName)
        log.info("network resolved on \(link.name, privacy: .public) via \(Self.describe(basis), privacy: .public)")
        refreshTotals()
    }

    private var lastResolvedKey: NetNetworkKey?

    private var heldBytes: NetByteTotals {
        if case .pending(_, let held, _) = owner { return held }
        return NetByteTotals()
    }

    private func relabel() {
        if Defaults[.netMonitorShowWiFiName] { NetLocationAccess.shared.refresh() }
        guard let link, case .resolved(let key) = owner else { return }
        let wifiName = link.kind == .wifi ? NetWiFiName.current(interfaceName: link.name) : nil
        ledger.setLabel(wifiName, for: key, kind: link.kind)
        network?.wifiName = wifiName
    }

    private static func describe(_ basis: NetNetworkKey.Basis) -> String {
        switch basis {
        case .systemSignature: return "system signature"
        case .routerIP: return "router address"
        case .interfaceOnly: return "interface only"
        }
    }

    // MARK: Sampling

    private func scheduleTimer() {
        timer?.invalidate()
        let interval = observerCount > 0 ? visibleInterval : backgroundInterval
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Generous tolerance in the background lets the system coalesce the
        // wake-up with others; on screen 10% keeps the graph even.
        newTimer.tolerance = observerCount > 0 ? 0.1 : 1
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        if let link, case .pending = owner { tryResolve(on: link, now: now, force: false) }
        sample()
        prune(force: false)
        if dirty, now - lastSave >= saveInterval { saveNow() }
    }

    private func sample() {
        guard isActive, let link else { return }
        guard let snapshot = NetSystemProbe.counters(interfaceIndex: link.index) else {
            // The interface vanished before the path monitor said so.
            lastSnapshot = nil
            return
        }
        defer { lastSnapshot = snapshot }
        guard let previous = lastSnapshot,
              let delta = NetCounterMath.delta(from: previous, to: snapshot)
        else { return }

        smoother.add(delta)
        rxRate = smoother.rx
        txRate = smoother.tx
        history.append(NetRatePoint(time: snapshot.time, rx: delta.rxRate, tx: delta.txRate))
        credit(delta, kind: link.kind)
        log.debug("sample if=\(link.name, privacy: .public) dt=\(delta.interval, format: .fixed(precision: 3), privacy: .public) rx=\(delta.rx, privacy: .public) tx=\(delta.tx, privacy: .public) rxRate=\(self.rxRate, format: .fixed(precision: 0), privacy: .public) txRate=\(self.txRate, format: .fixed(precision: 0), privacy: .public) sessionRx=\(self.session.rx, privacy: .public) sessionTx=\(self.session.tx, privacy: .public)")
    }

    private func credit(_ delta: NetTrafficDelta, kind: NetLinkKind) {
        guard delta.rx > 0 || delta.tx > 0 else { return }
        session.add(rx: delta.rx, tx: delta.tx)
        switch owner {
        case .resolved(let key):
            ledger.credit(key, kind: kind, day: NetDayKey.key(for: Date()), rx: delta.rx, tx: delta.tx)
            dirty = true
        case .pending(let since, var held, let day):
            held.add(rx: delta.rx, tx: delta.tx)
            owner = .pending(since: since, held: held, day: day)
        case nil:
            break
        }
        refreshTotals()
    }

    private func refreshTotals() {
        guard case .resolved(let key) = owner else {
            today = heldBytes
            month = heldBytes
            return
        }
        let now = Date()
        today = ledger.today(key, now: now)
        month = ledger.month(key, now: now)
    }

    // MARK: Persistence

    private func prune(force: Bool) {
        let day = NetDayKey.key(for: Date())
        guard force || day != lastPruneDay else { return }
        lastPruneDay = day
        let before = ledger
        ledger.prune(now: Date())
        if ledger != before { dirty = true }
        refreshTotals()
    }

    private func saveNow() {
        guard dirty else { return }
        dirty = false
        lastSave = ProcessInfo.processInfo.systemUptime
        let snapshot = ledger
        let file = self.file
        let log = self.log
        saveQueue.async {
            do { try file.save(snapshot) } catch {
                log.error("could not save traffic totals: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Quit or switch-off: settle any bytes still waiting for a signature,
    /// then write and wait for the write to land.
    private func flushSynchronously() {
        if let link { tryResolve(on: link, now: ProcessInfo.processInfo.systemUptime, force: true) }
        saveNow()
        saveQueue.sync {}
    }
}
