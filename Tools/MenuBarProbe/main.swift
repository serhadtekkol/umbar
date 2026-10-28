//
//  MenuBarProbe — spike C4 harness (card #107).
//
//  Question: can umbar tell, without Screen Recording and possibly without
//  Accessibility, whether its closed-island ears would cover the frontmost
//  app's menu titles or a status item? Built as an LSUIElement .app (see
//  build.sh) and launched with `open`, so TCC judges the probe itself, not
//  the shell. Compiled together with
//  boringNotch/private/MenuBarGeometry/MenuBarCollision.swift so the
//  decision it prints is the one the app would make.
//
//  Usage: open -n -W MenuBarProbe.app --args <mode> <out> [...]
//    screens <out>                          NSScreen geometry + derived ears
//    windows <out>                          CGWindowList view of the menu bar strip
//    ax <out>                               what Accessibility returns (or fails with)
//    statusitems <out> <count> <length> <hold-s>
//                                           add the probe's own blank status
//                                           items, record where macOS put them
//    bench <out> <iterations>               cost of each query
//    watch <out> <seconds>                  passive change notifications
//
//  Output is one JSON object per line. Window titles are never recorded
//  except on menu bar layers (24/25), where they are system strings such as
//  "Menubar"; for every other window only `hasName` is kept.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Output

final class Out {
    private let handle: FileHandle
    private let start = Date()

    init(path: String) {
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
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        handle.write(data)
        handle.write(Data("\n".utf8))
    }
}

func rectJSON(_ r: CGRect?) -> Any {
    guard let r else { return NSNull() }
    return ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height]
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: MenuBarProbe <mode> <out> [...]\n".utf8))
    exit(64)
}
let mode = args[1]
let out = Out(path: args[2])

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()

func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func permissions() -> [String: Any] {
    // Preflight only: neither call prompts. Request* variants are never used.
    ["screenRecording": CGPreflightScreenCaptureAccess(), "accessibility": AXIsProcessTrusted()]
}

// MARK: - screens

func geometry(of screen: NSScreen) -> NotchGeometry? {
    NotchGeometry.make(
        screenFrame: screen.frame,
        primaryScreenHeight: NSScreen.screens.first?.frame.height ?? screen.frame.height,
        auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
        auxiliaryTopRightArea: screen.auxiliaryTopRightArea,
        safeAreaTop: screen.safeAreaInsets.top)
}

func runScreens() {
    for (i, s) in NSScreen.screens.enumerated() {
        let g = geometry(of: s)
        out.emit("screen", [
            "index": i, "name": s.localizedName,
            "frame": rectJSON(s.frame), "visibleFrame": rectJSON(s.visibleFrame),
            "menuBarThickness": s.frame.maxY - s.visibleFrame.maxY,
            "safeAreaTop": s.safeAreaInsets.top,
            "auxLeft": rectJSON(s.auxiliaryTopLeftArea), "auxRight": rectJSON(s.auxiliaryTopRightArea),
            "backingScale": s.backingScaleFactor,
            "notchCG": rectJSON(g?.notch), "leftEarCG": rectJSON(g?.leftEar), "rightEarCG": rectJSON(g?.rightEar),
            "systemMenuBarThickness": NSStatusBar.system.thickness,
        ])
    }
}

// MARK: - windows

struct WindowRow {
    let layer: Int, pid: Int32, owner: String, name: String?, bounds: CGRect, onscreen: Bool
}

func windowRows(_ options: CGWindowListOption) -> [WindowRow] {
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { w in
        guard let b = w[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: b) else { return nil }
        return WindowRow(layer: w[kCGWindowLayer as String] as? Int ?? 0,
                         pid: w[kCGWindowOwnerPID as String] as? Int32 ?? 0,
                         owner: w[kCGWindowOwnerName as String] as? String ?? "?",
                         name: w[kCGWindowName as String] as? String,
                         bounds: rect,
                         onscreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }
}

func runWindows() {
    out.emit("permissions", permissions())
    let all = windowRows([.optionAll])
    let named = all.filter { $0.name != nil }
    out.emit("summary", [
        "total": all.count, "withName": named.count,
        "withNameOwners": Array(Set(named.map(\.owner))).sorted(),
        "layers": Dictionary(grouping: all, by: \.layer).mapValues(\.count).map { "\($0.key):\($0.value)" }.sorted(),
    ])
    // Anything that sits in the top 60 pt of a display and is not a
    // full-screen backdrop: where status item windows would be, if any.
    let screenH = NSScreen.screens.map(\.frame.height).max() ?? 0
    for w in all where w.bounds.minY < 60 && w.bounds.height < screenH * 0.5 {
        out.emit("stripWindow", [
            "layer": w.layer, "owner": w.owner, "pid": w.pid, "onscreen": w.onscreen,
            "hasName": w.name != nil,
            "name": (w.layer == 24 || w.layer == 25) ? ((w.name as Any?) ?? NSNull()) : NSNull(),
            "bounds": rectJSON(w.bounds),
        ])
    }
}

// MARK: - ax

func axErrorName(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .apiDisabled: return "apiDisabled(-25211)"
    case .cannotComplete: return "cannotComplete(-25204)"
    case .noValue: return "noValue(-25212)"
    case .attributeUnsupported: return "attributeUnsupported(-25205)"
    case .notImplemented: return "notImplemented(-25208)"
    case .invalidUIElement: return "invalidUIElement(-25202)"
    default: return "AXError(\(e.rawValue))"
    }
}

