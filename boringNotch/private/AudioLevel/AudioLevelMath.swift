//
//  AudioLevelMath.swift
//  boringNotch
//
//  The pure numbers behind AudioLevelMonitor: loudness in dB mapped to 0…1,
//  the attack/release smoothing the glow sees, and the split of a spectrum
//  into bass, mid and treble. No Core Audio here, so the hostless umbarTests
//  run it on synthetic buffers.
//

import Accelerate
import Foundation

enum AudioLevelMath {
    /// Quietest level that still shows: -50 dBFS maps to 0, 0 dBFS to 1.
    /// Quiet passages of mastered music sit around -40…-30 dBFS and choruses
    /// around -15…-8, so this range keeps both visible without the glow
    /// pinning at 1 on loud tracks.
    static let floorDB: Float = -50

    /// Upper edge of the bass band and lower edge of the treble band, in Hz.
    /// Part of the contract documented on AudioLevelMonitor.
    static let bassUpperHz: Double = 250
    static let trebleLowerHz: Double = 4_000

    /// Per-tick smoothing coefficients at the ~30 Hz publish rate: a beat
    /// reaches the glow within two ticks, and the glow falls back over about
    /// a quarter of a second instead of flickering between beats.
    static let attack: Float = 0.5
    static let release: Float = 0.12

    /// `20·log10(rms)`, with silence (and anything below -200 dB) clamped so
    /// the result is always finite.
    static func decibels(rms: Float) -> Float {
        guard rms.isFinite, rms > 1e-10 else { return -200 }
        return 20 * log10(rms)
    }

    /// Maps dBFS linearly onto 0…1 over `floorDB…0`, clamped at both ends.
    static func normalized(decibels db: Float) -> Float {
        guard db.isFinite else { return 0 }
        return min(max((db - floorDB) / -floorDB, 0), 1)
    }

    /// RMS amplitude straight to the 0…1 scale the monitor publishes.
    static func normalized(rms: Float) -> Float {
        normalized(decibels: decibels(rms: rms))
    }

    /// One step of the asymmetric one-pole follower: rising values move by
    /// `attack` of the gap, falling values by `release`. Snaps to the target
    /// once the gap is invisible, so silence really reaches 0.
    static func smooth(
        previous: Float,
        target: Float,
        attack: Float = AudioLevelMath.attack,
        release: Float = AudioLevelMath.release
    ) -> Float {
        let coefficient = target > previous ? attack : release
        let next = previous + (target - previous) * coefficient
        return abs(next - target) < 0.001 ? target : next
    }

    /// RMS of a block of samples; 0 for an empty block.
    static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard let base = samples.baseAddress, !samples.isEmpty else { return 0 }
        var result: Float = 0
        vDSP_rmsqv(base, 1, &result, vDSP_Length(samples.count))
        return result
    }

    /// Half-open FFT bin ranges for the three bands of an `fftSize`-point
    /// transform at `sampleRate`. Bin 0 (DC) belongs to no band; the
    /// Nyquist bin is left out too, it is outside any audible content.
    static func bandBins(
        sampleRate: Double,
        fftSize: Int
    ) -> (bass: Range<Int>, mid: Range<Int>, treble: Range<Int>) {
        let half = fftSize / 2
        guard sampleRate > 0, half > 1 else { return (1..<1, 1..<1, 1..<1) }
        let binHz = sampleRate / Double(fftSize)
        func bin(_ hz: Double) -> Int { min(max(Int((hz / binHz).rounded()), 1), half) }
        let bassEnd = bin(bassUpperHz)
        let trebleStart = max(bin(trebleLowerHz), bassEnd)
        return (1..<bassEnd, bassEnd..<trebleStart, trebleStart..<half)
    }

    /// RMS amplitude of the part of the signal that falls in `bins`, from
    /// the squared magnitudes of a windowed DFT (`|X_k|²`, unscaled).
    ///
    /// Parseval for a real signal: the windowed mean power is
    /// `2·Σ|X_k|² / (N·Σw²)` over the positive bins, so the same formula
    /// summed over one band gives that band's share. A full-band sine of
    /// amplitude A comes out at A/√2, the same RMS the time domain gives,
    /// so bands and the overall level share one dB scale.
    static func bandRMS(
        squaredMagnitudes: UnsafeBufferPointer<Float>,
        bins: Range<Int>,
        fftSize: Int,
        windowPowerSum: Float
    ) -> Float {
        let clamped = bins.clamped(to: 0..<squaredMagnitudes.count)
        guard !clamped.isEmpty, let base = squaredMagnitudes.baseAddress,
              windowPowerSum > 0, fftSize > 0 else { return 0 }
        var sum: Float = 0
        vDSP_sve(base + clamped.lowerBound, 1, &sum, vDSP_Length(clamped.count))
        let power = 2 * sum / (Float(fftSize) * windowPowerSum)
        return power > 0 ? power.squareRoot() : 0
    }
}

