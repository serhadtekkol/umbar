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
//    glow-audio-<notch>-<frame>.png     the audio-reactive glow fed a fake
//                                       120 bpm level sequence at 30 Hz
//                                       (frame 15 is a kick, 16–22 its decay)
//    glow-color-fixed-<bg>-<notch>.png  the fixed colour (the default one)
//    glow-color-cycle-<notch>-<s>.png   the colour cycle a quarter turn apart
//    glow-settings-<bg>.png             Settings' edge glow section, event
//                                       colours open
//  <bg> is dark or light: the glow is seen against the menu bar and what
//  is under it, which can be either. The style comes from the run's
//  defaults (`-edgeGlowStyle neon`), so the user's own settings are never
//  written. The timer and camera are fixtures: no clock, sound or hardware;
//  the audio frames are computed, nothing is captured or played.
//

#if DEBUG
import AppKit
import Defaults
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
            renderAudio(notch: notch, tag: tag, out: out)
            renderColors(notch: notch, tag: tag, out: out)
        }
        renderSettings(out: out)
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
        for style in [EdgeGlowStyle.soft, .neon] {
            for (bg, color) in backgrounds {
                still(notch, background: color,
                      glow: EdgeGlowShadow(style: style, color: Color(red: 0.86, green: 0.47, blue: 0.70), level: 0.7),
                      to: out.appendingPathComponent("glow-style-\(style.rawValue)-\(bg)-\(tag).png"))
            }
        }
    }

    /// Kick on every 15th frame (120 bpm at 30 Hz), a body of sound that
    /// swells with it, hats between. Shaped like the monitor's smoothed
    /// output: a rise over a frame or two, a slower fall.
    static func fakeAudio(frame i: Int) -> (level: Double, bass: Double, treble: Double) {
        let sinceKick = Double(i % 15)
        let kick = exp(-sinceKick / 3)
        let hat = i % 15 == 7 ? 0.8 : exp(-Double(abs(i % 15 - 7)) / 1.5) * 0.6
        return (0.3 + 0.4 * kick, 0.15 + 0.7 * kick, hat)
    }

    private static let audioFrames = [0, 7, 14, 15, 16, 18, 22, 29, 30]

    private static func renderAudio(notch: CGSize, tag: String, out: URL) {
        var follower = EdgeGlowAudioFollower()
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let album = EdgeGlowRGB(red: 0.86, green: 0.47, blue: 0.70)
        for i in 0...audioFrames.max()! {
            let a = fakeAudio(frame: i)
            follower.feed(level: a.level, bass: a.bass, treble: a.treble, now: start.addingTimeInterval(Double(i) / 30))
            guard audioFrames.contains(i) else { continue }
            let color = EdgeGlowColor.sparkle(album, amount: follower.sparkle).color
            still(notch, background: backgrounds[0].1,
                  glow: EdgeGlowShadow(style: .soft, color: color, level: follower.brightness * 0.7, spread: follower.spread),
                  to: out.appendingPathComponent("glow-audio-\(tag)-\(i).png"))
        }
    }

    private static func renderColors(notch: CGSize, tag: String, out: URL) {
        let fixed = EdgeGlowColor.rgb(hex: Defaults.Keys.edgeGlowFixedColor.defaultValue) ?? EdgeGlowRGB(red: 1, green: 1, blue: 1)
        for (bg, color) in backgrounds {
            still(notch, background: color,
                  glow: EdgeGlowShadow(style: .soft, color: fixed.color, level: 0.7),
                  to: out.appendingPathComponent("glow-color-fixed-\(bg)-\(tag).png"))
        }
        let quarter = EdgeGlowColor.cyclePeriod / 4
        for step in 0..<4 {
            let t = Double(step) * quarter
            still(notch, background: backgrounds[0].1,
                  glow: EdgeGlowShadow(style: .soft, color: EdgeGlowColor.cycle(time: t).color, level: 0.7),
                  to: out.appendingPathComponent("glow-color-cycle-\(tag)-\(Int(t * 10)).png"))
        }
    }

    /// The section as Settings shows it, in both appearances. The run's
    /// defaults choose what is on (`-edgeGlowColorMode fixed
    /// -edgeGlowAudioReactive YES`).
    private static func renderSettings(out: URL) {
        for (bg, appearance, scheme) in [("dark", NSAppearance.Name.darkAqua, ColorScheme.dark),
                                         ("light", .aqua, .light)] {
            let size = NSSize(width: 620, height: 820)
            let root = Form { EdgeGlowSettingsSection(showsEventColors: true) }
                .formStyle(.grouped)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme)
            let session = MotionFrameRenderer.Session(root, size: size)
            session.window.appearance = NSAppearance(named: appearance)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            MotionFrameRenderer.capture(session.host, to: out.appendingPathComponent("glow-settings-\(bg).png"))
            session.close()
        }
    }

    /// One frame of a fixture island (with a leading time ear) wearing `glow`.
    private static func still(_ notch: CGSize, background: Color, glow: EdgeGlowShadow, to url: URL) {
        let width = notch.width + 2 * max(0, notch.height - 12) + 20
        let ear: CGFloat = 70
        let shape = NotchShape(topCornerRadius: cornerRadiusInsets.closed.top,
                               bottomCornerRadius: cornerRadiusInsets.closed.bottom)
        let canvas = NSSize(width: width + 2 * ear + 80, height: notch.height + 50)
        let root = shape.fill(.black)
            .frame(width: width, height: notch.height)
            .background(alignment: .topLeading) {
                UnevenRoundedRectangle(bottomLeadingRadius: 8)
                    .fill(.black)
                    .frame(width: ear, height: notch.height)
                    .offset(x: -ear + cornerRadiusInsets.closed.top)
            }
            .compositingGroup()
            .modifier(glow)
            .frame(width: canvas.width, height: canvas.height, alignment: .top)
            .background(background)
            .environment(\.colorScheme, .dark)
        let session = MotionFrameRenderer.Session(root, size: canvas)
        MotionFrameRenderer.capture(session.host, to: url)
        session.close()
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
