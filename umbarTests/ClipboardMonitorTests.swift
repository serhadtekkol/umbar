//
//  ClipboardMonitorTests.swift
//  umbarTests
//
//  Spike A2 (card #3): which pasteboard changes the monitor reads, skips or
//  reports as needing permission. Ported from the deterministic part of
//  `Tools/PasteboardProbe selftest`. Nothing here touches the general
//  pasteboard: a fake source, plus one private, uniquely named pasteboard
//  (not subject to pasteboard privacy) for the NSPasteboard conformance.
//  The probe's interactive modes (real alert, CPU cost) stay in Tools/.
//

import AppKit
import Foundation
import Testing

private let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
private let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

/// Scriptable pasteboard that counts content reads.
private final class FakePasteboard: PasteboardSource {
    var changeCount = 0
    var types: [NSPasteboard.PasteboardType]? = []
    var accessBehavior: NSPasteboard.AccessBehavior = .alwaysAllow
    var text: String?
    var imageData: [NSPasteboard.PasteboardType: Data] = [:]
    private(set) var reads = 0
    /// Simulates another app writing while we read.
    var changesDuringRead = false

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        reads += 1
        if changesDuringRead { changeCount += 1 }
        return text
    }

    func data(forType dataType: NSPasteboard.PasteboardType) -> Data? {
        reads += 1
        if changesDuringRead { changeCount += 1 }
        return imageData[dataType]
    }

    func write(_ types: [NSPasteboard.PasteboardType], text: String?) {
        changeCount += 1
        self.types = types
        self.text = text
    }
}

@MainActor
@Suite("ClipboardMonitor", .timeLimit(.minutes(1)))
struct ClipboardMonitorTests {
    @Test func sensitivityMarkers() {
        #expect(ClipboardMonitor.sensitivityMarker(in: [.string, .rtf]) == nil)
        #expect(ClipboardMonitor.sensitivityMarker(in: []) == nil)
        #expect(ClipboardMonitor.sensitivityMarker(in: [.string, concealed]) == concealed)
        #expect(ClipboardMonitor.sensitivityMarker(in: [.init("com.agilebits.onepassword")]) != nil, "legacy 1Password marker")
    }

    @Test func contentAlreadyThereAtLaunchIsNotReported() {
        let pasteboard = FakePasteboard()
        pasteboard.write([.string], text: "from before launch")
        let monitor = ClipboardMonitor(source: pasteboard, frontmostBundleID: { nil }) { _ in }
        #expect(monitor.tick() == nil)
        #expect(pasteboard.reads == 0)
    }

    @Test func plainTextIsCapturedOncePerChange() {
        let pasteboard = FakePasteboard()
        var delivered: [ClipboardEvent] = []
        let monitor = ClipboardMonitor(source: pasteboard, frontmostBundleID: { nil }) { delivered.append($0) }
        #expect(monitor.tick() == nil, "no change")
        pasteboard.write([.string], text: "hello")
        #expect(monitor.tick() == .captured(text: "hello", changeCount: 1))
        #expect(monitor.tick() == nil, "same changeCount is not reported twice")
        #expect(delivered == [.captured(text: "hello", changeCount: 1)])
    }

    @Test(arguments: [concealed, transient])
    func sensitiveContentIsSkippedWithoutBeingRead(_ marker: NSPasteboard.PasteboardType) {
        let pasteboard = FakePasteboard()
        let monitor = ClipboardMonitor(source: pasteboard, frontmostBundleID: { nil }) { _ in }
        pasteboard.write([.string, marker], text: "secret")
        #expect(monitor.tick() == .skippedSensitive(marker: marker.rawValue, changeCount: 1))
        #expect(pasteboard.reads == 0, "a concealed item is never read, not merely dropped")
    }

    @Test func neitherTextNorImageIsSkipped() {
        let pasteboard = FakePasteboard()
        let monitor = ClipboardMonitor(source: pasteboard, frontmostBundleID: { nil }) { _ in }
        pasteboard.write([.pdf], text: nil)
        #expect(monitor.tick() == .skippedNonText(changeCount: 1))
        #expect(pasteboard.reads == 0)
    }

    @Test func imageIsCapturedPreferringPNG() {
        let pasteboard = FakePasteboard()
        let monitor = ClipboardMonitor(source: pasteboard, frontmostBundleID: { nil }) { _ in }
        pasteboard.imageData = [.png: Data([1, 2]), .tiff: Data([3])]
        pasteboard.write([.tiff, .png], text: nil)
        #expect(monitor.tick() == .capturedImage(data: Data([1, 2]), type: .png, changeCount: 1))
    }

