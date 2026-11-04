//
//  CritterLayer.swift
//  boringNotch
//
//  ContentView's slot for the idle critter: behind the island, so the
//  island's black hides it in the tunnel. Visual only; it never takes a
//  click, and the click-through mask is unaffected.
//
//  Cost while idle: one sleeping Task waiting for the next crossing. The
//  Canvas and its TimelineView exist only for the ~4.4 s of a crossing.
//

import Combine
import Defaults
import SwiftUI

/// One crossing in progress.
struct CritterRun: Identifiable, Equatable {
    let id = UUID()
    let kind: CritterKind
    let direction: CritterDirection
    let startedAt: Date
}

/// Settings' "Send one now": asks every island for a crossing, frequency aside.
enum CritterPreview {
    static let requested = PassthroughSubject<Void, Never>()
}

struct CritterLayer: View {
    /// The closed island's width (ears included) and whether the pointer is
    /// on it or near enough to make it lean; both from ContentView.
    let islandWidth: CGFloat
    let pointerNear: Bool

    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @ObservedObject private var music = MusicManager.shared
    @ObservedObject private var eyeBreak = EyeBreakManager.shared
    @ObservedObject private var system = CritterSystemState.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Default(.critterEnabled) private var enabled
    @Default(.critterFrequency) private var frequency
    @Default(.critterChoice) private var choice
    @Default(.critterWhileMusic) private var whileMusic

    @State private var liveStripShown = false
    /// The wait is over; the crossing starts once the island is quiet.
    @State private var due = false
    /// Bumped after every crossing, which restarts the wait.
    @State private var cycle = 0
    @State private var run: CritterRun?

    private static let maxSpan = windowSize.width - 8
    private var islandHeight: CGFloat { vm.effectiveClosedNotchHeight }

    private var conditions: CritterConditions {
        CritterConditions(
            enabled: enabled,
            reduceMotion: reduceMotion,
            notchClosed: vm.notchState == .closed,
            islandHidden: vm.hideOnClosed || islandHeight <= 0,
            musicActive: music.isPlaying || !music.isPlayerIdle,
            allowWhileMusic: whileMusic,
            transientShowing: coordinator.sneakPeek.show || coordinator.expandingView.show,
            liveStripShown: liveStripShown,
            eyeBreakBannerShown: eyeBreak.isPromptingInPanel,
            pointerNear: pointerNear,
            userAway: system.userAway,
            helloAnimationRunning: coordinator.helloAnimationRunning
        )
    }

    private var mayAppear: Bool { CritterPolicy.mayAppear(conditions) }

    private struct WaitKey: Equatable {
        let scheduling: Bool
        let frequency: CritterFrequency
        let cycle: Int
    }

    private var waitKey: WaitKey {
        WaitKey(scheduling: CritterPolicy.schedules(enabled: enabled, reduceMotion: reduceMotion),
                frequency: frequency, cycle: cycle)
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .overlay(alignment: .top) {
                if let run, let path = CritterPath(islandWidth: islandWidth, islandHeight: islandHeight,
                                                   maxSpan: Self.maxSpan, direction: run.direction) {
                    CritterCrossing(run: run, path: path)
                        .transition(.opacity.animation(.easeIn(duration: 0.15)))
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onReceive(LiveActivityCenter.shared.$stripItems.map { !$0.isEmpty }.removeDuplicates()) {
                liveStripShown = $0
            }
            .task(id: waitKey) {
                let key = waitKey
                due = false
                guard key.scheduling else { return }
                let delay = CritterPolicy.nextDelay(key.frequency, unit: .random(in: 0...1))
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                due = true
            }
            .task(id: due && mayAppear && run == nil) {
                guard due, mayAppear, run == nil else { return }
                try? await Task.sleep(for: .seconds(CritterPolicy.settleDelay))
                guard !Task.isCancelled, mayAppear else { return }
                start()
            }
            .task(id: run?.id) {
                guard let run else { return }
                let left = CritterPath.leadIn + CritterPath.travel - Date().timeIntervalSince(run.startedAt)
                try? await Task.sleep(for: .seconds(max(0, left)))
                guard !Task.isCancelled, self.run?.id == run.id else { return }
                finish()
            }
            // The island got busy (hover, music, a HUD): leave at once.
            .onChange(of: mayAppear) { _, may in
                if !may, run != nil { finish() }
            }
            .onReceive(CritterPreview.requested) {
                if run == nil, mayAppear { start() }
            }
            #if DEBUG
            .onReceive(CritterFixture.shared.$run.dropFirst()) { run = $0 }
            #endif
    }

    private func start() {
        due = false
        run = CritterRun(kind: choice.kind(unit: .random(in: 0..<1)),
                         direction: Bool.random() ? .leftToRight : .rightToLeft,
                         startedAt: Date())
    }

    private func finish() {
        run = nil
        cycle += 1
    }
}

/// The crossing itself: crumbs and the critter, redrawn every frame.
private struct CritterCrossing: View {
    let run: CritterRun
    let path: CritterPath

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                let elapsed = timeline.date.timeIntervalSince(run.startedAt)
                CritterArt.draw(run.kind, path: path, elapsed: elapsed, in: &context,
                                origin: CGPoint(x: size.width / 2, y: 0))
            }
        }
        .frame(width: path.span, height: path.laneY + 12)
    }
}

#if DEBUG
/// Lets MotionFrameRenderer start a crossing with a known critter and side.
@MainActor final class CritterFixture: ObservableObject {
    static let shared = CritterFixture()
    @Published var run: CritterRun?
}
#endif
