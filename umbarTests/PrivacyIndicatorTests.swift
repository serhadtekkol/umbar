//
//  PrivacyIndicatorTests.swift
//  umbarTests
//
//  F23: how one hardware sample becomes what the notch shows, and how a
//  capturing process gets its name. The HAL listeners themselves
//  (PrivacyHardwareProbe) are not exercised here.
//

import Foundation
import Testing

private let me: Int32 = 4242
private let apps = [
    PrivacyRunningApp(bundleID: "us.zoom.xos", name: "zoom.us"),
    PrivacyRunningApp(bundleID: "com.apple.FaceTime", name: "FaceTime"),
    PrivacyRunningApp(bundleID: "com.google.Chrome", name: "Google Chrome"),
    PrivacyRunningApp(bundleID: "com.apple.Safari", name: "Safari"),
]

private func process(_ pid: Int32, _ bundle: String?, input: Bool = true) -> PrivacyAudioProcess {
    PrivacyAudioProcess(pid: pid, bundleID: bundle, isRunningInput: input)
}

private func reduce(camera: Bool = false, device: Bool = false, _ processes: [PrivacyAudioProcess]?,
                    enabled: Bool = true) -> PrivacyUsage {
    PrivacyUsage.reduce(PrivacySample(cameraRunning: camera, inputDeviceRunning: device, audioProcesses: processes),
                        enabled: enabled, ownPID: me, runningApps: apps)
}

@Suite("PrivacyIndicator reduction", .timeLimit(.minutes(1)))
struct PrivacyUsageReductionTests {
    @Test func nothingRunningIsIdle() {
        #expect(reduce([]) == .idle)
        #expect(!reduce([]).isActive)
    }

    @Test func cameraIsShownWithoutAName() {
        let usage = reduce(camera: true, [])
        #expect(usage == PrivacyUsage(camera: true, microphone: false, microphoneApps: []))
        #expect(usage.isActive)
    }

    @Test func disabledShowsNothingWhateverRuns() {
        #expect(reduce(camera: true, device: true, [process(1, "us.zoom.xos")], enabled: false) == .idle)
    }

    @Test func capturingProcessesAreNamedSortedAndDeduplicated() {
        let usage = reduce([process(10, "us.zoom.xos"), process(11, "com.apple.FaceTime"), process(12, "us.zoom.xos")])
        #expect(usage.microphone)
        #expect(usage.microphoneApps == ["FaceTime", "zoom.us"])
    }

    @Test func processesNotCapturingDoNotCount() {
        let usage = reduce([process(10, "us.zoom.xos", input: false)])
        #expect(!usage.microphone)
    }

    /// A USB headset plays music: its device is "running somewhere" but no
    /// process captures. The process list wins, so no microphone dot.
    @Test func duplexDeviceOutputAloneIsNotAMicrophone() {
        #expect(!reduce(device: true, [process(10, "com.apple.Music", input: false)]).microphone)
    }

    @Test func deviceFlagIsTheFallbackWithoutAProcessList() {
        let usage = reduce(device: true, nil)
        #expect(usage.microphone)
        #expect(usage.microphoneApps.isEmpty)
        #expect(!reduce(device: false, nil).microphone)
    }

    @Test func umbarNeverReportsItself() {
        #expect(!reduce([process(me, "com.serhadbahadir.umbar")]).microphone)
    }

    @Test func unnamedCaptureStillShowsTheMicrophone() {
        let usage = reduce([process(10, nil), process(11, "")])
        #expect(usage.microphone)
        #expect(usage.microphoneApps.isEmpty)
    }
}

@Suite("PrivacyIndicator naming", .timeLimit(.minutes(1)))
struct PrivacyNamingTests {
    @Test func exactBundleMatch() {
        #expect(PrivacyUsage.displayName(bundleID: "com.apple.FaceTime", runningApps: apps) == "FaceTime")
    }

    @Test func helperFoldsIntoItsApp() {
        #expect(PrivacyUsage.displayName(bundleID: "com.google.Chrome.helper", runningApps: apps) == "Google Chrome")
    }

    @Test func longestPrefixWins() {
        let nested = apps + [PrivacyRunningApp(bundleID: "com.google.Chrome.canary", name: "Chrome Canary")]
        #expect(PrivacyUsage.displayName(bundleID: "com.google.Chrome.canary.helper", runningApps: nested) == "Chrome Canary")
    }

    /// "com.google.Chromebook" must not become Chrome: the prefix is dotted.
    @Test func prefixMustEndAtADot() {
        #expect(PrivacyUsage.displayName(bundleID: "com.google.Chromebook", runningApps: apps) == nil)
    }

    /// WebKit captures for Safari and every web view; never guess.
    @Test func webKitIsNeverGuessed() {
        #expect(PrivacyUsage.displayName(bundleID: "com.apple.WebKit.GPU", runningApps: apps) == nil)
    }

    @Test func unknownToolStaysUnnamed() {
        #expect(PrivacyUsage.displayName(bundleID: "org.example.recorder", runningApps: apps) == nil)
        #expect(PrivacyUsage.displayName(bundleID: nil, runningApps: apps) == nil)
    }
}
