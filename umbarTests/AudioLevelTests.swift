//
//  AudioLevelTests.swift
//  umbarTests
//
//  The audio-reactive glow's numbers: dB to 0…1, attack/release, the three
//  bands of a spectrum, the real-time meter fed with synthetic buffers, and
//  which processes the tap aims at. No sound is played and no tap is opened.
//

import CoreAudio
import Foundation
import Testing

private let sampleRate = 48_000.0

/// `count` samples of `amplitude·sin(2πft)`, plus `extra` sines if given.
private func sine(
    _ frequency: Double, amplitude: Float, count: Int, extra: [(Double, Float)] = []
) -> [Float] {
    let tones = [(frequency, amplitude)] + extra
    return (0..<count).map { n in
        tones.reduce(Float(0)) { sum, tone in
            sum + tone.1 * Float(sin(2 * Double.pi * tone.0 * Double(n) / sampleRate))
        }
    }
}

private func expectClose(_ value: Float, _ expected: Float, within tolerance: Float,
                         sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(value - expected) <= tolerance,
            "\(value) is not within \(tolerance) of \(expected)", sourceLocation: sourceLocation)
}

@Suite("AudioLevelMath", .timeLimit(.minutes(1)))
struct AudioLevelMathTests {
    @Test func decibelScaleMapsFloorToZeroAndFullScaleToOne() {
        #expect(AudioLevelMath.normalized(decibels: -50) == 0)
        #expect(AudioLevelMath.normalized(decibels: 0) == 1)
        expectClose(AudioLevelMath.normalized(decibels: -25), 0.5, within: 1e-6)
        // Out of range clamps instead of overshooting.
        #expect(AudioLevelMath.normalized(decibels: -80) == 0)
        #expect(AudioLevelMath.normalized(decibels: 6) == 1)
        #expect(AudioLevelMath.normalized(decibels: .nan) == 0)
    }

    @Test func silenceAndGarbageReadAsZero() {
        #expect(AudioLevelMath.normalized(rms: 0) == 0)
        #expect(AudioLevelMath.normalized(rms: -1) == 0)
        #expect(AudioLevelMath.normalized(rms: .nan) == 0)
        #expect(AudioLevelMath.normalized(rms: .infinity) == 0)
        #expect(AudioLevelMath.decibels(rms: 0).isFinite)
    }

    @Test func rmsOfFullScaleSineIsMinusThreeDecibels() {
        let samples = sine(1_000, amplitude: 1, count: 4_800)
        let rms = samples.withUnsafeBufferPointer(AudioLevelMath.rms)
        expectClose(AudioLevelMath.decibels(rms: rms), -3.0103, within: 0.01)
        #expect([Float]().withUnsafeBufferPointer(AudioLevelMath.rms) == 0)
    }

    @Test func attackIsFastAndReleaseIsSlow() {
        expectClose(AudioLevelMath.smooth(previous: 0, target: 1), 0.5, within: 1e-6)
        expectClose(AudioLevelMath.smooth(previous: 1, target: 0), 0.88, within: 1e-6)
    }

    @Test func releaseReachesExactSilence() {
        var value: Float = 1
        var ticks = 0
        while value > 0, ticks < 200 {
            value = AudioLevelMath.smooth(previous: value, target: 0)
            ticks += 1
        }
        #expect(value == 0)
        // 0.88ⁿ < 0.001 after ~54 ticks: under two seconds at 30 Hz.
        #expect(ticks < 60)
    }

    @Test func readingSmoothsEachFieldOnItsOwn() {
        let start = AudioLevelReading(level: 1, bass: 0, mid: 0.5, treble: 0.5)
        let target = AudioLevelReading(level: 0, bass: 1, mid: 0.5, treble: 1)
        let next = start.smoothed(toward: target)
        expectClose(next.level, 0.88, within: 1e-6)
        expectClose(next.bass, 0.5, within: 1e-6)
        #expect(next.mid == 0.5)
        expectClose(next.treble, 0.75, within: 1e-6)
    }

