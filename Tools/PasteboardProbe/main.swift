//
//  PasteboardProbe — spike A2 harness (card #3).
//
//  Built as a tiny LSUIElement .app (see build.sh) and launched through
//  `open`, so that launchd, not the calling shell, is its parent and the
//  pasteboard privacy machinery attributes every access to this bundle
//  rather than to Terminal/sshd. Compiled together with
//  boringNotch/private/Clipboard/ClipboardMonitor.swift so the harness
//  exercises the exact code the app ships.
//
//  Usage (via `open -n -W PasteboardProbe.app --args <mode> ...`). Append
//  `-EnablePasteboardPrivacyDeveloperPreview YES` to run with pasteboard
//  privacy enforced; it lands in NSArgumentDomain, so nothing persists.
//    selftest <out>                 deterministic checks, no general pasteboard
//    behavior <out>                 log accessBehavior only
//    poll <out> <seconds>           changeCount only
//    types <out> <seconds>          changeCount + `types` on every change
//    metadata <out>                 detectMetadata / detectPatterns once
//    read <out>                     one string(forType:) on the general pasteboard
//    monitor <out> <seconds> <onlyWhenAlwaysAllowed|always> [token]
//    cpu <out> <seconds> <interval-ms>   ClipboardMonitor idle cost via getrusage
//    write <out> <plain|concealed|transient|image> <token>
//
//  Output is one JSON object per line. User clipboard content is never
//  written to the output: reads record only length and a match flag
//  against the token the harness itself wrote.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Output

final class Out: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private let start = Date()

    init(path: String) {
        // Append, so several short-lived launches can share one log.
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
    }

    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        var obj = fields
        obj["event"] = event
        obj["t"] = String(format: "%.3f", Date().timeIntervalSince(start))
        obj["pid"] = ProcessInfo.processInfo.processIdentifier
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        lock.lock(); defer { lock.unlock() }
        handle.write(data)
        handle.write(Data("\n".utf8))
    }
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: PasteboardProbe <mode> <out> [...]\n".utf8))
    exit(64)
}
let mode = args[1]
let out = Out(path: args[2])
let general = NSPasteboard.general

func behaviorName(_ b: NSPasteboard.AccessBehavior) -> String {
    switch b {
    case .default: return "default"
    case .ask: return "ask"
    case .alwaysAllow: return "alwaysAllow"
    case .alwaysDeny: return "alwaysDeny"
    @unknown default: return "unknown(\(b.rawValue))"
    }
}

/// Owner names and layers of on-screen windows belonging to other
/// processes. Titles are not read (they need Screen Recording and may hold
/// user data); owner + layer is enough to see a system alert appear.
func foreignWindows() -> [String] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
    let me = ProcessInfo.processInfo.processIdentifier
    return list.compactMap { w in
        guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me else { return nil }
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        return "\(owner)#\(pid)@\(layer)"
    }
}

func snapshot(_ label: String) -> Set<String> {
    let windows = Set(foreignWindows())
    out.emit("snapshot", ["label": label, "behavior": behaviorName(general.accessBehavior), "changeCount": general.changeCount])
    return windows
}

func diffWindows(_ before: Set<String>, label: String) {
    let after = Set(foreignWindows())
    out.emit("windowsDiff", ["label": label, "appeared": Array(after.subtracting(before)).sorted(), "disappeared": Array(before.subtracting(after)).sorted()])
}

// MARK: - Modes

