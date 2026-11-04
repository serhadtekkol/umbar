//
//  CritterRenderer.swift
//  boringNotch
//
//  Debug-only frames of the idle critter, for MotionFrameRenderer
//  (`-UmbarRenderMotion <dir>`, or `-UmbarRenderMotionOnly critter`):
//
//    critter-<kind>-<notch>-<ground>-<ms>.png  the real closed island while
//                       a crossing plays, left to right (ground: light, dark)
//    critter-<kind>-rtl-<notch>-<ms>.png       one right-to-left crossing
//    critter-sheet-<ground>.png                the three critters at 6×,
//                       walking and mid-bite, for checking the pixels
//    critter-settings-<appearance>.png         the Settings section
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum CritterRenderer {
    static let times: [Double] = [0.1, 0.3, 0.6, 0.9, 1.2, 1.5, 1.8, 2.1, 2.4, 2.7, 3.0, 3.3, 3.6, 3.9, 4.2, 4.4]

    static func renderMotion(to out: URL) {
        let music = MusicManager.shared
        music.isPlaying = false
        music.isPlayerIdle = true
        let notches = [CGSize(width: 190, height: 37), CGSize(width: 200, height: 32), CGSize(width: 254, height: 45)]
        let grounds: [(String, Color)] = [("light", Color(white: 0.92)), ("dark", Color(white: 0.12))]
        for notch in notches {
            for (ground, color) in grounds {
                renderCrossings(notch: notch, ground: ground, color: color, out: out)
            }
        }
        for (ground, color) in grounds { renderSheet(ground: ground, color: color, out: out) }
        renderSettings(out: out)
    }

    private static func renderSettings(out: URL) {
        for (name, appearance, scheme) in [("dark", NSAppearance.Name.darkAqua, ColorScheme.dark),
                                           ("light", .aqua, .light)] {
            let size = NSSize(width: 620, height: 380)
            let root = Form { CritterSettingsSection() }
                .formStyle(.grouped)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, scheme)
            let session = MotionFrameRenderer.Session(root, size: size)
            session.window.appearance = NSAppearance(named: appearance)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            MotionFrameRenderer.capture(session.host, to: out.appendingPathComponent("critter-settings-\(name).png"))
            session.close()
        }
    }

    private static func renderCrossings(notch: CGSize, ground: String, color: Color, out: URL) {
        let tag = "\(Int(notch.width))x\(Int(notch.height))"
        let vm = MotionFrameRenderer.fixtureViewModel(notch: notch)
        vm.notchSize = notch
        let height: CGFloat = 80
        let root = ContentView()
            .environmentObject(vm)
            .frame(width: windowSize.width, height: height, alignment: .top)
            .background(color)
        let session = MotionFrameRenderer.Session(root, size: NSSize(width: windowSize.width, height: height))
        for kind in CritterKind.allCases {
            session.play(times: times, change: {
                CritterFixture.shared.run = CritterRun(kind: kind, direction: .leftToRight, startedAt: Date())
            }, name: { out.appendingPathComponent("critter-\(kind.rawValue)-\(tag)-\(ground)-\($0).png") })
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        if ground == "light" {
            session.play(times: times, change: {
                CritterFixture.shared.run = CritterRun(kind: .beetle, direction: .rightToLeft, startedAt: Date())
            }, name: { out.appendingPathComponent("critter-beetle-rtl-\(tag)-\($0).png") })
        }
        CritterFixture.shared.run = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        session.close()
    }

    /// Each critter on a short lane at 6×: walking, then a beat after a bite.
    private static func renderSheet(ground: String, color: Color, out: URL) {
        guard let path = CritterPath(islandWidth: 200, islandHeight: 32, maxSpan: 664, direction: .leftToRight),
              let bite = path.crumbs.dropFirst(3).first else { return }
        let scale: CGFloat = 6
        let cellSize = CGSize(width: 56, height: 28)
        let moments: [TimeInterval] = [bite.eatenAt - 0.2, bite.eatenAt + 0.05]
        let root = Canvas { context, _ in
            for (row, kind) in CritterKind.allCases.enumerated() {
                for (column, elapsed) in moments.enumerated() {
                    var cell = context
                    cell.translateBy(x: CGFloat(column) * cellSize.width * scale, y: CGFloat(row) * cellSize.height * scale)
                    cell.scaleBy(x: scale, y: scale)
                    let pose = path.pose(at: elapsed)
                    // Centre the critter in its cell: shift the lane's origin.
                    let origin = CGPoint(x: cellSize.width * 0.6 - pose.x, y: cellSize.height / 2 - pose.y)
                    CritterArt.draw(kind, path: path, elapsed: elapsed, in: &cell, origin: origin)
                }
            }
        }
        .frame(width: cellSize.width * scale * 2, height: cellSize.height * scale * 3)
        .background(color)
        let size = NSSize(width: cellSize.width * scale * 2, height: cellSize.height * scale * 3)
        let session = MotionFrameRenderer.Session(root, size: size)
        MotionFrameRenderer.capture(session.host, to: out.appendingPathComponent("critter-sheet-\(ground).png"))
        session.close()
    }
}
#endif
