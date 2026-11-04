//
//  MirrorCamera.swift
//  boringNotch
//
//  The mirror's camera: permission, device list and the capture session.
//  `MirrorSession` (MirrorPolicy.swift) decides; this file carries out.
//
//  Nothing in AVFoundation is touched while the mirror is off: no device
//  discovery, no authorization read, no session. Turning it on creates a
//  discovery session (which lists devices without opening one) and reads
//  the authorization status (which never prompts). The capture session is
//  built on the first start and its input is removed on every stop, so
//  the camera, and macOS's green indicator, are off whenever the preview
//  is not on screen.
//
//  The frames go to an AVCaptureVideoPreviewLayer only. There is no video
//  data output, no file output and no photo output: nothing is recorded,
//  stored or sent.
//
//  Threading. Main actor for state and policy; `MirrorCapture` confines
//  the AVCaptureSession to its own serial queue because startRunning and
//  stopRunning block.
//

import AppKit
import AVFoundation
import Combine
import Defaults
import os

extension Defaults.Keys {
    /// Off by default (opt-in). A new name rather than boring.notch's
    /// `showMirror`, so a development build that had the old key on does
    /// not come back with the camera feature enabled.
    static let mirrorEnabled = Key<Bool>("mirrorEnabled", default: false)
}

@MainActor
final class MirrorCamera: ObservableObject {
    static let shared = MirrorCamera()

    @Published private(set) var tileState: MirrorTileState = .idle
    /// The preview's layer; nil until the first start. The layer outlives
    /// a stop (it just shows nothing), so the tile does not rebuild its view.
    @Published private(set) var previewLayer: AVCaptureVideoPreviewLayer?
    /// For Settings: whether to show the "open System Settings" hint.
    @Published private(set) var access: MirrorAccess = .notDetermined

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "umbar", category: "Mirror")
    private var session = MirrorSession()
    private var cameraAvailable = false
    /// Tiles on screen, one per display's panel.
    private var visibleTiles: Set<AnyHashable> = []
    private var userPresent = true

    private var capture: MirrorCapture?
    private var discovery: AVCaptureDevice.DiscoverySession?
    private var devicesObservation: NSKeyValueObservation?
    private var subscriptions: Set<AnyCancellable> = []
    private var enabledSubscription: AnyCancellable?
    private var accessRequestInFlight = false

    private init() {}

    /// Follows the setting for the life of the app. Call once at launch.
    /// Never prompts: an already-on setting only reads the status.
    func start() {
        guard enabledSubscription == nil else { return }
        enabledSubscription = Defaults.publisher(.mirrorEnabled)
            .map(\.newValue)
            .removeDuplicates()
            .sink { [weak self] enabled in
                MainActor.assumeIsolated { enabled ? self?.activate() : self?.deactivate() }
            }
    }

    /// The user flipped the toggle in Settings. This, and a tap on the
    /// tile while macOS has never been asked, are the only two places that
    /// can raise the camera prompt.
    func userSetEnabled(_ enabled: Bool) {
        let was = Defaults[.mirrorEnabled]
        Defaults[.mirrorEnabled] = enabled
        // The publisher activates on the next turn; read the status now so
        // the prompt decision does not see a stale `.notDetermined`.
        if enabled { access = Self.currentAccess() }
        if MirrorAccessPolicy.requestsOnEnable(wasEnabled: was, isEnabled: enabled, access: access) {
            requestAccess()
        }
    }

    /// A tile appeared on, or left, an open panel's Şimdi page.
    func setTileVisible(_ visible: Bool, owner: AnyHashable) {
        let changed = visible ? visibleTiles.insert(owner).inserted : visibleTiles.remove(owner) != nil
        if changed { apply() }
    }

    func tap() {
        guard let command = session.tap(conditions) else { return }
        perform(command)
        refreshTile()
    }

    // MARK: Lifecycle

    private func activate() {
        access = Self.currentAccess()
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
        self.discovery = discovery
        // KVO on the device list replaces the deprecated
        // AVCaptureDeviceWasConnected/WasDisconnected notifications.
        devicesObservation = discovery.observe(\.devices, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.devicesChanged() }
        }
        CritterSystemState.shared.$userAway
            .removeDuplicates()
            .sink { [weak self] away in
                MainActor.assumeIsolated {
                    self?.userPresent = !away
                    self?.apply()
                }
            }
            .store(in: &subscriptions)
        // The user may grant or revoke access in System Settings while
        // umbar runs; there is no notification for that, so it is re-read
        // whenever umbar becomes active (System Settings closing, or a
        // click on the notch after it).
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.access = Self.currentAccess()
                    self.apply()
                }
            }
            .store(in: &subscriptions)
        apply()
    }

    private func deactivate() {
        apply() // enabled is false now: stops a running preview first.
        devicesObservation?.invalidate()
        devicesObservation = nil
        discovery = nil
        subscriptions.removeAll()
        cameraAvailable = false
    }

    private func devicesChanged() {
        let devices = discovery?.devices ?? []
        cameraAvailable = !devices.isEmpty
        // The camera in use was unplugged (or its Continuity iPhone walked
        // away): stop rather than silently switching to another camera.
        if session.running, let current = capture?.currentDeviceID,
           !devices.contains(where: { $0.uniqueID == current }) {
            log.notice("mirror: camera disconnected")
            session.sessionEnded()
            stopCapture()
        }
        apply()
    }

    // MARK: Policy

    private var conditions: MirrorConditions {
        MirrorConditions(enabled: Defaults[.mirrorEnabled], access: access,
                         cameraAvailable: cameraAvailable, tileVisible: !visibleTiles.isEmpty,
                         userPresent: userPresent)
    }

    private func apply() {
        if let command = session.update(conditions) { perform(command) }
        refreshTile()
    }

    private func refreshTile() {
        let state = session.tileState(conditions)
        if state != tileState { tileState = state }
    }

    private func perform(_ command: MirrorCommand) {
        switch command {
        case .start: startCapture()
        case .stop: stopCapture()
        case .requestAccess: requestAccess()
        case .openPrivacySettings: Self.openPrivacySettings()
        }
    }

    // MARK: Access

    private static func currentAccess() -> MirrorAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    private func requestAccess() {
        guard !accessRequestInFlight else { return }
        accessRequestInFlight = true
        Task { @MainActor [weak self] in
            _ = await AVCaptureDevice.requestAccess(for: .video)
            guard let self else { return }
            self.accessRequestInFlight = false
            self.access = Self.currentAccess()
            self.apply()
        }
    }

    /// Settings > Privacy & Security > Camera.
    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Capture

    private func startCapture() {
        // The user's chosen camera (Control Centre > Video Effects, or a
        // Continuity iPhone that was picked), else the first one listed.
        guard let device = AVCaptureDevice.systemPreferredCamera ?? discovery?.devices.first else {
            session.sessionEnded()
            return
        }
        let capture = self.capture ?? makeCapture()
        PrivacyIndicatorMonitor.shared.mirrorDidClaimCamera()
        capture.start(device: device) { [weak self] started in
            Task { @MainActor in
                guard let self, !started else { return }
                // Could not open the camera (in exclusive use by another
                // app, or gone in the meantime): back to the idle tile.
                self.log.error("mirror: capture did not start")
                self.session.sessionEnded()
                // Also removes a half-added input; releases the claim.
                self.stopCapture()
                self.refreshTile()
            }
        }
    }

    private func stopCapture() {
        capture?.stop {
            Task { @MainActor in PrivacyIndicatorMonitor.shared.mirrorDidReleaseCamera() }
        }
    }

    private func makeCapture() -> MirrorCapture {
        let capture = MirrorCapture()
        let layer = AVCaptureVideoPreviewLayer(session: capture.session)
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer
        // Posted on the capture's own thread, not main.
        NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification, object: capture.session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.session.running else { return }
                    self.log.error("mirror: capture runtime error")
                    self.session.sessionEnded()
                    self.stopCapture()
                    self.refreshTile()
                }
            }
            .store(in: &captureSubscriptions)
        self.capture = capture
        return capture
    }

    /// Kept apart from `subscriptions`, which turning the mirror off clears;
    /// the capture object and its error observer live for the app.
    private var captureSubscriptions: Set<AnyCancellable> = []
}

