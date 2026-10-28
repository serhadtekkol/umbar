//
//  PrivacyIndicatorMonitor.swift
//  boringNotch
//
//  F23: watches whether any app uses a camera or a microphone, with public
//  HAL properties and listener blocks only (no polling):
//    - cameras:     kCMIODevicePropertyDeviceIsRunningSomewhere (CoreMediaIO)
//    - microphones: kAudioProcessPropertyIsRunningInput per process object,
//                   kAudioDevicePropertyDeviceIsRunningSomewhere per input
//                   device as the fallback (CoreAudio)
//    - plus the device and process lists, so hot-plugged cameras and newly
//      started processes get listeners too.
//
//  Never opens a device. Reading these properties is not capture, so no
//  camera or microphone permission is needed and no TCC prompt is raised;
//  umbar has no camera/microphone entitlement or usage string, and must
//  not gain one for this feature.
//
//  Threading. `PrivacyHardwareProbe` lives on its own serial queue: every
//  listener block is delivered there, and the listener tables are only
//  touched there. A sample is a Sendable value handed to the main actor,
//  where names are resolved and `usage` is published.
//

import AppKit
import Combine
import CoreAudio
import CoreMediaIO
import Defaults
import os

@MainActor
final class PrivacyIndicatorMonitor: ObservableObject {
    static let shared = PrivacyIndicatorMonitor()

    /// What the closed ear and the Şimdi row show. `.idle` while disabled.
    @Published private(set) var usage: PrivacyUsage = .idle

    private let probe = PrivacyHardwareProbe()
    private var settings: AnyCancellable?

    private init() {}

    /// Follows the setting for the life of the app. Call once at launch.
    func start() {
        guard settings == nil else { return }
        settings = Defaults.publisher(.privacyIndicatorEnabled)
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated { enabled ? self?.activate() : self?.deactivate() }
            }
    }

    private func activate() {
        probe.start { [weak self] sample in
            Task { @MainActor in self?.publish(sample) }
        }
    }

    private func deactivate() {
        probe.stop()
        usage = .idle
    }

    private func publish(_ sample: PrivacySample) {
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> PrivacyRunningApp? in
            guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
            return PrivacyRunningApp(bundleID: id, name: name, pid: app.processIdentifier)
        }
        let next = PrivacyUsage.reduce(sample, enabled: Defaults[.privacyIndicatorEnabled],
                                       ownPID: ProcessInfo.processInfo.processIdentifier, runningApps: apps)
        if next != usage { usage = next }
    }

    #if DEBUG
    /// For the off-screen renderers only; nothing is listening there.
    func showFixture(_ fixture: PrivacyUsage) { usage = fixture }
    #endif
}

// MARK: - HAL probe

