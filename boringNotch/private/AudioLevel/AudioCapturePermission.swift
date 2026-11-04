//
//  AudioCapturePermission.swift
//  boringNotch
//
//  The "audio recording" (system audio capture) permission behind process
//  taps. macOS has no public API to read or request it: a tap made without
//  it simply delivers silence, so a denial would be indistinguishable from
//  a quiet song. The TCC framework's preflight/request calls are the only
//  way to know (the open-source AudioCap sample by Guilherme Rambo uses the
//  same two). They are looked up at run time; if a future macOS
//  removes them, this reports `.unavailable` and the capture runs anyway
//  (the system then prompts on its own when the tap first starts).
//
//  The request shows the system prompt with NSAudioCaptureUsageDescription
//  from Info.plist. It is made only from AudioLevelMonitor.setActive(true),
//  never at launch.
//

import Foundation

enum AudioCapturePermission {
    enum Status: Equatable { case granted, denied, notDetermined, unavailable }

    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let framework: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    private static let preflight: PreflightFunction? =
        framework.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: PreflightFunction.self) }

    private static let request: RequestFunction? =
        framework.flatMap { dlsym($0, "TCCAccessRequest") }.map { unsafeBitCast($0, to: RequestFunction.self) }

    /// Current status without prompting. TCCAccessPreflight returns 0 for
    /// granted, 1 for denied and 2 when the user has not been asked.
    static func status() -> Status {
        guard let preflight else { return .unavailable }
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// Shows the system prompt (once per app; later calls answer from the
    /// stored decision) and calls `completion` on the main queue.
    static func requestAccess(_ completion: @escaping @Sendable (Status) -> Void) {
        guard let request else {
            DispatchQueue.main.async { completion(.unavailable) }
            return
        }
        request(service, nil) { granted in
            DispatchQueue.main.async { completion(granted ? .granted : .denied) }
        }
    }
}