    @Test func bandEdgesFallOnTheDocumentedFrequencies() {
        let bins = AudioLevelMath.bandBins(sampleRate: sampleRate, fftSize: 2048)
        let binHz = sampleRate / 2048
        #expect(bins.bass.lowerBound == 1)
        #expect(bins.bass.upperBound == bins.mid.lowerBound)
        #expect(bins.mid.upperBound == bins.treble.lowerBound)
        #expect(bins.treble.upperBound == 1024)
        #expect(abs(Double(bins.mid.lowerBound) * binHz - 250) < binHz)
        #expect(abs(Double(bins.treble.lowerBound) * binHz - 4_000) < binHz)
        // A degenerate rate yields empty bands, not a crash.
        let none = AudioLevelMath.bandBins(sampleRate: 0, fftSize: 2048)
        #expect(none.bass.isEmpty && none.mid.isEmpty && none.treble.isEmpty)
    }
}

@Suite("AudioSpectrumAnalyzer", .timeLimit(.minutes(1)))
struct AudioSpectrumAnalyzerTests {
    private func analyze(_ samples: [Float]) -> AudioLevelReading {
        let analyzer = AudioSpectrumAnalyzer(fftSize: 2048)!
        return samples.withUnsafeBufferPointer { analyzer.analyze($0, sampleRate: sampleRate) }
    }

    @Test func rejectsSizesThatAreNotPowersOfTwo() {
        #expect(AudioSpectrumAnalyzer(fftSize: 1000) == nil)
        #expect(AudioSpectrumAnalyzer(fftSize: 32) == nil)
        #expect(AudioSpectrumAnalyzer(fftSize: 1024) != nil)
    }

    @Test func silenceAndShortInputReadSilent() {
        #expect(analyze([Float](repeating: 0, count: 2048)) == .silent)
        #expect(analyze([Float](repeating: 0.5, count: 100)) == .silent)
    }

    /// A tone lands in its own band at the level the time domain gives it
    /// (same dB scale), and the other two bands stay near the floor.
    @Test(arguments: [(100.0, 0), (1_000.0, 1), (8_000.0, 2)])
    func toneLandsInItsBand(frequency: Double, band: Int) {
        let amplitude: Float = 0.5
        let reading = analyze(sine(frequency, amplitude: amplitude, count: 2048))
        let expected = AudioLevelMath.normalized(rms: amplitude / Float(2).squareRoot())
        let bands = [reading.bass, reading.mid, reading.treble]
        expectClose(bands[band], expected, within: 0.03)
        expectClose(reading.level, expected, within: 0.01)
        for other in 0..<3 where other != band {
            #expect(bands[other] < 0.15, "band \(other) leaked \(bands[other]) for \(frequency) Hz")
        }
    }

    @Test func mixedSignalLightsEveryBand() {
        let samples = sine(80, amplitude: 0.4, count: 2048, extra: [(1_500, 0.2), (6_000, 0.1)])
        let reading = analyze(samples)
        #expect(reading.bass > reading.mid)
        #expect(reading.mid > reading.treble)
        #expect(reading.treble > 0.5)
    }

    @Test func louderIsHigher() {
        let quiet = analyze(sine(200, amplitude: 0.05, count: 2048))
        let loud = analyze(sine(200, amplitude: 0.5, count: 2048))
        #expect(loud.level > quiet.level)
        #expect(loud.bass > quiet.bass)
        // ×10 amplitude is +20 dB, 0.4 of the 50 dB scale.
        expectClose(loud.level - quiet.level, 0.4, within: 0.01)
    }
}

