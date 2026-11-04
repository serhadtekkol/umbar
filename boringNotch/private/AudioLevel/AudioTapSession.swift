//
//  AudioTapSession.swift
//  boringNotch
//
//  One live capture: a Core Audio process tap, the private aggregate device
//  that delivers its samples, and the IOProc that feeds them to an
//  AudioLevelMeter. Built whole or not at all; `invalidate` (or deinit)
//  destroys every HAL object it made, so nothing outlives the session and
//  no audio work happens while the glow is not listening.
//
//  Samples go from the IO buffer into the meter's ring and nowhere else:
//  nothing is written to disk, kept beyond the 43 ms analysis window, or
//  sent anywhere.
//

import CoreAudio
import Foundation
import os

struct AudioTapError: Error, CustomStringConvertible {
    let step: String
    let status: OSStatus?

    var description: String {
        status.map { "\(step) failed (OSStatus \($0))" } ?? "\(step) failed"
    }
}

/// Thread contract: created, used and invalidated from one serial queue
/// (AudioLevelMonitor's control queue). The IO block runs on the HAL's IO
/// thread and touches only `meter`, whose `ingest` is real-time safe.
final class AudioTapSession: @unchecked Sendable {
    let target: AudioTapTargeting.Target
    let meter: AudioLevelMeter
    /// UID of the output device the aggregate was built around; a change of
    /// the default output device means the session must be rebuilt.
    let outputDeviceUID: String

    private let system = AudioHardwareSystem.shared
    private var tap: AudioHardwareTap?
    private var aggregate: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var started = false

    private static let log = Logger(subsystem: "umbar", category: "AudioLevel")

