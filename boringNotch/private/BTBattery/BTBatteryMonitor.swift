//
//  BTBatteryMonitor.swift
//  boringNotch
//
//  F24: the system side of Bluetooth batteries. Listens for connects and
//  disconnects (IOKit matching on the HID battery service, IOBluetooth
//  connect/disconnect notifications once the Bluetooth permission exists),
//  reads levels (IORegistry, plus system_profiler for AirPods) and publishes
//  the rows the Araçlar page shows. A connect after launch also puts a
//  3 s glance on the closed island through LiveActivityCenter.
//
//  Cost: nothing polls while the panel is closed. Levels are re-read on a
//  connect or disconnect, when the Araçlar page appears, and every 60 s only
//  while that page is on screen with a device listed. system_profiler runs
//  only while an audio device is connected (see BTProfilerPolicy).
//
//  Threading: everything here runs on the main actor. The IOKit port is
//  scheduled on the main queue and IOBluetooth delivers its notifications
//  on the main run loop, so the callbacks are already on the main thread.
//

import AppKit
import Combine
import CoreBluetooth
import Defaults
import IOBluetooth
import IOKit
import os

@MainActor
final class BTBatteryMonitor: NSObject, ObservableObject {
    static let shared = BTBatteryMonitor()

    /// Connected devices with a battery level, in display order.
    @Published private(set) var devices: [BTBatteryDevice] = []

    private static let log = Logger(subsystem: "umbar", category: "BTBattery")
    private static let hidServiceClass = "AppleDeviceManagementHIDEventService"
    /// AirPods publish their levels a second or two after the link comes up,
    /// and a Magic device's BatteryPercent appears after its service does.
    private static let connectSettle: Duration = .milliseconds(2500)
    private static let pollInterval: Duration = .seconds(60)