func axFrame(_ el: AXUIElement) -> CGRect? {
    var p: CFTypeRef?, s: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
          AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
          let pv = p, let sv = s else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &point)
    AXValueGetValue(sv as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

/// Children frames of `attribute` (AXMenuBar / AXExtrasMenuBar) of an app.
/// Returns the AX error of the first failing call so a missing grant is
/// recorded precisely rather than as "no items".
func axBarFrames(pid: pid_t, attribute: String) -> (error: String, frames: [CGRect], titles: Int) {
    let el = AXUIElementCreateApplication(pid)
    // A hung target app must not stall the caller: bound every AX call.
    AXUIElementSetMessagingTimeout(el, 0.25)
    var bar: CFTypeRef?
    let e1 = AXUIElementCopyAttributeValue(el, attribute as CFString, &bar)
    guard e1 == .success, let barEl = bar else { return (axErrorName(e1), [], 0) }
    var kids: CFTypeRef?
    let e2 = AXUIElementCopyAttributeValue(barEl as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
    guard e2 == .success, let children = kids as? [AXUIElement] else { return (axErrorName(e2), [], 0) }
    let frames = children.compactMap(axFrame)
    return ("success", frames, children.count)
}

func runAX() {
    out.emit("permissions", permissions())
    let front = NSWorkspace.shared.frontmostApplication
    out.emit("frontmost", ["bundleID": front?.bundleIdentifier ?? NSNull(), "pid": front?.processIdentifier ?? 0])
    if let pid = front?.processIdentifier {
        let r = axBarFrames(pid: pid, attribute: kAXMenuBarAttribute)
        out.emit("axMenuBar", ["error": r.error, "children": r.titles, "frames": r.frames.map(rectJSON)])
    }
    for bid in ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.MenuBarAgent"] {
        for ra in NSRunningApplication.runningApplications(withBundleIdentifier: bid) {
            let r = axBarFrames(pid: ra.processIdentifier, attribute: kAXExtrasMenuBarAttribute)
            out.emit("axExtras", ["bundleID": bid, "error": r.error, "children": r.titles, "frames": r.frames.map(rectJSON)])
        }
    }
    // Hit-test at the centre of each ear: what the system-wide element says.
    let sys = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(sys, 0.25)
    for s in NSScreen.screens {
        guard let g = geometry(of: s) else { continue }
        for (side, ear) in [("left", g.leftEar), ("right", g.rightEar)] {
            var hit: AXUIElement?
            let e = AXUIElementCopyElementAtPosition(sys, Float(ear.midX), Float(ear.midY), &hit)
            var role: CFTypeRef?
            if let hit { AXUIElementCopyAttributeValue(hit, kAXRoleAttribute as CFString, &role) }
            out.emit("axHitTest", ["side": side, "error": axErrorName(e), "role": (role as? String) ?? NSNull()])
        }
    }
}

// MARK: - statusitems

func runStatusItems(count: Int, length: CGFloat, hold: TimeInterval) {
    out.emit("permissions", permissions())
    let me = ProcessInfo.processInfo.processIdentifier
    let agentBefore = windowRows([.optionAll]).filter { $0.owner == "MenuBarAgent" }.map(\.bounds)
    var items: [NSStatusItem] = []
    for _ in 0..<count {
        let item = NSStatusBar.system.statusItem(withLength: length)
        // Blank on purpose: nothing to read, nothing to click.
        item.button?.title = ""
        items.append(item)
    }
    pump(1.5) // let the status bar lay out (and, on 27, the agent host it)
    for (i, item) in items.enumerated() {
        let w = item.button?.window
        out.emit("item", [
            "index": i, "isVisible": item.isVisible,
            "windowFrame": rectJSON(w?.frame),
            "windowNumber": w?.windowNumber ?? -1,
            "windowOnActiveSpace": w?.isOnActiveSpace ?? false,
            "windowScreen": w?.screen?.localizedName ?? NSNull(),
            "windowOcclusionVisible": w.map { $0.occlusionState.contains(.visible) } ?? false,
        ])
    }
    let mine = windowRows([.optionAll]).filter { $0.pid == me }
    out.emit("ownWindowsInCGWindowList", ["count": mine.count, "rows": mine.map { ["layer": $0.layer, "bounds": rectJSON($0.bounds), "onscreen": $0.onscreen] }])
    let agentAfter = windowRows([.optionAll]).filter { $0.owner == "MenuBarAgent" }.map(\.bounds)
    out.emit("menuBarAgentWindows", ["before": agentBefore.map(rectJSON), "after": agentAfter.map(rectJSON)])
    // Convert our own item frames to CG space and run the shipped decision on
    // them: an end-to-end check of the coordinate conversion.
    if let s = NSScreen.screens.first(where: { geometry(of: $0) != nil }), let g = geometry(of: s) {
        let primaryH = NSScreen.screens[0].frame.height
        let cg = items.compactMap { $0.button?.window?.frame }.map {
            CGRect(x: $0.minX, y: primaryH - $0.maxY, width: $0.width, height: $0.height)
        }
        out.emit("decisionOnOwnItems", [
            "itemsCG": cg.map(rectJSON),
            "collisions": MenuBarCollision.collisions(geometry: g, occupied: cg).map(rectJSON),
            "placement": "\(MenuBarCollision.placement(geometry: g, occupancy: .init(occupied: cg, isComplete: true), policy: .assumeOccupied))",
        ])
    }
    pump(max(0, hold - 1.5))
    for item in items { NSStatusBar.system.removeStatusItem(item) }
    pump(0.3)
    out.emit("removed", ["count": items.count])
}

// MARK: - bench

func measure(_ n: Int, _ body: () -> Void) -> [String: Double] {
    var samples: [Double] = []
    samples.reserveCapacity(n)
    for _ in 0..<n {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
    }
    samples.sort()
    func q(_ p: Double) -> Double { samples[min(samples.count - 1, Int(Double(samples.count) * p))] }
    return ["p50us": q(0.5), "p95us": q(0.95), "maxus": samples.last ?? 0]
}

func runBench(_ n: Int) {
    out.emit("permissions", permissions())
    var sink = 0
    out.emit("bench", ["what": "NSScreen.screens+notchGeometry", "n": n, "r": measure(n) {
        sink &+= NSScreen.screens.compactMap(geometry).count
    }])
    out.emit("bench", ["what": "CGWindowListCopyWindowInfo(onScreenOnly)", "n": n, "r": measure(n) {
        sink &+= (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [Any])?.count ?? 0
    }])
    out.emit("bench", ["what": "AXIsProcessTrusted", "n": n, "r": measure(n) { sink &+= AXIsProcessTrusted() ? 1 : 0 }])
    if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
        out.emit("bench", ["what": "AX menubar read (frontmost)", "n": n, "r": measure(n) {
            sink &+= axBarFrames(pid: pid, attribute: kAXMenuBarAttribute).frames.count
        }])
    }
    if let g = NSScreen.screens.compactMap(geometry).first {
        let rects = (0..<40).map { CGRect(x: CGFloat($0) * 30, y: 0, width: 28, height: 32) }
        out.emit("bench", ["what": "MenuBarCollision.placement(40 rects)", "n": n, "r": measure(n) {
            sink &+= MenuBarCollision.placement(geometry: g, occupancy: .init(occupied: rects, isComplete: true), policy: .assumeOccupied) == .ears ? 1 : 0
        }])
    }
    out.emit("sink", ["v": sink])
}

