//
//  FocusTimerViews.swift
//  boringNotch
//
//  F18 UI: Araçlar tile, closed-notch ear, session-end banner.
//  All visual; the timer never makes a sound.
//

import Defaults
import SwiftUI

/// Remaining time, redrawn once a second by the view itself so the service
/// does not have to publish every second. Paused state is drawn static.
private struct FocusClockText: View {
    let state: FocusTimerState

    var body: some View {
        if state.isRunning {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(FocusTimerFormat.clock(state.remaining(at: ctx.date)))
            }
        } else {
            Text(FocusTimerFormat.clock(state.remaining(at: Date())))
        }
    }
}

private func phaseTitle(_ phase: FocusPhase?) -> String {
    switch phase {
    case .focus: return String(localized: "focus.phase.focus", defaultValue: "Focus")
    case .shortBreak: return String(localized: "focus.phase.shortBreak", defaultValue: "Break")
    case .longBreak: return String(localized: "focus.phase.longBreak", defaultValue: "Long break")
    case nil: return String(localized: "focus.phase.idle", defaultValue: "Focus timer")
    }
}

/// Araçlar tile, same pattern as CaffeinateTile: idle shows the preset
/// chips; running shows phase, remaining time and pause / skip / stop.
///
/// Inside the F25 time card `modeSwitch` sits in the title row, and the
/// title shortens to "Focus" to leave it room.
struct FocusTimerTile: View {
    @ObservedObject private var service = FocusTimerService.shared
    @Default(.focusTimerCustomFocusMinutes) private var customFocus
    @Default(.focusTimerCustomBreakMinutes) private var customBreak
    var modeSwitch: AnyView?

    var body: some View {
        ToolTile(
            symbol: "timer",
            title: modeSwitch == nil ? phaseTitle(nil) : phaseTitle(.focus),
            status: service.state.isIdle
                ? String(localized: "focus.help.start", defaultValue: "Start a focus session")
                : phaseTitle(service.state.phase),
            active: service.state.isRunning,
            accessory: { if let modeSwitch { modeSwitch } },
            statusView: { EmptyView() }
        ) {
            if service.state.isIdle {
                HStack(spacing: 4) { presetChips }
            } else {
                HStack(spacing: 4) {
                    FocusClockText(state: service.state)
                        .umbarFont(.numeric, size: 15, weight: 600)
                        .foregroundStyle(PageTokens.textPrimary)
                    Spacer(minLength: 4)
                    if service.state.isPaused {
                        iconButton("play.fill", help: String(localized: "focus.help.resume", defaultValue: "Resume")) { service.resume() }
                    } else {
                        iconButton("pause.fill", help: String(localized: "focus.help.pause", defaultValue: "Pause")) { service.pause() }
                    }
                    iconButton("forward.end.fill", help: String(localized: "focus.help.skip", defaultValue: "Skip to the next phase")) { service.skip() }
                    iconButton("stop.fill", help: String(localized: "focus.help.stop", defaultValue: "Stop the focus timer")) { service.stop() }
                }
            }
        }
    }

    @ViewBuilder private var presetChips: some View {
        chip("25/5", a11y: String(localized: "focus.preset.classic.a11y", defaultValue: "25 minutes focus, 5 minutes break")) {
            service.start(.classic)
        }
        chip("50/10", a11y: String(localized: "focus.preset.extended.a11y", defaultValue: "50 minutes focus, 10 minutes break")) {
            service.start(.extended)
        }
        chip("\(customFocus)/\(customBreak)", a11y: String(localized: "focus.preset.custom.a11y", defaultValue: "Custom: \(customFocus) minutes focus, \(customBreak) minutes break")) {
            service.startCustom()
        }
    }

    private func chip(_ title: String, a11y: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(ToolChipStyle())
            .accessibilityLabel(a11y)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
        }
        .buttonStyle(ToolChipStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Closed-notch ear on the leading edge (Caffeinate's tab is on the trailing
/// edge). Amber while a phase is counting down, gray while paused. It shares
/// the edge with the F25 timer's ear and steps aside when that one has
/// priority (LeadingTimeEarPolicy), so the two never draw over each other.
struct FocusTimerClosedBadge: View {
    @ObservedObject private var service = FocusTimerService.shared
    @ObservedObject private var timer = TimerService.shared
    @Default(.timerEnabled) private var timerEnabled
    let isClosed: Bool
    let height: CGFloat

    static let width: CGFloat = 48
    private var width: CGFloat { Self.width }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: Bool {
        isClosed && LeadingTimeEarPolicy.owner(
            focusActive: !service.state.isIdle, timer: timer.state,
            alerting: timer.isAlerting, timerEnabled: timerEnabled) == .focus
    }

    var body: some View {
        ZStack {
            if shown { badge }
        }
        .animation(UmbarMotion.ear(reduce: reduceMotion), value: shown)
    }

    private var badge: some View {
            FocusClockText(state: service.state)
                .umbarFont(.numeric, size: 11, weight: 600, design: .rounded)
                .foregroundStyle(service.state.isPaused ? Color.gray : Color.orange)
                .frame(width: width, height: height)
                .background(.black, in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 8))
                .offset(x: -width)
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(phaseTitle(service.state.phase))
                .accessibilityValue(FocusTimerFormat.clock(service.state.remaining(at: Date())))
                // Slides out from under the island's leading edge.
                .transition(.ear(inward: width, reduce: reduceMotion))
    }
}

/// Session-end banner, same layout as EyeBreakPromptView.
struct FocusTimerBannerView: View {
    @ObservedObject var service = FocusTimerService.shared

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: service.banner == .breakEnded ? "timer" : "cup.and.saucer")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                if service.banner != .breakEnded, !service.state.isIdle {
                    FocusClockText(state: service.state)
                        .font(.system(.title3, design: .rounded).monospacedDigit())
                        .foregroundStyle(.gray)
                }
            }

            Spacer(minLength: 8)

            if service.banner == .breakEnded {
                Button(String(localized: "focus.banner.startNext", defaultValue: "Start focus")) {
                    service.startNextFocus()
                }
            } else {
                Button(String(localized: "focus.banner.skipBreak", defaultValue: "Skip break")) {
                    service.skip()
                }
            }
            Button(String(localized: "focus.banner.dismiss", defaultValue: "Dismiss")) {
                service.dismissBanner()
            }
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var title: String {
        switch service.banner {
        case .breakStarted(.longBreak):
            return String(localized: "focus.banner.longBreak", defaultValue: "Focus done. Take a long break")
        case .breakStarted:
            return String(localized: "focus.banner.break", defaultValue: "Focus done. Take a break")
        case .breakEnded:
            return String(localized: "focus.banner.breakOver", defaultValue: "Break over")
        case nil:
            return ""
        }
    }
}
