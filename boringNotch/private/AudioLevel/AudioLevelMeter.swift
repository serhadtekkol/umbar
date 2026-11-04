//
//  AudioLevelMeter.swift
//  boringNotch
//
//  The real-time half of the capture: takes the tap's buffers on the Core
//  Audio IO thread, folds them to mono into a ring, runs the spectrum every
//  half window and leaves the newest reading in one atomic word for the
//  main thread to pick up. Nothing here allocates, locks or blocks after
//  init, which is what the IO thread requires.
//

import CoreAudio
import Foundation
import Synchronization

/// Thread contract: `ingest` is called from one thread at a time (the IO
/// thread of the session that owns this meter); `latest` from any thread.
/// The only state shared between the two is `packed`, an atomic, which is
/// why the class can be `@unchecked Sendable`.
final class AudioLevelMeter: @unchecked Sendable {
    let sampleRate: Double
    private let analyzer: AudioSpectrumAnalyzer
    private let size: Int
    private let ring: UnsafeMutablePointer<Float>
    private let linear: UnsafeMutablePointer<Float>
    /// Samples between two analyses: half a window, so consecutive windows
    /// overlap by 50% (2048 points at 48 kHz: a fresh reading every 21 ms,
    /// comfortably faster than the 30 Hz the main thread polls at).
    private let hop: Int

    // IO-thread-only state.
    private var writeIndex = 0
    private var filled = 0
    private var sinceAnalysis = 0

    /// level | bass | mid | treble, 16 bits each (0…65535 for 0…1), so the
    /// reader always sees the four values of one window together.
    private let packed = Atomic<UInt64>(0)
    /// Count of analyses so far; lets the probe and the tests tell a fresh
    /// reading from a stale one.
    private let analyses = Atomic<UInt64>(0)

    init?(sampleRate: Double, fftSize: Int = 2048) {
        guard sampleRate > 0, let analyzer = AudioSpectrumAnalyzer(fftSize: fftSize) else { return nil }
        self.sampleRate = sampleRate
        self.analyzer = analyzer
        size = fftSize
        hop = fftSize / 2
        ring = .allocate(capacity: fftSize)
        ring.initialize(repeating: 0, count: fftSize)
        linear = .allocate(capacity: fftSize)
        linear.initialize(repeating: 0, count: fftSize)
    }

    deinit {
        ring.deallocate()
        linear.deallocate()
    }

    /// The newest reading, raw (unsmoothed). Silent until the first full
    /// window has arrived.
    func latest() -> AudioLevelReading {
        Self.unpack(packed.load(ordering: .acquiring))
    }

    var analysisCount: UInt64 { analyses.load(ordering: .relaxed) }

    /// Feeds one IO cycle of 32-bit float samples, interleaved or not, any
    /// channel count; channels are averaged to mono. Real-time safe.
    func ingest(_ bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        var totalChannels = 0
        var frames = Int.max
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, buffer.mData != nil else { return }
            totalChannels += channels
            frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
        }
        guard totalChannels > 0, frames > 0, frames != .max else { return }
        let scale = 1 / Float(totalChannels)

        for frame in 0..<frames {
            var sum: Float = 0
            for buffer in buffers {
                let channels = Int(buffer.mNumberChannels)
                let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                let start = frame * channels
                for channel in 0..<channels { sum += samples[start + channel] }
            }
            push(sum * scale)
        }
    }

    private func push(_ sample: Float) {
        // A NaN or infinity from a misbehaving source would poison every
        // later window through the FFT sums; read it as silence instead.
        ring[writeIndex] = sample.isFinite ? sample : 0
        writeIndex = writeIndex + 1 == size ? 0 : writeIndex + 1
        if filled < size { filled += 1 }
        sinceAnalysis += 1
        guard filled == size, sinceAnalysis >= hop else { return }
        sinceAnalysis = 0

        // Oldest sample first: [writeIndex, size) then [0, writeIndex).
        let tail = size - writeIndex
        linear.update(from: ring + writeIndex, count: tail)
        (linear + tail).update(from: ring, count: writeIndex)
        let reading = analyzer.analyze(UnsafeBufferPointer(start: linear, count: size), sampleRate: sampleRate)
        packed.store(Self.pack(reading), ordering: .releasing)
        analyses.add(1, ordering: .relaxed)
    }

    static func pack(_ reading: AudioLevelReading) -> UInt64 {
        func q(_ value: Float) -> UInt64 {
            guard value.isFinite else { return 0 }
            return UInt64((min(max(value, 0), 1) * 65_535).rounded())
        }
        return q(reading.level) << 48 | q(reading.bass) << 32 | q(reading.mid) << 16 | q(reading.treble)
    }

    static func unpack(_ word: UInt64) -> AudioLevelReading {
        func f(_ shift: UInt64) -> Float { Float((word >> shift) & 0xFFFF) / 65_535 }
        return AudioLevelReading(level: f(48), bass: f(32), mid: f(16), treble: f(0))
    }
}