/// The raw (unsmoothed) reading of one analysis window, every field 0…1.
struct AudioLevelReading: Equatable, Sendable {
    var level: Float
    var bass: Float
    var mid: Float
    var treble: Float

    static let silent = AudioLevelReading(level: 0, bass: 0, mid: 0, treble: 0)

    /// `AudioLevelMath.smooth` applied field by field.
    func smoothed(toward target: AudioLevelReading) -> AudioLevelReading {
        AudioLevelReading(
            level: AudioLevelMath.smooth(previous: level, target: target.level),
            bass: AudioLevelMath.smooth(previous: bass, target: target.bass),
            mid: AudioLevelMath.smooth(previous: mid, target: target.mid),
            treble: AudioLevelMath.smooth(previous: treble, target: target.treble)
        )
    }
}

/// Hann-windowed real FFT over a fixed-size block, with every buffer
/// allocated up front so `analyze` is safe on the real-time IO thread: it
/// neither allocates nor locks.
///
/// Not thread-safe: one instance belongs to one thread at a time (the IO
/// thread of one tap session, or a test).
final class AudioSpectrumAnalyzer {
    let fftSize: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private let window: UnsafeMutablePointer<Float>
    private let windowed: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let magnitudes: UnsafeMutablePointer<Float>
    private let windowPowerSum: Float

    /// - Parameter fftSize: a power of two, at least 64. 2048 at 48 kHz gives
    ///   23 Hz bins (five of them below 250 Hz) over a 43 ms window.
    init?(fftSize: Int = 2048) {
        guard fftSize >= 64, fftSize & (fftSize - 1) == 0 else { return nil }
        let log2n = vDSP_Length(fftSize.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.fftSize = fftSize
        self.log2n = log2n
        self.setup = setup
        let half = fftSize / 2
        window = .allocate(capacity: fftSize)
        windowed = .allocate(capacity: fftSize)
        real = .allocate(capacity: half)
        imag = .allocate(capacity: half)
        magnitudes = .allocate(capacity: half)
        vDSP_hann_window(window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        var power: Float = 0
        vDSP_svesq(window, 1, &power, vDSP_Length(fftSize))
        windowPowerSum = power
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        window.deallocate()
        windowed.deallocate()
        real.deallocate()
        imag.deallocate()
        magnitudes.deallocate()
    }

    /// Reads exactly `fftSize` samples and returns the overall level and the
    /// three band levels on the 0…1 scale. Shorter input reads as silence.
    func analyze(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> AudioLevelReading {
        guard samples.count >= fftSize, let input = samples.baseAddress, sampleRate > 0 else {
            return .silent
        }
        let half = fftSize / 2
        let level = AudioLevelMath.normalized(
            rms: AudioLevelMath.rms(UnsafeBufferPointer(start: input, count: fftSize)))

        vDSP_vmul(input, 1, window, 1, windowed, 1, vDSP_Length(fftSize))
        var split = DSPSplitComplex(realp: real, imagp: imag)
        windowed.withMemoryRebound(to: DSPComplex.self, capacity: half) {
            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
        }
        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
        // zrip packs the Nyquist bin into imag[0]; no band uses bin 0, so
        // clearing it keeps DC and Nyquist out of every sum.
        imag[0] = 0
        real[0] = 0
        vDSP_zvmags(&split, 1, magnitudes, 1, vDSP_Length(half))
        // vDSP_fft_zrip returns 2·X_k, so the squared magnitudes are 4·|X_k|².
        var quarter: Float = 0.25
        vDSP_vsmul(magnitudes, 1, &quarter, magnitudes, 1, vDSP_Length(half))

        let bins = AudioLevelMath.bandBins(sampleRate: sampleRate, fftSize: fftSize)
        let spectrum = UnsafeBufferPointer(start: magnitudes, count: half)
        func band(_ range: Range<Int>) -> Float {
            AudioLevelMath.normalized(rms: AudioLevelMath.bandRMS(
                squaredMagnitudes: spectrum, bins: range,
                fftSize: fftSize, windowPowerSum: windowPowerSum))
        }
        return AudioLevelReading(
            level: level, bass: band(bins.bass), mid: band(bins.mid), treble: band(bins.treble))
    }
}