    private var enabled = false
    private var observation: AnyCancellable?
    private var notifyPort: IONotificationPortRef?
    private var hidIterators: [io_iterator_t] = []
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]

    private var glance = BTConnectGlancePolicy(startedAt: Date())
    /// Ids that connected and still owe a glance once their levels are read.
    private var pendingGlances: [String: String] = [:]
    private var knownHIDIDs: Set<String> = []
    private var hidBaselineTaken = false

    private var lastProfilerRun: Date?
    private var profilerCache: [String: QuickBattery] = [:]
    private var refreshTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var visibleCount = 0

    /// Starts following the setting. Call once at launch; idempotent.
    func start() {
        guard observation == nil else { return }
        observation = Defaults.publisher(.btBatteryEnabled, options: [.initial])
            .map(\.newValue)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in MainActor.assumeIsolated { self?.apply(enabled: on) } }
    }

    /// Whether a connected audio device's level can show up in `devices`:
    /// the setting is on and AirPods levels are readable (they need the
    /// Bluetooth permission). HeadphoneConnectMonitor waits briefly for a
    /// level only when one can come.
    var canReadAudioBatteries: Bool { enabled && Self.bluetoothPermitted }

    /// The Araçlar line calls this from onAppear / onDisappear. Counted, so
    /// two lines on screen (renderer, previews) do not stop each other.
    func setVisible(_ visible: Bool) {
        visibleCount = max(0, visibleCount + (visible ? 1 : -1))
        guard enabled else { return }
        if visibleCount > 0 {
            // A permission granted from the toggles row since launch.
            registerBluetoothIfPermitted()
            scheduleRefresh(after: .zero, forceProfiler: false)
            startPolling()
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    // MARK: Lifecycle

    private func apply(enabled on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            glance = BTConnectGlancePolicy(startedAt: Date())
            hidBaselineTaken = false
            registerHID()
            registerBluetoothIfPermitted()
            scheduleRefresh(after: .zero, forceProfiler: false)
            if visibleCount > 0 { startPolling() }
        } else {
            tearDown()
            devices = []
        }
    }

    private func tearDown() {
        refreshTask?.cancel()
        pollTask?.cancel()
        refreshTask = nil
        pollTask = nil
        for iterator in hidIterators { IOObjectRelease(iterator) }
        hidIterators = []
        if let port = notifyPort { IONotificationPortDestroy(port) }
        notifyPort = nil
        connectNotification?.unregister()
        connectNotification = nil
        for note in disconnectNotifications.values { note.unregister() }
        disconnectNotifications = [:]
        pendingGlances = [:]
        knownHIDIDs = []
        profilerCache = [:]
        lastProfilerRun = nil
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                // Nothing listed means nothing to keep fresh; a connect
                // notification brings the list back.
                if !self.devices.isEmpty { self.scheduleRefresh(after: .zero, forceProfiler: false) }
            }
        }
    }

    // MARK: Notifications

    /// IOKit first-match / terminated notifications on the HID battery
    /// service. These need no Bluetooth permission.
    private func registerHID() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            BTBatteryMonitor.drain(iterator)
            guard let refcon else { return }
            let monitor = Unmanaged<BTBatteryMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.hidServicesChanged() }
        }
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            let status = IOServiceAddMatchingNotification(
                port, type, IOServiceMatching(Self.hidServiceClass), callback, context, &iterator)
            guard status == KERN_SUCCESS else {
                Self.log.error("IOServiceAddMatchingNotification failed: \(status)")
                continue
            }
            // Arms the notification; the services already there are the
            // baseline that `refresh` records without a glance.
            Self.drain(iterator)
            hidIterators.append(iterator)
        }
    }

    nonisolated private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    private func hidServicesChanged() {
        guard enabled else { return }
        scheduleRefresh(after: Self.connectSettle, forceProfiler: false)
    }

    /// IOBluetooth is only touched once the permission is granted: before
    /// that, the first IOBluetooth call would show the prompt with no
    /// context (QuickTogglesBackend asks for it from a tap instead).
    private func registerBluetoothIfPermitted() {
        guard connectNotification == nil, Self.bluetoothPermitted else { return }
        // Registration reports the devices already connected as connects;
        // restart the baseline window so a permission granted mid-session
        // does not announce AirPods that were in the user's ears all along.
        glance = BTConnectGlancePolicy(startedAt: Date())
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        // Not every macOS release replays existing connections; register
        // their disconnects directly so the row still goes when they leave.
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        for device in paired where device.isConnected() {
            guard let address = device.addressString else { continue }
            let id = QuickBluetoothAddress.normalize(address)
            guard disconnectNotifications[id] == nil else { continue }
            disconnectNotifications[id] = device.register(
                forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        }
    }

    private static var bluetoothPermitted: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil
            && CBCentralManager.authorization == .allowedAlways
    }

    /// Also called once per device already connected at registration;
    /// BTConnectGlancePolicy's baseline window keeps those silent.
    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard enabled, let address = device.addressString else { return }
        let id = QuickBluetoothAddress.normalize(address)
        disconnectNotifications[id]?.unregister()
        disconnectNotifications[id] = device.register(
            forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        // Headphones get HeadphoneConnectMonitor's wider glance instead of
        // this strip while that setting is on; one connect, one notice.
        let headphoneGlanceOwnsIt = device.deviceClassMajor == kBluetoothDeviceClassMajorAudio
            && Defaults[.headphoneGlanceEnabled]
        if !headphoneGlanceOwnsIt, glance.shouldAnnounce(id, at: Date()) {
            pendingGlances[id] = device.name ?? address
        }
        scheduleRefresh(after: Self.connectSettle, forceProfiler: true)
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        let id = QuickBluetoothAddress.normalize(address)
        disconnectNotifications.removeValue(forKey: id)?.unregister()
        pendingGlances[id] = nil
        guard enabled else { return }
        // Drop the row now; the refresh confirms it.
        devices.removeAll { $0.id == id }
        scheduleRefresh(after: .milliseconds(300), forceProfiler: false)
    }

    // MARK: Reading

    /// Coalesces bursts (a Magic Keyboard matches several services at once,
    /// AirPods connect then add a second link): the last request wins, and
    /// a forced profiler read is never lost to a later unforced one.
    private var pendingForce = false
    private func scheduleRefresh(after delay: Duration, forceProfiler: Bool) {
        pendingForce = pendingForce || forceProfiler
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            let force = self.pendingForce
            self.pendingForce = false
            await self.refresh(forceProfiler: force)
        }
    }

    private func refresh(forceProfiler: Bool) async {
        guard enabled else { return }
        let hid = Self.readHIDBatteries()
        let connected = Self.connectedDevices()

        let now = Date()
        let hasAudio = connected.contains(where: \.isAudio)
        if BTProfilerPolicy.shouldRun(hasConnectedAudio: hasAudio, lastRun: lastProfilerRun, now: now, forced: forceProfiler) {
            lastProfilerRun = now
            // Cancellation (a newer refresh) stops system_profiler too, so
            // the result is only kept when this refresh is still current;
            // a stopped run would otherwise blank every battery.
            let fresh = await Self.readProfiler()
            guard !Task.isCancelled, enabled else { return }
            profilerCache = fresh
        } else if forceProfiler,
                  let delay = BTProfilerPolicy.forcedRetryDelay(hasConnectedAudio: hasAudio, lastRun: lastProfilerRun, now: now) {
            scheduleRefresh(after: .milliseconds(Int(delay * 1000) + 50), forceProfiler: true)
        }

        devices = BTBatteryMerge.merge(connected: connected, profiler: profilerCache, hid: hid)
        announceNewHID(hid, now: now)
        flushGlances(now: Date())
    }

    /// HID devices connect without an IOBluetooth notification when the
    /// Bluetooth permission is missing; a new id in IORegistry is then the
    /// only sign. The first read after start is the baseline.
    private func announceNewHID(_ hid: [BTHIDBattery], now: Date) {
        let ids = Set(hid.map(\.id))
        if hidBaselineTaken {
            for entry in hid where !knownHIDIDs.contains(entry.id) && pendingGlances[entry.id] == nil {
                if glance.shouldAnnounce(entry.id, at: now) { pendingGlances[entry.id] = entry.name }
            }
        }
        hidBaselineTaken = true
        knownHIDIDs = ids
    }

    private func flushGlances(now: Date) {
        for (id, name) in pendingGlances {
            let row = devices.first { $0.id == id }
            LiveActivityCenter.shared.flash(
                .bluetoothConnected(id: id, name: row?.name ?? name, battery: row?.battery, now: now))
        }
        pendingGlances = [:]
    }

    /// IORegistry HID levels. Cheap (a handful of registry entries), needs
    /// no permission; also used by the quick toggles device strip.
    static func readHIDBatteries() -> [BTHIDBattery] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(hidServiceClass), &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var entries: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                entries.append(dict)
            }
            IOObjectRelease(service)
        }
        return BTHIDBatteryParser.parse(entries)
    }

    private static func connectedDevices() -> [BTConnectedDevice] {
        guard bluetoothPermitted else { return [] }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return paired.compactMap { device in
            guard device.isConnected(), let address = device.addressString else { return nil }
            return BTConnectedDevice(
                id: QuickBluetoothAddress.normalize(address),
                name: device.name ?? address,
                isAudio: device.deviceClassMajor == kBluetoothDeviceClassMajorAudio)
        }
    }

    private static func readProfiler() async -> [String: QuickBattery] {
        let output = try? await QuickToggleProcess.run(
            "/usr/sbin/system_profiler", ["-json", "-detailLevel", "basic", "SPBluetoothDataType"],
            timeout: .seconds(5))
        return output.map(QuickBatteryParser.parse) ?? [:]
    }
}
