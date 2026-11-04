//
//  DripRenderer.swift
//  boringNotch
//
//  Debug-only frames of the liquid drip, for MotionFrameRenderer
//  (`-UmbarRenderMotion <dir>`, or `-UmbarRenderMotionOnly drip`), cropped
//  to the island's bottom edge. The real closed island; DripFixture stands
//  in for the pointer, HoverFixture for the hint's lean.
//
//    drip-approach-<notch>-<ground>-<ms>.png  the pointer coming up under
//                       the island over half a second (ground: light, dark)
//    drip-slide-<notch>-<ground>-<ms>.png     the pointer sliding right under it
//    drip-flick-<notch>-<ground>-<ms>.png     the pointer flicked away: pinch,
//                       fall and ripple
//    drip-retract-<notch>-<ground>-<ms>.png   the pointer backing off slowly
//    drip-open-<notch>-<ground>-<ms>.png      the panel opening over a full drip
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum DripRenderer {
    static let times: [Double] = [0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8]

    static func renderMotion(to out: URL) {
        let music = MusicManager.shared
        music.isPlaying = false
        music.isPlayerIdle = true
        let notches = [CGSize(width: 200, height: 32), CGSize(width: 254, height: 45)]
        let grounds: [(String, Color)] = [("light", Color(white: 0.92)), ("dark", Color(white: 0.12))]
        for notch in notches {
            for (ground, color) in grounds {
                render(notch: notch, ground: ground, color: color, out: out)
            }
        }
        DripFixture.shared.reading = nil
        MotionFrameRenderer.HoverFixture.shared.approach = 0
    }

    private static func render(notch: CGSize, ground: String, color: Color, out: URL) {
        let tag = "\(Int(notch.width))x\(Int(notch.height))"
        let vm = MotionFrameRenderer.fixtureViewModel(notch: notch)
        vm.notchSize = notch
        let height: CGFloat = windowSize.height
        let root = ContentView()
            .environmentObject(vm)
            .frame(width: windowSize.width, height: height, alignment: .top)
            .background(color)
        let session = MotionFrameRenderer.Session(root, size: NSSize(width: windowSize.width, height: height))
        // Deep enough for a drop to fall the whole way.
        let crop = NSRect(x: windowSize.width / 2 - 160, y: 0, width: 320,
                          height: notch.height + DripArt.height - DripArt.top + 8)
        let fixture = DripFixture.shared
        let hover = MotionFrameRenderer.HoverFixture.shared
        func name(_ scene: String) -> (Int) -> URL {
            { out.appendingPathComponent("drip-\(scene)-\(tag)-\(ground)-\($0).png") }
        }
        func reset() {
            fixture.reading = nil
            hover.approach = 0
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        }

        // Coming up from 48 pt below to 10 pt below in 0.5 s, the hint
        // leaning with it as the real monitor would make it.
        drive(session, crop: crop, name: name("approach")) { t in
            let p = min(t / 0.5, 1)
            hover.approach = (p * 6).rounded() / 6 * 0.5
            return NotchDripReading(pull: p, x: 0.5)
        }
        // Full, then sliding from 0.3 to 0.75 across the edge in 0.25 s.
        fixture.reading = NotchDripReading(pull: 1, x: 0.3)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        drive(session, crop: crop, name: name("slide")) { t in
            NotchDripReading(pull: 1, x: 0.3 + 0.45 * min(t / 0.25, 1))
        }
        reset()
        // Full, then gone in one move.
        fixture.reading = NotchDripReading(pull: 1, x: 0.5)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        drive(session, crop: crop, name: name("flick")) { _ in nil }
        reset()
        // Full, then backing off over 1 s.
        fixture.reading = NotchDripReading(pull: 1, x: 0.5)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        drive(session, crop: crop, name: name("retract")) { t in
            let pull = 1 - t
            return pull > 0 ? NotchDripReading(pull: pull, x: 0.5) : nil
        }
        reset()
        // Full, and the panel opens over it.
        fixture.reading = NotchDripReading(pull: 1, x: 0.5)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let openCrop = NSRect(x: 0, y: 0, width: windowSize.width, height: windowSize.height)
        var opened = false
        drive(session, crop: openCrop, name: name("open")) { _ in
            if !opened {
                opened = true
                withAnimation(UmbarMotion.open()) { vm.open() }
            }
            return nil
        }
        session.close()
    }

    /// Feeds `reading(t)` every 16 ms, as mouse events would, and captures
    /// `crop` at each of `times`.
    private static func drive(_ session: MotionFrameRenderer.Session, crop: NSRect,
                              name: (Int) -> URL, reading: (Double) -> NotchDripReading?) {
        let start = Date()
        var frames = times[...]
        var last: NotchDripReading?? = .none
        while let next = frames.first {
            let t = Date().timeIntervalSince(start)
            let value = reading(t)
            if last == nil || last! != value {
                DripFixture.shared.reading = value
                last = .some(value)
            }
            if t >= next {
                capture(session.host, crop: crop, to: name(Int(next * 1000)))
                frames = frames.dropFirst()
                continue
            }
            RunLoop.main.run(until: Date().addingTimeInterval(min(0.016, next - t)))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    /// `crop` in the host's top-left space.
    private static func capture(_ host: NSView, crop: NSRect, to url: URL) {
        let flipped = host.isFlipped ? crop : NSRect(x: crop.minX, y: host.bounds.height - crop.maxY,
                                                      width: crop.width, height: crop.height)
        guard let rep = host.bitmapImageRepForCachingDisplay(in: flipped) else { return }
        host.cacheDisplay(in: flipped, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