    /// Builds and starts the capture. On any failure everything already made
    /// is destroyed before the error is thrown.
    init(target: AudioTapTargeting.Target) throws {
        self.target = target

        guard let output = try Self.step("read default output device", { try AudioHardwareSystem.shared.defaultOutputDevice }) else {
            throw AudioTapError(step: "find default output device", status: nil)
        }
        outputDeviceUID = try Self.step("read output device UID") { try output.uid }

        let description: CATapDescription
        switch target {
        case .processes(let ids):
            description = CATapDescription(monoMixdownOfProcesses: ids)
        case .global:
            // Exclude umbar itself; it plays nothing today, but a future
            // sound effect must not feed back into its own glow.
            let own = (try? AudioHardwareSystem.shared.process(for: getpid()))?.map { [$0.id] } ?? []
            description = CATapDescription(monoGlobalTapButExcludeProcesses: own)
        }
        description.name = "umbar level"
        description.uuid = UUID()
        // Private: invisible to other apps' device lists. Unmuted: the user
        // keeps hearing the music; the tap only listens.
        description.isPrivate = true
        description.muteBehavior = .unmuted

        // The meter needs the tap's sample rate, so the tap comes first; the
        // temporary `meter` keeps `self` incomplete until every step passed.
        var createdTap: AudioHardwareTap?
        var createdAggregate: AudioHardwareAggregateDevice?
        var createdProc: AudioDeviceIOProcID?
        func rollback() {
            if let createdProc, let createdAggregate {
                AudioDeviceDestroyIOProcID(createdAggregate.id, createdProc)
            }
            if let createdAggregate { try? AudioHardwareSystem.shared.destroyAggregateDevice(createdAggregate) }
            if let createdTap { try? AudioHardwareSystem.shared.destroyProcessTap(createdTap) }
        }

        do {
            guard let tap = try Self.step("create process tap", { try AudioHardwareSystem.shared.makeProcessTap(description: description) }) else {
                throw AudioTapError(step: "create process tap", status: nil)
            }
            createdTap = tap
            let format = try Self.step("read tap format") { try tap.format }
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32 else {
                throw AudioTapError(step: "tap format is not 32-bit float", status: nil)
            }
            guard let meter = AudioLevelMeter(sampleRate: format.mSampleRate) else {
                throw AudioTapError(step: "make meter at \(format.mSampleRate) Hz", status: nil)
            }
            self.meter = meter
            let tapUID = try Self.step("read tap UID") { try tap.uid }

            // Two shapes, chosen by whether the output device also has
            // inputs:
            //  - Output-only (built-in speakers, a display, most DACs): the
            //    device is the aggregate's sub-device and clock source, and
            //    the drift-corrected tap follows it.
            //  - Output with inputs (a Bluetooth or USB headset, an audio
            //    interface): adding it as a sub-device also adds its
            //    microphone streams, and starting the aggregate would start
            //    that input: the microphone indicator lights, a Bluetooth
            //    headset drops to its call profile, and the microphone
            //    permission is checked. So the aggregate holds the tap
            //    alone and no device input is ever part of it.
            // If the device's streams cannot be read, it is treated as
            // having inputs: a glow that does not move is the safe failure.
            let outputInputStreams = Self.inputStreamCount(of: output.id)
            let tapOnly = outputInputStreams != 0
            var composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "umbar level",
                kAudioAggregateDeviceUIDKey: "com.serhadbahadir.umbar.level.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUID,
                ]],
            ]
            if !tapOnly {
                composition[kAudioAggregateDeviceMainSubDeviceKey] = outputDeviceUID
                composition[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputDeviceUID]]
            }
            guard let aggregate = try Self.step("create aggregate device", { try AudioHardwareSystem.shared.makeAggregateDevice(description: composition) }) else {
                throw AudioTapError(step: "create aggregate device", status: nil)
            }
            createdAggregate = aggregate

            // Belt and braces for the shape above: the IOProc reads the
            // tap's buffer and nothing else, so even an aggregate that
            // carries an input stream cannot feed it into the meter.
            guard let aggregateInputs = Self.inputStreamCount(of: aggregate.id),
                  let tapBuffers = AudioTapStreamLayout.tapBuffers(
                      aggregateInputStreams: aggregateInputs,
                      subdeviceInputStreams: tapOnly ? 0 : (outputInputStreams ?? 0),
                      tapStreams: 1) else {
                throw AudioTapError(step: "find the tap's stream in the aggregate device", status: nil)
            }
            Self.log.debug("aggregate built (tap only: \(tapOnly, privacy: .public), tap buffers: \(tapBuffers, privacy: .public))")

            // nil queue: the block runs on the HAL's real-time IO thread
            // with no extra copy or hop. It must not allocate or lock;
            // AudioLevelMeter.ingest is written to that rule.
            var procID: AudioDeviceIOProcID?
            let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, nil) { _, inputData, _, _, _ in
                meter.ingest(inputData, buffers: tapBuffers)
            }
            guard status == noErr, let procID else {
                throw AudioTapError(step: "create IOProc", status: status)
            }
            createdProc = procID

            let startStatus = AudioDeviceStart(aggregate.id, procID)
            guard startStatus == noErr else {
                throw AudioTapError(step: "start aggregate device", status: startStatus)
            }
            self.tap = tap
            self.aggregate = aggregate
            ioProcID = procID
            started = true
        } catch {
            rollback()
            throw error
        }
    }

    deinit { invalidate() }

    /// Stops IO and destroys the IOProc, the aggregate device and the tap,
    /// in that order (the reverse of creation). Idempotent.
    func invalidate() {
        if let aggregate, let ioProcID {
            if started { AudioDeviceStop(aggregate.id, ioProcID) }
            AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
        }
        started = false
        ioProcID = nil
        if let aggregate {
            do { try system.destroyAggregateDevice(aggregate) } catch {
                Self.log.error("destroy aggregate device failed: \(String(describing: error), privacy: .public)")
            }
        }
        aggregate = nil
        if let tap {
            do { try system.destroyProcessTap(tap) } catch {
                Self.log.error("destroy process tap failed: \(String(describing: error), privacy: .public)")
            }
        }
        tap = nil
    }

    /// Number of input streams `device` exposes, or nil when the HAL does
    /// not answer.
    private static func inputStreamCount(of device: AudioObjectID) -> Int? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return nil }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    /// Runs one HAL step, turning the overlay's error into one that names
    /// the step, so the log says which call failed and with which status.
    private static func step<T>(_ name: String, _ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as AudioHardwareError {
            throw AudioTapError(step: name, status: error.error)
        } catch let error as AudioTapError {
            throw error
        } catch {
            throw AudioTapError(step: "\(name): \(error)", status: nil)
        }
    }
}

/// Reads the HAL's process list as targeting candidates. A process that
/// vanishes mid-read is skipped, not an error.
enum AudioProcessList {
    static func candidates() -> [AudioTapTargeting.Candidate] {
        guard let processes = try? AudioHardwareSystem.shared.processes else { return [] }
        return processes.map { process in
            AudioTapTargeting.Candidate(
                objectID: process.id,
                bundleID: (try? process.bundleID) ?? nil,
                isRunningOutput: (try? process.isRunningOutput) ?? false,
                isRunningInput: (try? process.isRunningInput) ?? false)
        }
    }
}