/// The AVCaptureSession and its single input, confined to `queue`.
final class MirrorCapture: @unchecked Sendable {
    /// Read-only outside `queue`, apart from handing it to the preview layer.
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "umbar.mirror.capture", qos: .userInitiated)
    private var input: AVCaptureDeviceInput?
    private let lock = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// The uniqueID of the camera being captured, for unplug detection.
    var currentDeviceID: String? { lock.withLock { $0 } }

    /// Opens `device` and starts running. `completion(false)` when the
    /// camera could not be opened.
    func start(device: AVCaptureDevice, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            do {
                if input?.device.uniqueID != device.uniqueID {
                    let next = try AVCaptureDeviceInput(device: device)
                    session.beginConfiguration()
                    if let input { session.removeInput(input) }
                    // A tile of ~112 pt does not need more; lower presets
                    // also keep the camera's power draw down.
                    if session.canSetSessionPreset(.medium) { session.sessionPreset = .medium }
                    guard session.canAddInput(next) else {
                        session.commitConfiguration()
                        input = nil
                        completion(false)
                        return
                    }
                    session.addInput(next)
                    session.commitConfiguration()
                    input = next
                }
                lock.withLock { $0 = device.uniqueID }
                if !session.isRunning { session.startRunning() }
                completion(session.isRunning)
            } catch {
                completion(false)
            }
        }
    }

    /// Stops running and removes the input, so the device is released
    /// (the green indicator goes out) rather than merely paused.
    func stop(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
            if let input {
                session.beginConfiguration()
                session.removeInput(input)
                session.commitConfiguration()
                self.input = nil
            }
            lock.withLock { $0 = nil }
            completion()
        }
    }
}
