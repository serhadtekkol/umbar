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
    /// The app's pid, when known. Lets a capturing process be named by who
    /// it is (`NSRunningApplication(processIdentifier:)`) rather than by
    /// the bundle ID it reports to the HAL.
    var pid: Int32? = nil
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
    ///   - ownPID: umbar's pid. umbar never captures audio, and the
    ///     indicator must not report umbar to itself if it ever did.
    ///   - runningApps: regular apps, used to name a process and to fold a
    ///     helper ("com.google.Chrome.helper") into its app ("Google Chrome").
    ///   - ownCamera: the running camera is umbar's own mirror
    ///     (`OwnCameraClaim.masksCamera`). CoreMediaIO cannot attribute a
    ///     camera to a process, so this is how the mirror keeps the ear,
    ///     the Şimdi row and the edge glow from reporting umbar to itself.
    ///
    /// The microphone rule: when the process list is readable it decides
    /// alone. A device that does input *and* output (a USB headset) reports
    /// "running somewhere" while it only plays music, so the device flag is
    /// trusted only when there is no process list to ask.
    static func reduce(_ sample: PrivacySample, enabled: Bool, ownPID: Int32,
                       runningApps: [PrivacyRunningApp], ownCamera: Bool = false) -> PrivacyUsage {
        guard enabled else { return .idle }
        let microphone: Bool
        var names: [String] = []
        if let processes = sample.audioProcesses {
            let capturing = processes.filter { $0.isRunningInput && $0.pid != ownPID }
            microphone = !capturing.isEmpty
            names = capturing.compactMap { displayName(bundleID: $0.bundleID, pid: $0.pid, runningApps: runningApps) }
        } else {
            microphone = sample.inputDeviceRunning
        }
        let unique = Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return PrivacyUsage(camera: sample.cameraRunning && !ownCamera, microphone: microphone, microphoneApps: unique)
    }

    /// The name to show for a capturing process, or nil to leave it unnamed.
    ///
    /// The pid decides first: when it belongs to a running app, that app's
    /// own bundle ID (from LaunchServices) is used, never the one the
    /// process reported to the HAL. A process cannot then borrow another
    /// app's name ("Zoom") by claiming its bundle ID (security review L9).
    /// Only a process LaunchServices does not list falls back to the
    /// reported bundle ID; that name is as trustworthy as the claim.
    ///
    /// Either way, an exact bundle match wins; otherwise the longest running
    /// app whose bundle ID is a dotted prefix (Chrome's and Electron apps'
    /// audio helpers). WebKit's GPU process captures for Safari *and* for
    /// every app with a web view, so it is never guessed: an unnamed line is
    /// better than a wrong one.
    static func displayName(bundleID: String?, pid: Int32? = nil, runningApps: [PrivacyRunningApp]) -> String? {
        if let pid, let owner = runningApps.first(where: { $0.pid == pid }) {
            if owner.bundleID.hasPrefix("com.apple.WebKit.") { return nil }
            let parent = runningApps
                .filter { owner.bundleID.hasPrefix($0.bundleID + ".") }
                .max { $0.bundleID.count < $1.bundleID.count }
            return parent?.name ?? owner.name
        }
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let exact = runningApps.first(where: { $0.bundleID == bundleID }) { return exact.name }
        if bundleID.hasPrefix("com.apple.WebKit.") { return nil }
        return runningApps
            .filter { bundleID.hasPrefix($0.bundleID + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }?
            .name
    }
}

/// Whether "a camera is running" is umbar's own mirror.
///
/// The mirror claims the camera just before it starts the capture and
/// releases it once the capture has stopped. While the claim masks, the
/// indicator reports no camera.
///
/// Two cases keep the mask honest:
///  - A camera already running elsewhere when the mirror starts (a call in
///    FaceTime) is not masked at all: it was not umbar's, and masking it
///    would also make the edge glow flash "camera on" when the panel closes.
///  - After the release the HAL can report "running somewhere" for a
///    moment longer. The mask holds until a sample says the camera is off,
///    or the monitor's `releaseGrace` timer calls `expire`, whichever is
///    first. After the grace a camera that is still running is someone
///    else's, and it is shown.
///
/// No wall-clock time is kept here. An earlier version compared a `Date`
/// deadline with `Date()` while the timer slept on the monotonic clock, so
/// a clock stepped back during the grace left the mask on until the next
/// HAL event (Muhittin L1). The timer firing now ends the grace by itself.
///
/// The cost, accepted: while the mirror itself runs, another app turning a
/// camera on is not reported until the mirror stops. The user is looking
/// at a live camera preview in that moment, and macOS's own green
/// indicator is unaffected.
struct OwnCameraClaim: Equatable, Sendable {
    /// Longer than the HAL's lag after `stopRunning` (well under a second
    /// in practice), short enough that a masked camera cannot hide for long.
    static let releaseGrace: TimeInterval = 2

    private(set) var masksCamera = false
    private var holding = false
    /// Between the release and the first "camera off" sample or `expire`.
    private(set) var releasing = false

    /// The mirror is about to start the capture.
    /// - Parameter cameraRunningElsewhere: the last sample's camera flag.
    mutating func begin(cameraRunningElsewhere: Bool) {
        // Restarting during a release: the camera never went off, so
        // whatever was masked is still the mirror's.
        if !holding && !releasing {
            masksCamera = !cameraRunningElsewhere
        }
        holding = true
        releasing = false
    }

    /// The mirror's capture has stopped. The caller starts a
    /// `releaseGrace` timer that ends in `expire` when `releasing`.
    mutating func end() {
        guard holding else { return }
        holding = false
        releasing = masksCamera
    }

    /// Call after every sample.
    mutating func observe(cameraRunning: Bool) {
        guard releasing, !cameraRunning else { return }
        finishRelease()
    }

    /// The grace timer fired: a camera still running now is not umbar's.
    mutating func expire() {
        guard releasing else { return }
        finishRelease()
    }

    private mutating func finishRelease() {
        masksCamera = false
        releasing = false
    }
}
