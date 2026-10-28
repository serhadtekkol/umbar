//
//  EyeBreakBannerRenderer.swift
//  boringNotch
//
//  Debug-only fixtures for the eye-break banner (C7-H), run as part of the
//  two frame renderers:
//    -UmbarRenderPages <dir>   eyebreak-<state>-<notch>.png, the whole
//                              notch window with the banner (compact, intro)
//                              and the open panel while it is up (panel)
//    -UmbarRenderMotion <dir>  eyebreak-in-<notch>-<ms>.png, the banner
//                              arriving under the closed notch
//  The real ContentView draws it, so the frames show its place under the
//  notch. Language follows -AppleLanguages.
//

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum EyeBreakBannerRenderer {
    static let notches = [CGSize(width: 190, height: 37), CGSize(width: 200, height: 32), CGSize(width: 254, height: 45)]

    static func renderPages(to out: URL) {
        for notch in notches {
            let tag = "\(Int(notch.width))x\(Int(notch.height))"
            for (state, intro, open) in [("compact", false, false), ("intro", true, false), ("panel", false, true), ("panel-intro", true, true)] {
                let vm = MotionFrameRenderer.fixtureViewModel(notch: notch)
                vm.notchSize = notch
                if open { vm.open() }
                // 14 of 20 s left, so the bar shows a part drained.
                EyeBreakManager.shared.showFixturePrompt(endsAt: Date().addingTimeInterval(14.5), intro: intro)
                let session = MotionFrameRenderer.Session(root(vm), size: size)
                MotionFrameRenderer.capture(session.host, to: out.appendingPathComponent("eyebreak-\(state)-\(tag).png"))
                session.close()
            }
        }
    }

    static func renderMotion(to out: URL) {
        for notch in notches {
            let tag = "\(Int(notch.width))x\(Int(notch.height))"
            let vm = MotionFrameRenderer.fixtureViewModel(notch: notch)
            vm.notchSize = notch
            EyeBreakManager.shared.skip()
            let session = MotionFrameRenderer.Session(root(vm), size: size)
            session.play(change: {
                EyeBreakManager.shared.showFixturePrompt(endsAt: Date().addingTimeInterval(20), intro: false)
            }, name: { out.appendingPathComponent("eyebreak-in-\(tag)-\($0).png") })
            session.close()
        }
        EyeBreakManager.shared.skip()
    }

    private static let size = NSSize(width: windowSize.width, height: windowSize.height)

    private static func root(_ vm: BoringViewModel) -> some View {
        ContentView()
            .environmentObject(vm)
            .frame(width: windowSize.width, height: windowSize.height, alignment: .top)
            .background(Color(white: 0.85))
    }
}
#endif