// MARK: - watch

func runWatch(_ seconds: TimeInterval) {
    let ws = NSWorkspace.shared.notificationCenter
    var tokens: [NSObjectProtocol] = []
    for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                 NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
        tokens.append(ws.addObserver(forName: name, object: nil, queue: .main) { n in
            let ra = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            out.emit("notification", ["name": n.name.rawValue, "bundleID": ra?.bundleIdentifier ?? NSNull()])
        })
    }
    tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
        out.emit("notification", ["name": "didChangeScreenParameters", "screens": NSScreen.screens.count])
    })
    // menuBarVisible flips when the bar auto-hides or a full-screen space
    // hides it; there is no notification for it, so record whether KVO-free
    // sampling would be needed.
    out.emit("watchStart", ["menuBarVisible": NSMenu.menuBarVisible(), "seconds": seconds])
    pump(seconds)
    out.emit("watchEnd", ["menuBarVisible": NSMenu.menuBarVisible()])
    tokens.forEach { ws.removeObserver($0); NotificationCenter.default.removeObserver($0) }
}

// MARK: - main

switch mode {
case "screens": runScreens()
case "windows": runWindows()
case "ax": runAX()
case "statusitems":
    runStatusItems(count: Int(args[safe: 3] ?? "") ?? 3, length: CGFloat(Double(args[safe: 4] ?? "") ?? 24),
                   hold: Double(args[safe: 5] ?? "") ?? 2)
case "bench": runBench(Int(args[safe: 3] ?? "") ?? 200)
case "watch": runWatch(Double(args[safe: 3] ?? "") ?? 10)
default:
    out.emit("error", ["message": "unknown mode \(mode)"])
    exit(64)
}
exit(0)

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
