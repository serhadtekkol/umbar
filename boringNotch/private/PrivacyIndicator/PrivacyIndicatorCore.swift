//
//  PrivacyIndicatorCore.swift
//  boringNotch
//
//  F23 camera/microphone in-use indicator: the pure part. Turns one raw
//  sample of the hardware (is a camera running, which audio processes are
//  capturing) into what the notch shows. No CoreAudio or CoreMediaIO here,
//  so umbarTests compiles this file hostless (membershipExceptions).
//
//  Why the camera is never named. CoreMediaIO only says that a camera is
//  running somewhere, not for whom. The only ways to learn the process are
//  private (the TCC/ControlCenter attribution SPI) or parsing the unified
//  log, and both are ruled out for umbar. So the camera line says "Camera
//  in use" without a name; the microphone line names apps because CoreAudio
//  publishes its process objects (kAudioHardwarePropertyProcessObjectList,
//  public since macOS 14).
//

import Foundation

/// One CoreAudio process object as read from the HAL.
struct PrivacyAudioProcess: Equatable, Sendable {
    var pid: Int32
    /// kAudioProcessPropertyBundleID; nil or empty for tools without a bundle.
    var bundleID: String?
    /// kAudioProcessPropertyIsRunningInput.
    var isRunningInput: Bool
}

/// A running app the name of a capturing process can be resolved against.
struct PrivacyRunningApp: Equatable, Sendable {
    var bundleID: String
    var name: String
}

/// One read of the hardware, taken after any listener fired.
struct PrivacySample: Equatable, Sendable {
    /// Any camera reports kCMIODevicePropertyDeviceIsRunningSomewhere.
    var cameraRunning: Bool
    /// Any device with input streams reports
    /// kAudioDevicePropertyDeviceIsRunningSomewhere.
    var inputDeviceRunning: Bool
    /// The HAL's process objects, or nil when that list could not be read.
    var audioProcesses: [PrivacyAudioProcess]?
}

/// What the notch shows.
struct PrivacyUsage: Equatable, Sendable {
    var camera: Bool
    var microphone: Bool
    /// Display names of the apps capturing audio, de-duplicated and sorted.
    /// Empty when the microphone is in use but nobody could be named.
    var microphoneApps: [String]

    static let idle = PrivacyUsage(camera: false, microphone: false, microphoneApps: [])

    var isActive: Bool { camera || microphone }

    /// Reduces a sample to what is shown.
    ///
    /// - Parameters:
    ///   - sample: the raw hardware read.
    ///   - enabled: the user's setting; off shows nothing whatever runs.
    ///   - ownPID: umbar's pid. umbar never captures, but if a future
    ///     feature did, the indicator must not report umbar to itself.
    ///   - runningApps: regular apps, used to name a process and to fold a
    ///     helper ("com.google.Chrome.helper") into its app ("Google Chrome").
    ///
    /// The microphone rule: when the process list is readable it decides
    /// alone. A device that does input *and* output (a USB headset) reports
    /// "running somewhere" while it only plays music, so the device flag is
    /// trusted only when there is no process list to ask.
    static func reduce(_ sample: PrivacySample, enabled: Bool, ownPID: Int32,
                       runningApps: [PrivacyRunningApp]) -> PrivacyUsage {
        guard enabled else { return .idle }
        let microphone: Bool
        var names: [String] = []
        if let processes = sample.audioProcesses {
            let capturing = processes.filter { $0.isRunningInput && $0.pid != ownPID }
            microphone = !capturing.isEmpty
            names = capturing.compactMap { displayName(bundleID: $0.bundleID, runningApps: runningApps) }
        } else {
            microphone = sample.inputDeviceRunning
        }
        let unique = Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return PrivacyUsage(camera: sample.cameraRunning, microphone: microphone, microphoneApps: unique)
    }

    /// The name to show for a capturing process, or nil to leave it unnamed.
    ///
    /// An exact bundle match wins; otherwise the longest running app whose
    /// bundle ID is a dotted prefix (Chrome's and Electron apps' audio
    /// helpers). WebKit's GPU process captures for Safari *and* for every
    /// app with a web view, so it is never guessed: an unnamed line is
    /// better than a wrong one.
    static func displayName(bundleID: String?, runningApps: [PrivacyRunningApp]) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let exact = runningApps.first(where: { $0.bundleID == bundleID }) { return exact.name }
        if bundleID.hasPrefix("com.apple.WebKit.") { return nil }
        return runningApps
            .filter { bundleID.hasPrefix($0.bundleID + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }?
            .name
    }
}
