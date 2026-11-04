//
//  EdgeGlowRenderer.swift
//  boringNotch
//
//  Debug-only fixtures for the edge glow, run by `-UmbarRenderMotion <dir>`:
//    glow-music-<bg>-<notch>-<ms>.png   the real closed island, music
//                                       playing: the breath, 1.75 s apart
//                                       (a quarter of it)
//    glow-<event>-<notch>-<ms>.png      the real island as an event fires
//                                       (timer, camera): two flashes, then
//                                       dark by 1.6 s
//    glow-style-<style>-<bg>-<notch>.png  each style at the default
//                                       intensity around a fixture island
//                                       with music ears and a time ear
//  <bg> is dark or light: the glow is seen against the menu bar and what
//  is under it, which can be either. The style comes from the run's
//  defaults (`-edgeGlowStyle neon`), so the user's own settings are never
//  written. The timer and camera are fixtures: no clock, sound or hardware.
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum EdgeGlowRenderer {
    static let notches = [CGSize(width: 190, height: 37), CGSize(width: 200, height: 32), CGSize(width: 254, height: 45)]
    private static let backgrounds: [(String, Color)] = [("dark", Color(white: 0.11)), ("light", Color(white: 0.85))]
    private static let pulseTimes: [Double] = [0, 0.2, 0.4, 0.8, 1.2, 1.7]
    private static let height: CGFloat = 100

    static func renderMotion(to out: URL) {
        for notch in notches {
            let tag = "\(Int(notch.width))x\(Int(notch.height))"
            renderMusic(notch: notch, tag: tag, out: out)
            renderEvents(notch: notch, tag: tag, out: out)
            renderStyles(notch: notch, tag: tag, out: out)
        }
    }

    private static func renderMusic(notch: CGSize, tag: String, out: URL) {
        let music = MusicManager.shared
        music.songTitle = "Gesaffelstein — Pursuit"
        music.artistName = "Gesaffelstein"
        music.isPlaying = true
        music.isPlayerIdle = false
        music.avgColor = NSColor(red: 0.78, green: 0.25, blue: 0.55, alpha: 1)
        for (bg, color) in backgrounds {
            let session = MotionFrameRenderer.Session(island(notch, background: color), size: size)
            let start = Date()
            for t in [0.0, 1.75, 3.5] {
                RunLoop.main.run(until: start.addingTimeInterval(t))
                MotionFrameRenderer.capture(session.host, to: out.appendingPathComponent("glow-music-\(bg)-\(tag)-\(Int(t * 1000)).png"))
            }
            session.close()
        }
        music.isPlaying = false
        music.isPlayerIdle = true
    }

    private static func renderEvents(notch: CGSize, tag: String, out: URL) {
        let timer = TimerService.shared
        let privacy = PrivacyIndicatorMonitor.shared
        let events: [(String, () -> Void, () -> Void)] = [
            ("timer", { timer.showFixture(.idle, alerting: true) }, { timer.showFixture(.idle, alerting: false) }),
            ("camera", { privacy.showFixture(PrivacyUsage(camera: true, microphone: false, microphoneApps: [])) },
             { privacy.showFixture(.idle) }),
        ]
        let session = MotionFrameRenderer.Session(island(notch, background: backgrounds[0].1), size: size)
        for (name, fire, reset) in events {
            fire()
            let start = Date()
            for t in pulseTimes {
                RunLoop.main.run(until: start.addingTimeInterval(t))
                MotionFrameRenderer.capture(session.host, to: out.appendingPathComponent("glow-\(name)-\(tag)-\(Int(t * 1000)).png"))
            }
            reset()
            RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        }
        session.close()
    }

    /// A fixture island with a time ear on its leading side, so the frame
    /// shows the glow following the ear, at the default intensity.
    private static func renderStyles(notch: CGSize, tag: String, out: URL) {
        let width = notch.width + 2 * max(0, notch.height - 12) + 20
        let ear: CGFloat = 70
        let shape = NotchShape(topCornerRadius: cornerRadiusInsets.closed.top,
                               bottomCornerRadius: cornerRadiusInsets.closed.bottom)
        let canvas = NSSize(width: width + 2 * ear + 80, height: notch.height + 50)
        for style in [EdgeGlowStyle.soft, .neon] {
            for (bg, color) in backgrounds {
                let root = shape.fill(.black)
                    .frame(width: width, height: notch.height)
                    .background(alignment: .topLeading) {
                        UnevenRoundedRectangle(bottomLeadingRadius: 8)
                            .fill(.black)
                            .frame(width: ear, height: notch.height)
                            .offset(x: -ear + cornerRadiusInsets.closed.top)
                    }
                    .compositingGroup()
                    .modifier(EdgeGlowShadow(style: style, color: Color(red: 0.86, green: 0.47, blue: 0.70), level: 0.7))
                    .frame(width: canvas.width, height: canvas.height, alignment: .top)
                    .background(color)
                    .environment(\.colorScheme, .dark)
                let still = MotionFrameRenderer.Session(root, size: canvas)
                MotionFrameRenderer.capture(still.host, to: out.appendingPathComponent("glow-style-\(style.rawValue)-\(bg)-\(tag).png"))
                still.close()
            }
        }
    }

    private static let size = NSSize(width: windowSize.width, height: height)

    private static func island(_ notch: CGSize, background: Color) -> some View {
        let vm = MotionFrameRenderer.fixtureViewModel(notch: notch)
        vm.notchSize = notch
        return ContentView()
            .environmentObject(vm)
            .frame(width: windowSize.width, height: height, alignment: .top)
            .background(background)
    }
}
#endif
