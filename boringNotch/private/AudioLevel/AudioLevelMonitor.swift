//
//  AudioLevelMonitor.swift
//  boringNotch
//
//  Live loudness of the now-playing app's audio output, for the edge glow's
//  audio-reactive mode. Off unless the user turns that mode on; the system
//  asks for audio-capture permission the first time it starts. Levels are
//  computed in memory and never stored or sent anywhere.
//
//  Contract shared by the edge glow (reader) and the capture (writer).
//  The implementation behind it is a stub until the capture lands.
//

import Combine
import Foundation

@MainActor
final class AudioLevelMonitor: ObservableObject {
    static let shared = AudioLevelMonitor()

    enum Authorization: Equatable { case unknown, granted, denied, unsupported }

    /// Smoothed loudness, 0…1. 0 while stopped.
    @Published private(set) var level: Float = 0
    /// Smoothed band energies, 0…1: below ~250 Hz, ~250 Hz–4 kHz, above ~4 kHz.
    @Published private(set) var bass: Float = 0
    @Published private(set) var mid: Float = 0
    @Published private(set) var treble: Float = 0
    @Published private(set) var isRunning = false
    @Published private(set) var authorization: Authorization = .unknown

    private init() {}

    /// Starts or stops capture. Safe to call repeatedly; the glow calls it
    /// with `true` only while the mode is on and music is playing.
    func setActive(_ active: Bool) {}
}