@Suite("AudioLevelMeter", .timeLimit(.minutes(1)))
struct AudioLevelMeterTests {
    /// Feeds `channels` as one interleaved buffer, or as one buffer per
    /// channel when `interleaved` is false, in IO-sized chunks.
    private func feed(_ meter: AudioLevelMeter, channels: [[Float]], interleaved: Bool, chunk: Int = 512) {
        let frames = channels[0].count
        var offset = 0
        while offset < frames {
            let count = min(chunk, frames - offset)
            if interleaved {
                var data = [Float](repeating: 0, count: count * channels.count)
                for f in 0..<count { for c in channels.indices { data[f * channels.count + c] = channels[c][offset + f] } }
                data.withUnsafeMutableBytes { raw in
                    var list = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: UInt32(channels.count),
                            mDataByteSize: UInt32(raw.count),
                            mData: raw.baseAddress))
                    meter.ingest(&list, buffers: 0..<1)
                }
            } else {
                let list = AudioBufferList.allocate(maximumBuffers: channels.count)
                var storage: [UnsafeMutablePointer<Float>] = []
                defer {
                    storage.forEach { $0.deallocate() }
                    free(list.unsafeMutablePointer)
                }
                for c in channels.indices {
                    let samples = UnsafeMutablePointer<Float>.allocate(capacity: count)
                    for f in 0..<count { samples[f] = channels[c][offset + f] }
                    storage.append(samples)
                    list[c] = AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                        mData: UnsafeMutableRawPointer(samples))
                }
                meter.ingest(list.unsafePointer, buffers: 0..<channels.count)
            }
            offset += count
        }
    }

    @Test func staysSilentUntilTheFirstFullWindow() {
        let meter = AudioLevelMeter(sampleRate: sampleRate)!
        feed(meter, channels: [sine(1_000, amplitude: 0.5, count: 2047)], interleaved: true)
        #expect(meter.analysisCount == 0)
        #expect(meter.latest() == .silent)
        feed(meter, channels: [[0.5]], interleaved: true)
        #expect(meter.analysisCount == 1)
        #expect(meter.latest().level > 0.5)
    }

    @Test func analysesEveryHalfWindowAfterThat() {
        let meter = AudioLevelMeter(sampleRate: sampleRate)!
        feed(meter, channels: [sine(1_000, amplitude: 0.5, count: 2048 + 1024 * 3)], interleaved: true)
        #expect(meter.analysisCount == 4)
    }

    @Test func interleavedStereoIsAveragedToMono() {
        let tone = sine(1_000, amplitude: 0.5, count: 4096)
        let meter = AudioLevelMeter(sampleRate: sampleRate)!
        feed(meter, channels: [tone, tone], interleaved: true)
        let expected = AudioLevelMath.normalized(rms: 0.5 / Float(2).squareRoot())
        expectClose(meter.latest().level, expected, within: 0.01)
        expectClose(meter.latest().mid, expected, within: 0.03)
    }

    @Test func nonInterleavedChannelsAreAveragedToMono() {
        // Opposite phase cancels to silence: proof both buffers were mixed.
        let tone = sine(1_000, amplitude: 0.5, count: 4096)
        let meter = AudioLevelMeter(sampleRate: sampleRate)!
        feed(meter, channels: [tone, tone.map { -$0 }], interleaved: false)
        #expect(meter.analysisCount > 0)
        #expect(meter.latest() == .silent)

        let same = AudioLevelMeter(sampleRate: sampleRate)!
        feed(same, channels: [tone, tone], interleaved: false)
        #expect(same.latest().level > 0.8)
    }

    @Test func nonFiniteSamplesReadAsSilence() {
        let meter = AudioLevelMeter(sampleRate: sampleRate)!
        feed(meter, channels: [[Float](repeating: .nan, count: 4096)], interleaved: true)
        #expect(meter.analysisCount > 0)
        #expect(meter.latest() == .silent)
    }

    @Test func emptyAndChannellessBuffersAreIgnored() {
        let meter = AudioLevelMeter(sampleRate: sampleRate)!
        var empty = AudioBufferList(
            mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil))
        meter.ingest(&empty, buffers: 0..<1)
        #expect(meter.analysisCount == 0)
        #expect(AudioLevelMeter(sampleRate: 0) == nil)
    }

    /// Regression for the headset case: the aggregate delivers the
    /// microphone's buffer first and the tap's second. Only the tap's may
    /// move the meter, and a range the list cannot satisfy reads nothing.
    @Test func readsOnlyTheTapsBuffers() {
        let microphone = sine(1_000, amplitude: 0.5, count: 4096)
        let tap = [Float](repeating: 0, count: 4096)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        let storage = [microphone, tap].map { channel -> UnsafeMutablePointer<Float> in
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: channel.count)
            samples.initialize(from: channel, count: channel.count)
            return samples
        }
        defer {
            storage.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for index in storage.indices {
            list[index] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(4096 * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(storage[index]))
        }

        let tapOnly = AudioLevelMeter(sampleRate: sampleRate)!
        tapOnly.ingest(list.unsafePointer, buffers: 1..<2)
        #expect(tapOnly.analysisCount > 0)
        #expect(tapOnly.latest() == .silent)

        let micOnly = AudioLevelMeter(sampleRate: sampleRate)!
        micOnly.ingest(list.unsafePointer, buffers: 0..<1)
        #expect(micOnly.latest().level > 0.5)

        let outOfRange = AudioLevelMeter(sampleRate: sampleRate)!
        outOfRange.ingest(list.unsafePointer, buffers: 2..<3)
        outOfRange.ingest(list.unsafePointer, buffers: 1..<1)
        #expect(outOfRange.analysisCount == 0)
    }

    @Test func packingKeepsFourValuesTogether() {
        let reading = AudioLevelReading(level: 1, bass: 0.25, mid: 0.5, treble: 0)
        let back = AudioLevelMeter.unpack(AudioLevelMeter.pack(reading))
        #expect(back.level == 1 && back.treble == 0)
        expectClose(back.bass, 0.25, within: 1e-4)
        expectClose(back.mid, 0.5, within: 1e-4)
        // Out-of-range input clamps instead of spilling into a neighbour.
        let wild = AudioLevelMeter.unpack(AudioLevelMeter.pack(
            AudioLevelReading(level: 2, bass: -1, mid: .nan, treble: 1)))
        #expect(wild == AudioLevelReading(level: 1, bass: 0, mid: 0, treble: 1))
    }
}

