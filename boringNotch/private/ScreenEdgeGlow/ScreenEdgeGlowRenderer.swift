//
//  ScreenEdgeGlowRenderer.swift
//  boringNotch
//
//  Debug-only fixtures for the screen edge glow, run by
//  `-UmbarRenderMotion <dir> -UmbarRenderMotionOnly screenedge`. Each frame
//  is the top 180 pt of a MacBook screen (1512 pt wide, 10 pt corners, a
//  190 pt notch and a menu bar) at full size, which is all the bands use:
//    screenedge-camera-<bg>-<ms>.png   an event: the sweep out of the
//                                      notch and the two flashes, dark by 1.6 s
//    screenedge-music-<bg>-<ms>.png    music starting: the reveal, then the
//                                      breath with its glint
//    screenedge-audio-<frame>.png      reacting to sound, fed the notch
//                                      glow's fake 120 bpm sequence at 30 Hz
//                                      (frame 15 is a kick, 7 a hat)
//    screenedge-reduce-<bg>.png        Reduce Motion: the still bands
//    screenedge-style-<style>-<bg>.png each style, a glint mid-band
//    screenedge-thickness-<pt>.png     the thinnest and thickest settings
//    screenedge-spread-<x100>.png      the shortest, default and longest
//                                      bands (notch widths × 100)
//    screenedge-settings-<bg>.png      Settings' edge glow section
//  <bg> is dark or light (the wallpaper under it). Nothing is captured or
//  played; the user's settings are only read (`-edgeGlowStyle neon`).
//

#if DEBUG
import AppKit
import Defaults
import SwiftUI

@MainActor
enum ScreenEdgeGlowRenderer {
    private static let screen = CGSize(width: 1512, height: 982)
    private static let notch = CGSize(width: 190, height: 37)
    private static let corner: CGFloat = 10
    private static let stripHeight: CGFloat = 180
    private static let backgrounds: [(String, Color, Color)] = [
        ("dark", Color(red: 0.10, green: 0.11, blue: 0.14), Color(white: 0.16)),
        ("light", Color(red: 0.86, green: 0.87, blue: 0.90), Color(white: 0.94)),
    ]
    private static let album = EdgeGlowRGB(red: 0.86, green: 0.47, blue: 0.70)

    static func renderMotion(to out: URL) {
        let thickness = CGFloat(Defaults[.screenEdgeGlowThickness])
        let intensity = Defaults[.screenEdgeGlowIntensity]
        let style = Defaults[.edgeGlowStyle]
        let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

        for (bg, wall, bar) in backgrounds {
            // An event.
            var envelope = EdgeGlowEnvelope()
            envelope.update(to: EdgeGlowState(tint: .camera, animation: .pulse), now: start, reduceMotion: false)
            for t in [0.0, 0.15, 0.3, 0.5, 0.8, 1.0, 1.2, 1.6] {
                let frame = ScreenEdgeGlowModel.frame(envelope: envelope, audio: .init(), pulseStart: start,
                                                      album: album, at: start.addingTimeInterval(t))
                still(frame, style: style, thickness: thickness, intensity: intensity, wall: wall, bar: bar,
                      to: out.appendingPathComponent("screenedge-camera-\(bg)-\(Int(t * 1000)).png"))
            }
            // Music starting.
            envelope = EdgeGlowEnvelope()
            envelope.update(to: EdgeGlowState(tint: .album, animation: .breathing), now: start, reduceMotion: false)
            for t in [0.0, 0.2, 0.45, 0.9, 1.75, 2.6, 3.5] {
                let frame = ScreenEdgeGlowModel.frame(envelope: envelope, audio: .init(), pulseStart: .distantPast,
                                                      album: album, at: start.addingTimeInterval(t))
                still(frame, style: style, thickness: thickness, intensity: intensity, wall: wall, bar: bar,
                      to: out.appendingPathComponent("screenedge-music-\(bg)-\(Int(t * 1000)).png"))
            }
            // Reduce Motion.
            envelope = EdgeGlowEnvelope()
            envelope.update(to: EdgeGlowState(tint: .album, animation: .steady), now: start, reduceMotion: true)
            still(ScreenEdgeGlowModel.frame(envelope: envelope, audio: .init(), pulseStart: .distantPast, album: album, at: start),
                  style: style, thickness: thickness, intensity: intensity, wall: wall, bar: bar,
                  to: out.appendingPathComponent("screenedge-reduce-\(bg).png"))
            // Styles, full size, mid-breath with a glint on the side.
            for s in [EdgeGlowStyle.soft, .neon] {
                let frame = ScreenEdgeGlowFrame(color: album.color, level: 0.8, reach: 1,
                                                glint: .init(position: 0.45, strength: 0.8,
                                                             color: EdgeGlowColor.sparkle(album, amount: 0.45).color))
                still(frame, style: s, thickness: thickness, intensity: intensity, wall: wall, bar: bar,
                      to: out.appendingPathComponent("screenedge-style-\(s.rawValue)-\(bg).png"))
            }
        }
        renderAudio(style: style, thickness: thickness, intensity: intensity, start: start, out: out)
        for pt in [ScreenEdgeGlowPolicy.thicknessRange.lowerBound, ScreenEdgeGlowPolicy.thicknessRange.upperBound] {
            let frame = ScreenEdgeGlowFrame(color: album.color, level: 0.8, reach: 1, glint: nil)
            still(frame, style: style, thickness: CGFloat(pt), intensity: intensity,
                  wall: backgrounds[0].1, bar: backgrounds[0].2,
                  to: out.appendingPathComponent("screenedge-thickness-\(Int(pt)).png"))
        }
        for spread in [ScreenEdgeGlowPolicy.spreadRange.lowerBound, Defaults.Keys.screenEdgeGlowSpread.defaultValue,
                       ScreenEdgeGlowPolicy.spreadRange.upperBound] {
            let frame = ScreenEdgeGlowFrame(color: album.color, level: 0.8, reach: 1, glint: nil)
            still(frame, style: style, thickness: thickness, intensity: intensity,
                  wall: backgrounds[0].1, bar: backgrounds[0].2, spread: spread,
                  to: out.appendingPathComponent("screenedge-spread-\(Int(spread * 100)).png"))
        }
        renderSettings(out: out)
    }

