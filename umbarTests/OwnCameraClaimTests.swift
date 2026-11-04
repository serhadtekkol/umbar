//
//  OwnCameraClaimTests.swift
//  umbarTests
//
//  How the privacy indicator keeps from reporting umbar's own mirror as
//  "camera in use", without hiding anyone else's camera for long. Pure
//  values only; the HAL probe is not exercised.
//

import Foundation
import Testing

@Suite("OwnCameraClaim", .timeLimit(.minutes(1)))
struct OwnCameraClaimTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func sample(camera: Bool) -> PrivacySample {
        PrivacySample(cameraRunning: camera, inputDeviceRunning: false, audioProcesses: [])
    }

    private func usage(_ claim: OwnCameraClaim, camera: Bool) -> PrivacyUsage {
        PrivacyUsage.reduce(sample(camera: camera), enabled: true, ownPID: 1, runningApps: [],
                            ownCamera: claim.masksCamera)
    }

    @Test func noClaimReportsTheCamera() {
        #expect(usage(OwnCameraClaim(), camera: true).camera)
    }

    @Test func theMirrorsOwnCameraIsNotReported() {
        var claim = OwnCameraClaim()
        claim.begin(cameraRunningElsewhere: false)
        claim.observe(cameraRunning: true, now: t0)
        #expect(!usage(claim, camera: true).camera)
        #expect(!usage(claim, camera: true).isActive)
    }

    @Test func aCameraAlreadyOnElsewhereStaysReported() {
        // FaceTime call in progress, then the mirror opens.
        var claim = OwnCameraClaim()
        claim.begin(cameraRunningElsewhere: true)
        #expect(!claim.masksCamera)
        #expect(usage(claim, camera: true).camera)
    }

    @Test func maskHoldsThroughTheHALsLagAfterStop() {
        var claim = OwnCameraClaim()
        claim.begin(cameraRunningElsewhere: false)
        claim.end(now: t0)
        // The HAL still says "running" half a second after stopRunning.
        claim.observe(cameraRunning: true, now: t0.addingTimeInterval(0.5))
        #expect(claim.masksCamera)
        claim.observe(cameraRunning: false, now: t0.addingTimeInterval(0.6))
        #expect(!claim.masksCamera)
        #expect(claim.releaseDeadline == nil)
    }

    @Test func aCameraStillOnAfterTheGraceIsSomeoneElses() {
        var claim = OwnCameraClaim()
        claim.begin(cameraRunningElsewhere: false)
        claim.end(now: t0)
        claim.observe(cameraRunning: true, now: t0.addingTimeInterval(OwnCameraClaim.releaseGrace))
        #expect(!claim.masksCamera)
        #expect(usage(claim, camera: true).camera)
    }

    @Test func aCameraOffSampleWhileHoldingDoesNotRelease() {
        // The first sample after begin can come before the hardware is up.
        var claim = OwnCameraClaim()
        claim.begin(cameraRunningElsewhere: false)
        claim.observe(cameraRunning: false, now: t0)
        #expect(claim.masksCamera)
    }

    @Test func restartDuringTheReleaseKeepsTheMask() {
        var claim = OwnCameraClaim()
        claim.begin(cameraRunningElsewhere: false)
        claim.end(now: t0)
        // Re-tap before the HAL reported off: the last sample still says on,
        // but that is the mirror's own camera.
        claim.begin(cameraRunningElsewhere: true)
        #expect(claim.masksCamera)
        #expect(claim.releaseDeadline == nil)
        // The grace no longer applies while holding.
        claim.observe(cameraRunning: true, now: t0.addingTimeInterval(10))
        #expect(claim.masksCamera)
    }

    @Test func endWithoutBeginIsANoOp() {
        var claim = OwnCameraClaim()
        claim.end(now: t0)
        #expect(!claim.masksCamera)
        #expect(claim.releaseDeadline == nil)
    }

    @Test func maskNeverHidesTheMicrophone() {
        var claim = OwnCameraClaim()
        claim.begin(cameraRunningElsewhere: false)
        let mic = PrivacySample(cameraRunning: true, inputDeviceRunning: false,
                                audioProcesses: [PrivacyAudioProcess(pid: 77, bundleID: "us.zoom.xos", isRunningInput: true)])
        let shown = PrivacyUsage.reduce(mic, enabled: true, ownPID: 1, runningApps: [], ownCamera: claim.masksCamera)
        #expect(!shown.camera)
        #expect(shown.microphone)
    }
}