@Suite("AudioTapStreamLayout", .timeLimit(.minutes(1)))
struct AudioTapStreamLayoutTests {
    /// Stream counts as read from the HAL smoke on macOS 27 (no IO).
    @Test func outputOnlyDeviceHasTheTapAlone() {
        #expect(AudioTapStreamLayout.tapBuffers(aggregateInputStreams: 1, subdeviceInputStreams: 0, tapStreams: 1) == 0..<1)
    }

    @Test func duplexDeviceInputsComeFirstAndAreSkipped() {
        #expect(AudioTapStreamLayout.tapBuffers(aggregateInputStreams: 2, subdeviceInputStreams: 1, tapStreams: 1) == 1..<2)
        #expect(AudioTapStreamLayout.tapBuffers(aggregateInputStreams: 4, subdeviceInputStreams: 3, tapStreams: 1) == 3..<4)
    }

    @Test func unexpectedLayoutsRefuseToCapture() {
        // More or fewer streams than sub-device + tap: something else is
        // in the list, so no index can be trusted.
        #expect(AudioTapStreamLayout.tapBuffers(aggregateInputStreams: 2, subdeviceInputStreams: 0, tapStreams: 1) == nil)
        #expect(AudioTapStreamLayout.tapBuffers(aggregateInputStreams: 0, subdeviceInputStreams: 0, tapStreams: 1) == nil)
        #expect(AudioTapStreamLayout.tapBuffers(aggregateInputStreams: 1, subdeviceInputStreams: 1, tapStreams: 1) == nil)
        #expect(AudioTapStreamLayout.tapBuffers(aggregateInputStreams: 1, subdeviceInputStreams: 1, tapStreams: 0) == nil)
        #expect(AudioTapStreamLayout.tapBuffers(aggregateInputStreams: 0, subdeviceInputStreams: -1, tapStreams: 1) == nil)
    }
}

@Suite("AudioTapTargeting", .timeLimit(.minutes(1)))
struct AudioTapTargetingTests {
    private typealias C = AudioTapTargeting.Candidate

    @Test func appAndItsHelpersBelongToIt() {
        #expect(AudioTapTargeting.belongs(process: "com.spotify.client", to: "com.spotify.client"))
        #expect(AudioTapTargeting.belongs(process: "com.google.Chrome.helper", to: "com.google.Chrome"))
        #expect(AudioTapTargeting.belongs(process: "company.thebrowser.browser.helper", to: "company.thebrowser.Browser"))
        #expect(AudioTapTargeting.belongs(process: "com.apple.WebKit.GPU", to: "com.apple.Safari"))
    }