func runPoll(seconds: Double, readTypes: Bool) {
    let before = snapshot("before")
    var last = general.changeCount
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        let c = general.changeCount
        if c != last {
            last = c
            var fields: [String: Any] = ["changeCount": c]
            if readTypes {
                fields["types"] = (general.types ?? []).map(\.rawValue)
                fields["itemTypes"] = (general.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
            }
            fields["behavior"] = behaviorName(general.accessBehavior)
            out.emit("change", fields)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    diffWindows(before, label: "after-poll")
    _ = snapshot("after")
}

@MainActor func runMetadata() async {
    let before = snapshot("before")
    do {
        let md = try await general.detectedMetadata(for: [\.contentType])
        out.emit("detectedMetadata", ["contentType": md.contentType?.identifier ?? "nil"])
    } catch {
        out.emit("detectedMetadataError", ["error": String(describing: error)])
    }
    do {
        let p = try await general.detectedPatterns(for: [\.probableWebURL, \.number, \.emailAddresses, \.links])
        out.emit("detectedPatterns", ["patterns": p.map { "\($0)" }.sorted()])
    } catch {
        out.emit("detectedPatternsError", ["error": String(describing: error)])
    }
    diffWindows(before, label: "after-detect")
    _ = snapshot("after")
}

func runRead(token: String?) {
    let before = snapshot("before")
    out.emit("readTypes", ["types": (general.types ?? []).map(\.rawValue)])
    let done = DispatchSemaphore(value: 0)
    let started = Date()
    let result = Box<String?>(nil)
    let completed = Box(false)
    Thread.detachNewThread {
        result.value = general.string(forType: .string)
        completed.value = true
        done.signal()
    }
    // Poll for an alert while the read is in flight; a read that blocks on
    // a user decision would otherwise look identical to a slow read.
    var sawWindows: [String] = []
    for _ in 0..<40 {
        if done.wait(timeout: .now() + 0.5) == .success { break }
        let appeared = Set(foreignWindows()).subtracting(before)
        if !appeared.isEmpty { sawWindows = Array(appeared).sorted() }
    }
    let finished = completed.value
    out.emit("readResult", [
        "returned": finished,
        "elapsedMs": Int(Date().timeIntervalSince(started) * 1000),
        "isNil": result.value == nil,
        "length": result.value?.count ?? -1,
        "matchesToken": token.map { result.value == $0 } ?? NSNull(),
        "windowsWhileBlocked": sawWindows,
    ])
    diffWindows(before, label: "after-read")
    _ = snapshot("after")
}

final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

func runWrite(kind: String, token: String) {
    let item = NSPasteboardItem()
    switch kind {
    case "plain":
        item.setString(token, forType: .string)
    case "concealed":
        item.setString(token, forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
    case "transient":
        item.setString(token, forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
    case "image":
        let img = NSImage(size: NSSize(width: 4, height: 4))
        img.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
        item.setData(img.tiffRepresentation ?? Data(), forType: .tiff)
    default:
        out.emit("error", ["message": "unknown kind \(kind)"]); return
    }
    general.clearContents()
    let ok = general.writeObjects([item])
    out.emit("wrote", ["kind": kind, "ok": ok, "changeCount": general.changeCount, "behavior": behaviorName(general.accessBehavior)])
}

// The monitor's timer fires on the main queue, so waits here must yield
// the main actor (Task.sleep) rather than spin a nested run loop, which
// does not drain the main queue while a main-queue block is executing.
@MainActor func runMonitor(seconds: Double, policy: ClipboardMonitor.ReadPolicy, token: String?) async {
    let before = snapshot("before")
    let monitor = ClipboardMonitor(policy: policy) { event in
        var fields: [String: Any] = ["desc": ClipboardMonitor.describe(event)]
        if case .captured(let text, _) = event, let token { fields["matchesToken"] = text == token }
        out.emit("monitorEvent", fields)
    }
    monitor.start()
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline { try? await Task.sleep(for: .milliseconds(250)) }
    monitor.stop()
    diffWindows(before, label: "after-monitor")
    _ = snapshot("after")
}

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6
        + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
}

@MainActor func runCPU(seconds: Double, intervalMs: Int) async {
    let monitor = ClipboardMonitor(interval: .milliseconds(intervalMs)) { _ in }
    // Let launch work settle so it is not billed to the monitor.
    try? await Task.sleep(for: .seconds(3))
    let c0 = cpuSeconds(), w0 = Date()
    monitor.start()
    while Date().timeIntervalSince(w0) < seconds { try? await Task.sleep(for: .seconds(1)) }
    monitor.stop()
    let c1 = cpuSeconds(), wall = Date().timeIntervalSince(w0)
    out.emit("cpu", ["intervalMs": intervalMs, "wallS": wall, "cpuS": c1 - c0, "cpuPercent": (c1 - c0) / wall * 100])
}

// MARK: - Self test (no general pasteboard involved)

final class FakeSource: PasteboardSource {
    var changeCount = 0
    var types: [NSPasteboard.PasteboardType]? = []
    var accessBehavior: NSPasteboard.AccessBehavior = .alwaysAllow
    var text: String?
    var reads = 0
    var bumpOnRead = false
    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        reads += 1
        if bumpOnRead { changeCount += 1 }
        return text
    }
    func data(forType dataType: NSPasteboard.PasteboardType) -> Data? { reads += 1; return nil }
    func set(_ t: [NSPasteboard.PasteboardType], text: String?) { changeCount += 1; types = t; self.text = text }
}

@MainActor func runSelfTest() -> Bool {
    var failures = 0
    func check(_ name: String, _ cond: Bool) {
        out.emit("test", ["name": name, "pass": cond])
        if !cond { failures += 1 }
    }
    let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    check("marker: none for plain text", ClipboardMonitor.sensitivityMarker(in: [.string, .rtf]) == nil)
    check("marker: concealed", ClipboardMonitor.sensitivityMarker(in: [.string, concealed]) == concealed)
    check("marker: legacy 1Password", ClipboardMonitor.sensitivityMarker(in: [.init("com.agilebits.onepassword")]) != nil)
    check("marker: empty", ClipboardMonitor.sensitivityMarker(in: []) == nil)

    let f = FakeSource()
    let m = ClipboardMonitor(source: f) { _ in }
    check("no change -> nil", m.tick() == nil)

    f.set([.string], text: "hello")
    check("plain -> captured", m.tick() == .captured(text: "hello", changeCount: 1))
    check("same count twice -> nil", m.tick() == nil)

    f.reads = 0
    f.set([.string, concealed], text: "secret")
    check("concealed -> skipped", m.tick() == .skippedSensitive(marker: concealed.rawValue, changeCount: 2))
    check("concealed -> contents never read", f.reads == 0)

    f.set([.string, transient], text: "otp")
    check("transient -> skipped", m.tick() == .skippedSensitive(marker: transient.rawValue, changeCount: 3))

    f.set([.pdf], text: nil)
    check("neither text nor image -> nonText", m.tick() == .skippedNonText(changeCount: 4))

    for b in [NSPasteboard.AccessBehavior.default, .ask, .alwaysDeny] {
        f.reads = 0; f.accessBehavior = b
        f.set([.string], text: "x")
        check("behavior \(behaviorName(b)) -> permissionRequired, no read",
              m.tick() == .permissionRequired(behavior: b, changeCount: f.changeCount) && f.reads == 0)
    }

    let always = ClipboardMonitor(source: f, policy: .always) { _ in }
    f.accessBehavior = .alwaysDeny
    f.set([.string], text: nil)
    check("policy always + nil read -> permissionRequired", always.tick() == .permissionRequired(behavior: .alwaysDeny, changeCount: f.changeCount))

    f.accessBehavior = .alwaysAllow
    f.bumpOnRead = true
    f.set([.string], text: "racy")
    check("change during read -> dropped", m.tick() == nil)
    f.bumpOnRead = false

    // Real NSPasteboard round-trip on a private pasteboard: proves the
    // NSPasteboard conformance and that marker types survive writeObjects.
    let pb = NSPasteboard(name: .init("umbar.spike.\(UUID().uuidString)"))
    let real = ClipboardMonitor(source: pb) { _ in }
    let item = NSPasteboardItem()
    item.setString("pw", forType: .string)
    item.setData(Data(), forType: concealed)
    pb.clearContents(); pb.writeObjects([item])
    check("private pasteboard behavior is alwaysAllow", pb.accessBehavior == .alwaysAllow)
    if case .skippedSensitive = real.tick() { check("private pasteboard concealed -> skipped", true) } else { check("private pasteboard concealed -> skipped", false) }
    pb.clearContents(); pb.setString("plain", forType: .string)
    check("private pasteboard plain -> captured", real.tick() == .captured(text: "plain", changeCount: pb.changeCount))
    pb.releaseGlobally()

    out.emit("selftestSummary", ["failures": failures])
    return failures == 0
}

// MARK: - Entry

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            var code: Int32 = 0
            out.emit("start", ["mode": mode, "bundle": Bundle.main.bundleIdentifier ?? "nil", "os": ProcessInfo.processInfo.operatingSystemVersionString])
            switch mode {
            case "selftest": code = runSelfTest() ? 0 : 1
            case "behavior": _ = snapshot("only")
            case "poll": runPoll(seconds: Double(args[3]) ?? 10, readTypes: false)
            case "types": runPoll(seconds: Double(args[3]) ?? 10, readTypes: true)
            case "metadata": await runMetadata()
            case "read": runRead(token: args.count > 3 ? args[3] : nil)
            case "monitor":
                let policy: ClipboardMonitor.ReadPolicy = (args.count > 4 && args[4] == "always") ? .always : .onlyWhenAlwaysAllowed
                await runMonitor(seconds: Double(args[3]) ?? 10, policy: policy, token: args.count > 5 ? args[5] : nil)
            case "cpu": await runCPU(seconds: Double(args[3]) ?? 60, intervalMs: Int(args.count > 4 ? args[4] : "500") ?? 500)
            case "write": runWrite(kind: args[3], token: args[4])
            default: out.emit("error", ["message": "unknown mode \(mode)"]); code = 64
            }
            out.emit("end", ["code": code])
            exit(code)
        }
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