/// Installs and removes the listener blocks and reads one sample after
/// each callback. All state is confined to `queue`.
final class PrivacyHardwareProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "umbar.privacy-indicator", qos: .utility)
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "umbar", category: "PrivacyIndicator")

    private var onSample: (@Sendable (PrivacySample) -> Void)?
    /// Listener blocks by object, kept because removal needs the same block.
    private var cameraListeners: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var audioListeners: [AudioObjectID: (address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = [:]
    private var cameraListListener: CMIOObjectPropertyListenerBlock?
    private var audioListListener: AudioObjectPropertyListenerBlock?
    private var processListListener: AudioObjectPropertyListenerBlock?

    func start(onSample: @escaping @Sendable (PrivacySample) -> Void) {
        queue.async { [self] in
            guard self.onSample == nil else { return }
            self.onSample = onSample
            installListListeners()
            refresh()
        }
    }

    func stop() {
        queue.async { [self] in
            guard onSample != nil else { return }
            onSample = nil
            removeAllListeners()
        }
    }

    // MARK: Refresh

    /// Brings the per-object listeners in line with the current device and
    /// process lists, then reports a sample. Runs after every callback, so a
    /// change in either list is picked up by the same path as a state flip.
    private func refresh() {
        guard let onSample else { return }
        let cameras = Self.cmioDevices()
        let inputs = Self.audioDevices().filter(Self.hasInputStreams)
        let processes = Self.audioProcesses()

        sync(cameras: Set(cameras))
        sync(audio: Set(inputs).union(processes ?? []))

        let sample = PrivacySample(
            cameraRunning: cameras.contains { Self.cmioUInt32(Self.cmioRunningAddress, of: $0) == 1 },
            inputDeviceRunning: inputs.contains { Self.audioUInt32(Self.deviceRunningAddress, of: $0) == 1 },
            audioProcesses: processes?.map { id in
                PrivacyAudioProcess(
                    pid: Int32(bitPattern: Self.audioUInt32(Self.processPIDAddress, of: id) ?? 0),
                    bundleID: Self.audioString(Self.processBundleAddress, of: id),
                    isRunningInput: Self.audioUInt32(Self.processInputAddress, of: id) == 1)
            })
        onSample(sample)
    }

    private func installListListeners() {
        let cameraList: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        var cameraAddress = Self.cmioDevicesAddress
        if CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &cameraAddress, queue, cameraList) == 0 {
            cameraListListener = cameraList
        } else {
            log.error("camera list listener not installed")
        }

        let audioList: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        var devicesAddress = Self.audioDevicesAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, queue, audioList) == noErr {
            audioListListener = audioList
        }
        let processList: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
        var processesAddress = Self.processListAddress
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &processesAddress, queue, processList) == noErr {
            processListListener = processList
        } else {
            log.error("audio process list listener not installed; falling back to device state")
        }
    }

    private func sync(cameras: Set<CMIOObjectID>) {
        for gone in Set(cameraListeners.keys).subtracting(cameras) {
            var address = Self.cmioRunningAddress
            if let block = cameraListeners.removeValue(forKey: gone) {
                _ = CMIOObjectRemovePropertyListenerBlock(gone, &address, queue, block)
            }
        }
        for new in cameras.subtracting(cameraListeners.keys) {
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            var address = Self.cmioRunningAddress
            if CMIOObjectAddPropertyListenerBlock(new, &address, queue, block) == 0 {
                cameraListeners[new] = block
            }
        }
    }

    /// One listener per audio object: input devices listen for "running
    /// somewhere", process objects for "running input". An object is one
    /// or the other, so the selector is chosen by asking which it is.
    private func sync(audio objects: Set<AudioObjectID>) {
        for gone in Set(audioListeners.keys).subtracting(objects) {
            if var entry = audioListeners.removeValue(forKey: gone) {
                _ = AudioObjectRemovePropertyListenerBlock(gone, &entry.address, queue, entry.block)
            }
        }
        for new in objects.subtracting(audioListeners.keys) {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.refresh() }
            var probe = Self.processInputAddress
            var address = AudioObjectHasProperty(new, &probe) ? Self.processInputAddress : Self.deviceRunningAddress
            if AudioObjectAddPropertyListenerBlock(new, &address, queue, block) == noErr {
                audioListeners[new] = (address, block)
            }
        }
    }

    private func removeAllListeners() {
        sync(cameras: [])
        sync(audio: [])
        if let block = cameraListListener {
            var address = Self.cmioDevicesAddress
            _ = CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue, block)
        }
        if let block = audioListListener {
            var address = Self.audioDevicesAddress
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        if let block = processListListener {
            var address = Self.processListAddress
            _ = AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        }
        cameraListListener = nil
        audioListListener = nil
        processListListener = nil
    }

    // MARK: Addresses

    private static func cmio(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func audio(_ selector: AudioObjectPropertySelector,
                              scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static let cmioDevicesAddress = cmio(kCMIOHardwarePropertyDevices)
    private static let cmioRunningAddress = cmio(kCMIODevicePropertyDeviceIsRunningSomewhere)
    private static let audioDevicesAddress = audio(kAudioHardwarePropertyDevices)
    private static let processListAddress = audio(kAudioHardwarePropertyProcessObjectList)
    private static let deviceRunningAddress = audio(kAudioDevicePropertyDeviceIsRunningSomewhere)
    private static let inputStreamsAddress = audio(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    private static let processPIDAddress = audio(kAudioProcessPropertyPID)
    private static let processBundleAddress = audio(kAudioProcessPropertyBundleID)
    private static let processInputAddress = audio(kAudioProcessPropertyIsRunningInput)

    // MARK: Reads

    private static func cmioDevices() -> [CMIOObjectID] {
        var address = cmioDevicesAddress
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &ids) == 0 else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func cmioUInt32(_ address: CMIOObjectPropertyAddress, of id: CMIOObjectID) -> UInt32? {
        var address = address
        var value: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
        return status == 0 ? value : nil
    }

    private static func audioObjects(_ address: AudioObjectPropertyAddress) -> [AudioObjectID]? {
        var address = address
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty else { return [] }
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func audioDevices() -> [AudioObjectID] { audioObjects(audioDevicesAddress) ?? [] }

    /// nil when the HAL does not answer, which turns on the device fallback.
    private static func audioProcesses() -> [AudioObjectID]? { audioObjects(processListAddress) }

    private static func hasInputStreams(_ id: AudioObjectID) -> Bool {
        var address = inputStreamsAddress
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func audioUInt32(_ address: AudioObjectPropertyAddress, of id: AudioObjectID) -> UInt32? {
        var address = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func audioString(_ address: AudioObjectPropertyAddress, of id: AudioObjectID) -> String? {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
