//
//  HeadphoneConnectMonitor.swift
//  boringNotch
//
//  The system side of the headphone connect glance: follows Core Audio's
//  device list for Bluetooth outputs appearing and disappearing, keeps the
//  Mac's sleep state for HeadphoneGlancePolicy, and publishes the glance the
//  closed island draws (HeadphoneGlanceOverlay).
//
//  Permissions: none. Core Audio's device list and device properties are
//  readable without the Bluetooth (TCC) or microphone permission. Battery
//  levels come from BTBatteryMonitor, which reads AirPods levels only once
//  the user granted Bluetooth from the quick toggles; without it the glance
//  shows "Connected" instead of a level.
//
//  Threading: main actor. The property listener is registered on the main
//  queue, so its block already runs on the main thread.
//

import AppKit
import Combine
import CoreAudio
import Defaults
import os

@MainActor
final class HeadphoneConnectMonitor: ObservableObject {
    static let shared = HeadphoneConnectMonitor()

    /// The glance on screen, or nil.
    @Published private(set) var glance: HeadphoneGlance?

    private static let log = Logger(subsystem: "umbar", category: "HeadphoneConnect")
    /// How long a connect waits for BTBatteryMonitor's level before it is
    /// shown without one. Short on purpose: the glance should feel like a
    /// reaction to the connect; a level that arrives later fades in.
    private static let batteryWait: Duration = .milliseconds(1500)

    private var enabledObservation: AnyCancellable?
    private var batteryObservation: AnyCancellable?
    private var listener: AudioObjectPropertyListenerBlock?
    private var sleepObservers: [NSObjectProtocol] = []
    private var policy = HeadphoneGlancePolicy(baseline: [], startedAt: Date())
    private var nextGlanceID = 0
    private var pendingConnect: (output: HeadphoneOutput, task: Task<Void, Never>)?
    private var dismissTask: Task<Void, Never>?

    private static var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private init() {}

    /// Starts following the setting. Call once at launch; idempotent.
    func start() {
        guard enabledObservation == nil else { return }
        enabledObservation = Defaults.publisher(.headphoneGlanceEnabled, options: [.initial])
            .map(\.newValue)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in MainActor.assumeIsolated { self?.apply(enabled: on) } }
    }

    #if DEBUG
    /// The frame renderer's glance; nothing is listening in a render run.
    func showFixture(_ fixture: HeadphoneGlance?) {
        glance = fixture
    }
    #endif

    // MARK: Lifecycle

    private func apply(enabled on: Bool) {
        if on {
            guard listener == nil else { return }
            // What is connected now is the baseline: turning the setting on
            // (or launching) with AirPods in must not announce them.
            policy = HeadphoneGlancePolicy(baseline: Self.readOutputs(), startedAt: Date())
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.devicesChanged() }
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &Self.devicesAddress, .main, block)
            guard status == noErr else {
                Self.log.error("AudioObjectAddPropertyListenerBlock failed: \(status)")
                return
            }
            listener = block
            observeSleep()
            observeBatteries()
        } else {
            if let block = listener {
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &Self.devicesAddress, .main, block)
            }
            listener = nil
            for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            sleepObservers = []
            batteryObservation = nil
            pendingConnect?.task.cancel()
            pendingConnect = nil
            dismissTask?.cancel()
            dismissTask = nil
            glance = nil
        }
    }

    private func observeSleep() {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.policy.noteSleep(at: Date()) }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.policy.noteWake(at: Date()) }
            },
        ]
    }

    /// A level that arrives after the connect: completes a waiting connect
    /// early, or fills in the glance already on screen.
    private func observeBatteries() {
        batteryObservation = BTBatteryMonitor.shared.$devices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                MainActor.assumeIsolated { self?.batteriesChanged(devices) }
            }
    }

    private func batteriesChanged(_ devices: [BTBatteryDevice]) {
        if let pending = pendingConnect, let battery = Self.battery(for: pending.output.id, in: devices) {
            pending.task.cancel()
            pendingConnect = nil
            present(.connected, pending.output, battery: battery)
            return
        }
        guard var current = glance, current.phase == .connected,
              let battery = Self.battery(for: current.output.id, in: devices),
              battery != current.battery
        else { return }
        current.battery = battery
        glance = current
    }

    // MARK: Events

    private func devicesChanged() {
        let events = policy.update(Self.readOutputs(), at: Date())
        guard let event = HeadphoneGlancePolicy.headline(events) else { return }
        switch event {
        case .connected(let output):
            connect(output)
        case .disconnected(let output):
            if pendingConnect?.output.id == output.id {
                pendingConnect?.task.cancel()
                pendingConnect = nil
            }
            present(.disconnected, output, battery: nil)
        }
    }

    private func connect(_ output: HeadphoneOutput) {
        pendingConnect?.task.cancel()
        pendingConnect = nil
        let monitor = BTBatteryMonitor.shared
        if let battery = Self.battery(for: output.id, in: monitor.devices) {
            present(.connected, output, battery: battery)
            return
        }
        // No wait when no level can come: the setting is off or AirPods
        // levels are not readable without the Bluetooth permission.
        guard monitor.canReadAudioBatteries else {
            present(.connected, output, battery: nil)
            return
        }
        let task = Task { [weak self] in
            try? await Task.sleep(for: Self.batteryWait)
            guard !Task.isCancelled, let self, self.pendingConnect?.output.id == output.id else { return }
            self.pendingConnect = nil
            self.present(.connected, output, battery: nil)
        }
        pendingConnect = (output, task)
    }

    private func present(_ phase: HeadphoneGlance.Phase, _ output: HeadphoneOutput, battery: QuickBattery?) {
        nextGlanceID &+= 1
        glance = HeadphoneGlance(id: nextGlanceID, phase: phase, output: output, battery: battery)
        let seconds = phase == .connected
            ? HeadphoneGlancePolicy.clampedDuration(Defaults[.headphoneGlanceDuration])
            : HeadphoneGlancePolicy.disconnectDuration
        let id = nextGlanceID
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.glance?.id == id else { return }
            self.glance = nil
        }
    }

    private static func battery(for id: String, in devices: [BTBatteryDevice]) -> QuickBattery? {
        guard let battery = devices.first(where: { $0.id == id })?.battery, !battery.isEmpty else { return nil }
        return battery
    }

    // MARK: Core Audio

    /// The Bluetooth outputs Core Audio lists now. A handful of property
    /// reads per device; runs only on a device-list change.
    private static func readOutputs() -> [HeadphoneOutput] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &devicesAddress, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &devicesAddress, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { device in
            guard let transport = uint32(device, kAudioDevicePropertyTransportType),
                  HeadphoneDeviceInfo.isHeadphoneOutput(transport: transport, outputStreams: outputStreamCount(device)),
                  let uid = string(device, kAudioDevicePropertyDeviceUID)
            else { return nil }
            let name = string(device, kAudioObjectPropertyName) ?? uid
            return HeadphoneDeviceInfo.output(uid: uid, name: name, modelUID: string(device, kAudioDevicePropertyModelUID))
        }
    }

    private static func uint32(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        let text = value.takeRetainedValue() as String
        return text.isEmpty ? nil : text
    }

    private static func outputStreamCount(_ device: AudioObjectID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}