    private static let audioFrames = [0, 7, 14, 15, 16, 18, 22]

    private static func renderAudio(style: EdgeGlowStyle, thickness: CGFloat, intensity: Double, start: Date, out: URL) {
        var envelope = EdgeGlowEnvelope()
        // Long enough ago that the reveal is over.
        envelope.update(to: EdgeGlowState(tint: .album, animation: .audio), now: start.addingTimeInterval(-5), reduceMotion: false)
        var follower = EdgeGlowAudioFollower()
        for i in 0...audioFrames.max()! {
            let a = EdgeGlowRenderer.fakeAudio(frame: i)
            let now = start.addingTimeInterval(Double(i) / 30)
            follower.feed(level: a.level, bass: a.bass, treble: a.treble, now: now)
            guard audioFrames.contains(i) else { continue }
            let frame = ScreenEdgeGlowModel.frame(envelope: envelope, audio: follower, pulseStart: .distantPast,
                                                  album: album, at: now)
            still(frame, style: style, thickness: thickness, intensity: intensity,
                  wall: backgrounds[0].1, bar: backgrounds[0].2,
                  to: out.appendingPathComponent("screenedge-audio-\(i).png"))
        }
    }

    private static func renderSettings(out: URL) {
        for (bg, appearance, scheme) in [("dark", NSAppearance.Name.darkAqua, ColorScheme.dark),
                                         ("light", .aqua, .light)] {
            let size = NSSize(width: 620, height: 640)
            let root = Form { EdgeGlowSettingsSection() }
                .formStyle(.grouped)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme)
            let session = MotionFrameRenderer.Session(root, size: size)
            session.window.appearance = NSAppearance(named: appearance)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            MotionFrameRenderer.capture(session.host, to: out.appendingPathComponent("screenedge-settings-\(bg).png"))
            session.close()
        }
    }

    /// The top of one screen: wallpaper, menu bar, the bands, the notch
    /// over them, the display's rounded top corners (black outside, as
    /// the bezel). `spread` defaults to the run's setting.
    private static func still(_ frame: ScreenEdgeGlowFrame?, style: EdgeGlowStyle, thickness: CGFloat,
                              intensity: Double, wall: Color, bar: Color,
                              spread: Double = Defaults[.screenEdgeGlowSpread], to url: URL) {
        let size = CGSize(width: screen.width, height: stripHeight)
        let root = ZStack(alignment: .top) {
            wall
            bar.frame(height: notch.height)
            if let frame {
                ScreenEdgeGlowRim(frame: frame, style: style, thickness: thickness, intensity: intensity,
                                  notchWidth: notch.width,
                                  bandLength: ScreenEdgeGlowPolicy.bandLength(
                                      screenWidth: screen.width, notchWidth: notch.width, spread: spread))
            }
            // Hardware, and the notch's own window above the bands': nothing
            // drawn under it is seen.
            UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                .fill(.black)
                .frame(width: notch.width, height: notch.height)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: corner, topTrailingRadius: corner))
        .background(.black)
        let session = MotionFrameRenderer.Session(root, size: NSSize(width: size.width, height: size.height))
        MotionFrameRenderer.capture(session.host, to: url)
        session.close()
    }
}
#endif