    @Test func lookalikesDoNotBelong() {
        #expect(!AudioTapTargeting.belongs(process: "com.spotify.clientx", to: "com.spotify.client"))
        #expect(!AudioTapTargeting.belongs(process: "com.spotify", to: "com.spotify.client"))
        #expect(!AudioTapTargeting.belongs(process: "com.apple.WebKit.GPU", to: "com.google.Chrome"))
        #expect(!AudioTapTargeting.belongs(process: "anything", to: ""))
    }

    @Test func tapsOnlyTheAppsOutputtingProcesses() {
        let candidates = [
            C(objectID: 9, bundleID: "com.google.Chrome.helper", isRunningOutput: true),
            C(objectID: 3, bundleID: "com.google.Chrome", isRunningOutput: true),
            C(objectID: 5, bundleID: "com.google.Chrome.helper.renderer", isRunningOutput: false),
            C(objectID: 7, bundleID: "com.apple.Music", isRunningOutput: true),
            C(objectID: 8, bundleID: nil, isRunningOutput: true),
        ]
        let target = AudioTapTargeting.target(nowPlaying: "com.google.Chrome", candidates: candidates, ownBundleID: "com.serhadbahadir.umbar")
        #expect(target == .processes([3, 9]))
    }

    @Test func fallsBackToGlobalWhenTheAppIsNotHeard() {
        let quiet = [C(objectID: 3, bundleID: "com.spotify.client", isRunningOutput: false)]
        #expect(AudioTapTargeting.target(nowPlaying: "com.spotify.client", candidates: quiet, ownBundleID: nil) == .global)
        #expect(AudioTapTargeting.target(nowPlaying: "com.spotify.client", candidates: [], ownBundleID: nil) == .global)
        #expect(AudioTapTargeting.target(nowPlaying: nil, candidates: quiet, ownBundleID: nil) == .global)
        #expect(AudioTapTargeting.target(nowPlaying: "", candidates: quiet, ownBundleID: nil) == .global)
    }