    @Test func textWinsOverAnImage() {
        let pasteboard = FakePasteboard()
        let monitor = ClipboardMonitor(source: pasteboard, frontmostBundleID: { nil }) { _ in }
        pasteboard.imageData = [.tiff: Data([3])]
        pasteboard.write([.string, .tiff], text: "cell")
        #expect(monitor.tick() == .captured(text: "cell", changeCount: 1))
    }

    /// Finder puts the file name as text and the icon as TIFF next to the
    /// file URL; neither is what the user copied.
    @Test func fileCopiesAreSkippedWithoutBeingRead() {
        let pasteboard = FakePasteboard()
        let monitor = ClipboardMonitor(source: pasteboard, frontmostBundleID: { nil }) { _ in }
        pasteboard.write([.fileURL, .string, .tiff], text: "report.pdf")
        #expect(monitor.tick() == .skippedNonText(changeCount: 1))
        #expect(pasteboard.reads == 0)
    }

    @Test func copiesFromAPasswordManagerAreNotRead() {
        let pasteboard = FakePasteboard()
        let monitor = ClipboardMonitor(source: pasteboard, frontmostBundleID: { "com.bitwarden.desktop" }) { _ in }
        pasteboard.write([.string], text: "hunter2")
        #expect(monitor.tick() == .skippedSourceApp(bundleID: "com.bitwarden.desktop", changeCount: 1))
        #expect(pasteboard.reads == 0)
    }

    @Test func ownWriteIsIgnored() {
        let pasteboard = FakePasteboard()
        let monitor = ClipboardMonitor(source: pasteboard, frontmostBundleID: { nil }) { _ in }
        pasteboard.write([.string], text: "copied back")
        monitor.ignoreCurrentContents()
        #expect(monitor.tick() == nil)
        #expect(pasteboard.reads == 0)
    }

    /// The production policy never reads unless the user chose "Allow", so
    /// a background poll can never be what raises the privacy alert.
    @Test(arguments: [NSPasteboard.AccessBehavior.default, .ask, .alwaysDeny])
    func withoutAlwaysAllowNothingIsRead(_ behavior: NSPasteboard.AccessBehavior) {
        let pasteboard = FakePasteboard()
        pasteboard.accessBehavior = behavior
        let monitor = ClipboardMonitor(source: pasteboard, frontmostBundleID: { nil }) { _ in }
        pasteboard.write([.string], text: "x")
        #expect(monitor.tick() == .permissionRequired(behavior: behavior, changeCount: 1))
        #expect(pasteboard.reads == 0)
    }

    @Test func refusedReadIsReportedAsPermissionRequired() {
        let pasteboard = FakePasteboard()
        pasteboard.accessBehavior = .alwaysDeny
        let monitor = ClipboardMonitor(source: pasteboard, policy: .always, frontmostBundleID: { nil }) { _ in }
        pasteboard.write([.string], text: nil)
        #expect(monitor.tick() == .permissionRequired(behavior: .alwaysDeny, changeCount: 1))
    }

    @Test func changeDuringTheReadIsDropped() {
        let pasteboard = FakePasteboard()
        let monitor = ClipboardMonitor(source: pasteboard, frontmostBundleID: { nil }) { _ in }
        pasteboard.changesDuringRead = true
        pasteboard.write([.string], text: "racy")
        #expect(monitor.tick() == nil, "the read belongs to neither generation")
    }

    @Test func describeNeverContainsTheText() {
        let description = ClipboardMonitor.describe(.captured(text: "hunter2", changeCount: 1))
        #expect(!description.contains("hunter2"))
        #expect(description == "captured(len=7)")
    }

    @Test func privateNSPasteboardRoundTrip() {
        let pasteboard = NSPasteboard(name: .init("umbarTests.clipboard.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let monitor = ClipboardMonitor(source: pasteboard, frontmostBundleID: { nil }) { _ in }
        #expect(pasteboard.accessBehavior == .alwaysAllow, "private pasteboards are not privacy-gated")

        let item = NSPasteboardItem()
        item.setString("pw", forType: .string)
        item.setData(Data(), forType: concealed)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        #expect(monitor.tick() == .skippedSensitive(marker: concealed.rawValue, changeCount: pasteboard.changeCount),
                "the marker type survives writeObjects")

        pasteboard.clearContents()
        pasteboard.setString("plain", forType: .string)
        #expect(monitor.tick() == .captured(text: "plain", changeCount: pasteboard.changeCount))
    }
}
