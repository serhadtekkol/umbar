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
        claim.observe(cameraRunning: true)
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
        claim.end()
        // The HAL still says "running" just after stopRunning.
        claim.observe(cameraRunning: true)
        #expect(claim.masksCamera)
        claim.observe(cameraRunning: false)
        #expect(!claim.masksCamera)
        #expect(!claim.releasing)
    }

    @Test func aCameraStillOnAfterTheGraceIsSomeoneElses() {
        var claim = OwnCameraClaim()
        claim.begin(cameraRunningElsewhere: false)
        claim.end()
        claim.observe(cameraRunning: true)
        claim.expire() // the grace timer
        #expect(!claim.masksCamera)
        #expect(usage(claim, camera: true).camera)
    }

    @Test func aCameraOffSampleWhileHoldingDoesNotRelease() {
        // The first sample after begin can come before the hardware is up.
        var claim = OwnCameraClaim()
        claim.begin(cameraRunningElsewhere: false)
        claim.observe(cameraRunning: false)
        #expect(claim.masksCamera)
    }

    @Test func restartDuringTheReleaseKeepsTheMask() {
        var claim = OwnCameraClaim()
        claim.begin(cameraRunningElsewhere: false)
        claim.end()
        // Re-tap before the HAL reported off: the last sample still says on,
        // but that is the mirror's own camera.
        claim.begin(cameraRunningElsewhere: true)
        #expect(claim.masksCamera)
        #expect(!claim.releasing)
        // The old grace timer firing no longer applies while holding.
        claim.expire()
        #expect(claim.masksCamera)
    }

    @Test func endWithoutBeginIsANoOp() {
        var claim = OwnCameraClaim()
        claim.end()
        claim.expire()
        #expect(!claim.masksCamera)
        #expect(!claim.releasing)
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

    /// Muhittin L1: the clock stepping back during the grace (NTP, a manual
    /// change) must not keep the mask on. Nothing here reads a clock; the
    /// timer firing is enough, whatever samples came in between.
    @Test func theGraceTimerEndsTheMaskWhateverTheWallClockDid() {
        var claim = OwnCameraClaim()
        claim.begin(cameraRunningElsewhere: false)
        claim.end()
        for _ in 0..<5 { claim.observe(cameraRunning: true) }
        #expect(claim.masksCamera)
        claim.expire()
        #expect(!claim.masksCamera)
        #expect(usage(claim, camera: true).camera)
    }

    @Test func aCameraStillMaskedBeforeTheTimerIsStillMasked() {
        var claim = OwnCameraClaim()
        claim.begin(cameraRunningElsewhere: false)
        claim.end()
        claim.observe(cameraRunning: true)
        #expect(claim.releasing)
        #expect(!usage(claim, camera: true).camera)
    }
}