    @Test func neverTapsUmbarItself() {
        let candidates = [C(objectID: 4, bundleID: "com.serhadbahadir.umbar", isRunningOutput: true)]
        #expect(AudioTapTargeting.target(
            nowPlaying: "com.serhadbahadir.umbar", candidates: candidates,
            ownBundleID: "com.serhadbahadir.umbar") == .global)
    }

    @Test func neverFallsBackToGlobalWhileTheMicrophoneIsInUse() {
        let call = C(objectID: 6, bundleID: "us.zoom.xos", isRunningOutput: true, isRunningInput: true)
        let quietPlayer = C(objectID: 3, bundleID: "com.spotify.client", isRunningOutput: false)
        #expect(AudioTapTargeting.target(nowPlaying: "com.spotify.client", candidates: [quietPlayer, call], ownBundleID: nil) == nil)
        #expect(AudioTapTargeting.target(nowPlaying: nil, candidates: [call], ownBundleID: nil) == nil)
        // A capturing process without a bundle ID still counts.
        let anonymous = C(objectID: 8, bundleID: nil, isRunningOutput: false, isRunningInput: true)
        #expect(AudioTapTargeting.target(nowPlaying: nil, candidates: [anonymous], ownBundleID: nil) == nil)
    }

    @Test func perAppTapIsStillAllowedWhileTheMicrophoneIsInUse() {
        let candidates = [
            C(objectID: 3, bundleID: "com.spotify.client", isRunningOutput: true),
            C(objectID: 6, bundleID: "us.zoom.xos", isRunningOutput: true, isRunningInput: true),
        ]
        #expect(AudioTapTargeting.target(nowPlaying: "com.spotify.client", candidates: candidates, ownBundleID: nil) == .processes([3]))
    }

    @Test func umbarsOwnTapDoesNotCountAsMicrophoneUse() {
        // The live tap shows up as input on umbar's process object; it
        // must not make the global fallback switch itself off.
        let own = C(objectID: 4, bundleID: "com.serhadbahadir.umbar", isRunningOutput: false, isRunningInput: true)
        #expect(AudioTapTargeting.target(
            nowPlaying: nil, candidates: [own],
            ownBundleID: "com.serhadbahadir.umbar") == .global)
    }

    @Test func microphoneTearsDownAGlobalTapButKeepsAPerAppOne() {
        let app = "com.spotify.client"
        #expect(AudioTapTargeting.shouldRebuild(current: .global, currentApp: app, proposed: nil, app: app))
        #expect(AudioTapTargeting.shouldRebuild(current: .global, currentApp: nil, proposed: nil, app: nil))
        #expect(!AudioTapTargeting.shouldRebuild(current: .processes([3]), currentApp: app, proposed: nil, app: app))
        // Another app with no per-app target during a call: the old app's
        // tap goes.
        #expect(AudioTapTargeting.shouldRebuild(current: .processes([3]), currentApp: app, proposed: nil, app: "com.apple.Music"))
    }

    @Test func sameAppTapOnlyGrows() {
        let app = "com.google.Chrome"
        // A helper went quiet or the app briefly had none: keep the tap.
        #expect(!AudioTapTargeting.shouldRebuild(current: .processes([3, 9]), currentApp: app, proposed: .processes([3]), app: app))
        #expect(!AudioTapTargeting.shouldRebuild(current: .processes([3]), currentApp: app, proposed: .global, app: app))
        #expect(!AudioTapTargeting.shouldRebuild(current: .global, currentApp: app, proposed: .global, app: app))
        // A new process started playing, or the app is now heard at all.
        #expect(AudioTapTargeting.shouldRebuild(current: .processes([3]), currentApp: app, proposed: .processes([3, 9]), app: app))
        #expect(AudioTapTargeting.shouldRebuild(current: .global, currentApp: app, proposed: .processes([3]), app: app))
    }

    @Test func anotherAppRebuildsUnlessTheTargetIsTheSame() {
        #expect(AudioTapTargeting.shouldRebuild(
            current: .processes([3]), currentApp: "com.google.Chrome",
            proposed: .global, app: "com.spotify.client"))
        #expect(AudioTapTargeting.shouldRebuild(
            current: .processes([3]), currentApp: "com.google.Chrome",
            proposed: .processes([7]), app: "com.apple.Music"))
        #expect(!AudioTapTargeting.shouldRebuild(
            current: .global, currentApp: "com.google.Chrome",
            proposed: .global, app: "com.spotify.client"))
    }
}

@Suite("AudioPermissionRequestGate", .timeLimit(.minutes(1)))
struct AudioPermissionRequestGateTests {
    // The gate's methods are mutating, which #expect cannot call inline.

    @Test func oneRequestAtATime() {
        var gate = AudioPermissionRequestGate()
        let first = gate.begin()
        let whileOutstanding = gate.begin()
        #expect(first != nil)
        #expect(whileOutstanding == nil)
        gate.finish(first!)
        let afterAnswer = gate.begin()
        #expect(afterAnswer != nil)
    }

    /// Regression: with a bool flag, a completion that never fired kept
    /// every later start from asking. Deactivating now clears it.
    @Test func cancelLetsTheNextStartAskAgain() {
        var gate = AudioPermissionRequestGate()
        _ = gate.begin()
        gate.cancel()
        let next = gate.begin()
        #expect(next != nil)
    }

    @Test func expiryEndsOnlyAnUnansweredRequest() {
        var gate = AudioPermissionRequestGate()
        let lost = gate.begin()!
        let expired = gate.expire(lost)
        let expiredAgain = gate.expire(lost)
        #expect(expired)
        #expect(!expiredAgain)

        let answered = gate.begin()!
        gate.finish(answered)
        let expiredAfterAnswer = gate.expire(answered)
        #expect(!expiredAfterAnswer)
    }

    @Test func staleAnswersAndTimersLeaveANewerRequestAlone() {
        var gate = AudioPermissionRequestGate()
        let old = gate.begin()!
        gate.cancel()
        let current = gate.begin()!
        gate.finish(old)
        let oldExpired = gate.expire(old)
        let anotherWhileCurrent = gate.begin()
        let currentExpired = gate.expire(current)
        #expect(!oldExpired)
        #expect(anotherWhileCurrent == nil)
        #expect(currentExpired)
    }
}
