//
//  TimerViews.swift
//  boringNotch
//
//  F25 UI: the Araçlar time card (focus timer / countdown / stopwatch behind
//  one mode switch) and the closed-island ear with the end-of-countdown alert.
//

import Defaults
import SwiftUI

// MARK: - Time card

/// The Araçlar card for every clock. One card with a mode switch rather than
/// a tile per clock: the page fits three tiles across, and the focus timer's
/// running controls already need most of one.
struct TimeToolTile: View {
    @ObservedObject private var timer = TimerService.shared
    @ObservedObject private var focus = FocusTimerService.shared
    @Default(.focusTimerEnabled) private var focusOn
    @Default(.timerEnabled) private var timerOn
    @Default(.timeToolMode) private var storedMode
    #if DEBUG
    /// The page renderer's mode; nil reads the user's choice.
    var modeFixture: TimeToolMode?
    #endif

    private var modes: [TimeToolMode] {
        (focusOn ? [.focus] : []) + (timerOn ? [.countdown, .stopwatch] : [])
    }

    /// A finished countdown takes the card, so opening the panel on the
    /// pulsing ear lands on its "OK / Again".
    private var mode: TimeToolMode {
        if timerOn && timer.isAlerting { return .countdown }
        #if DEBUG
        if let modeFixture { return modeFixture }
        #endif
        return modes.contains(storedMode) ? storedMode : (modes.first ?? .focus)
    }

    var body: some View {
        let switcher = modes.count > 1 ? AnyView(modeSwitch) : nil
        switch mode {
        case .focus: FocusTimerTile(modeSwitch: switcher)
        case .countdown: CountdownTile(modeSwitch: switcher)
        case .stopwatch: StopwatchTile(modeSwitch: switcher)
        }
    }

    private var modeSwitch: some View {
        HStack(spacing: 2) {
            ForEach(modes, id: \.self) { m in
                Button { storedMode = m } label: {
                    Image(systemName: Self.symbol(m))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isLive(m) ? PageTokens.live
                                         : m == mode ? PageTokens.textPrimary : PageTokens.textSecondary)
                        .frame(width: 22, height: 18)
                        .background(Capsule().fill(m == mode ? PageTokens.raisedStrong : .clear))
                        // The dot carries "counting" on its own: in the panel
                        // the outline "timer" and "stopwatch" glyphs draw
                        // white whatever their foreground style (seen in the
                        // page renderer on macOS 27; the filled forms tint).
                        .overlay(alignment: .topTrailing) {
                            if isLive(m) {
                                Circle().fill(PageTokens.live).frame(width: 4, height: 4).offset(x: -2, y: 1)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(Self.title(m))
                .accessibilityLabel(Self.title(m))
                .accessibilityAddTraits(m == mode ? .isSelected : [])
                .accessibilityValue(isLive(m) ? String(localized: "stopwatch.running", defaultValue: "Running") : "")
            }
        }
    }

    /// Amber glyph on a mode that is counting while another one is shown, so
    /// a running stopwatch is not forgotten behind the focus card.
    private func isLive(_ m: TimeToolMode) -> Bool {
        switch m {
        case .focus: return focus.state.isRunning
        case .countdown: return timer.state.mode == .countdown && timer.state.isRunning
        case .stopwatch: return timer.state.mode == .stopwatch && timer.state.isRunning
        }
    }

    static func symbol(_ m: TimeToolMode) -> String {
        switch m {
        case .focus: return "timer"
        case .countdown: return "hourglass"
        case .stopwatch: return "stopwatch"
        }
    }

    static func title(_ m: TimeToolMode) -> String {
        switch m {
        case .focus: return String(localized: "focus.phase.focus", defaultValue: "Focus")
        case .countdown: return String(localized: "timer.title", defaultValue: "Timer")
        case .stopwatch: return String(localized: "stopwatch.title", defaultValue: "Stopwatch")
        }
    }
}

/// Remaining or elapsed time, redrawn once a second by the view itself so
/// the service does not publish every second. Paused state is drawn static.
private struct TimerClockText: View {
    let state: TimerState

    var body: some View {
        if state.isRunning {
            // A stopwatch's seconds flip on its own second boundaries.
            TimelineView(.periodic(from: state.runningSince ?? .now, by: 1)) { ctx in
                Text(TimerFormat.display(state, at: ctx.date))
            }
        } else {
            Text(TimerFormat.display(state, at: Date()))
        }
    }
}

private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: symbol).font(.system(size: 10, weight: .bold))
    }
    .buttonStyle(ToolChipStyle())
    .help(help)
    .accessibilityLabel(help)
}

private func minutesLabel(_ minutes: Int) -> String {
    String(format: String(localized: "timer.minutes", defaultValue: "%lld min"), minutes)
}

struct CountdownTile: View {
    @ObservedObject private var service = TimerService.shared
    @Default(.timerCustomMinutes) private var customMinutes
    var modeSwitch: AnyView?

    static let presets = [1, 5, 10, 25]

    /// The engine holds one clock at a time: a running stopwatch is not
    /// this card's state, and starting a countdown replaces it.
    private var own: TimerState? {
        service.state.mode == .countdown && !service.state.isIdle ? service.state : nil
    }

    var body: some View {
        ToolTile(
            symbol: "hourglass",
            title: TimeToolTile.title(.countdown),
            status: status,
            active: service.isAlerting || (own?.isRunning ?? false),
            accessory: { if let modeSwitch { modeSwitch } },
            statusView: {
                if own == nil && !service.isAlerting {
                    customRow
                } else {
                    // Same face as ToolTile's own status line.
                    Text(status)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(service.isAlerting ? PageTokens.live : PageTokens.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        ) {
            if service.isAlerting {
                HStack(spacing: 4) {
                    Button(String(localized: "timer.alert.ok", defaultValue: "OK")) { service.dismissAlert() }
                        .buttonStyle(ToolChipStyle())
                    Button(String(localized: "timer.again", defaultValue: "Again")) { service.restartCountdown() }
                        .buttonStyle(ToolChipStyle())
                        .help(minutesLabel(lastMinutes))
                }
            } else if let own {
                HStack(spacing: 4) {
                    TimerClockText(state: own)
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(PageTokens.textPrimary)
                    Spacer(minLength: 4)
                    if own.isPaused {
                        iconButton("play.fill", help: String(localized: "focus.help.resume", defaultValue: "Resume")) { service.resume() }
                    } else {
                        iconButton("pause.fill", help: String(localized: "focus.help.pause", defaultValue: "Pause")) { service.pause() }
                    }
                    iconButton("stop.fill", help: String(localized: "timer.help.reset", defaultValue: "Reset")) { service.reset() }
                }
            } else {
                HStack(spacing: 4) {
                    ForEach(Self.presets, id: \.self) { minutes in
                        Button("\(minutes)′") { service.startCountdown(minutes: minutes) }
                            .buttonStyle(ToolChipStyle())
                            .accessibilityLabel(String(
                                format: String(localized: "timer.preset.a11y", defaultValue: "Start a %lld-minute timer"), minutes))
                    }
                }
            }
        }
    }

    private var lastMinutes: Int { max(1, Int((service.state.duration / 60).rounded())) }

    private var status: String {
        if service.isAlerting { return String(localized: "timer.alert.title", defaultValue: "Time's up") }
        guard let own else { return "" }
        if own.isPaused { return String(localized: "timer.paused", defaultValue: "Paused") }
        return String(format: String(localized: "timer.running", defaultValue: "%@ timer"), minutesLabel(lastMinutes))
    }

    /// The custom length, set in place: − / + and start. Steps of one minute
    /// up to 10, then five, which reaches an hour in a few clicks.
    private var customRow: some View {
        HStack(spacing: 4) {
            iconButton("minus", help: String(localized: "timer.help.shorter", defaultValue: "Shorter")) {
                customMinutes = Self.step(customMinutes, up: false)
            }
            Text(minutesLabel(customMinutes))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(PageTokens.textPrimary)
                .lineLimit(1)
                .frame(minWidth: 44)
                .accessibilityLabel(String(localized: "timer.custom.a11y", defaultValue: "Custom length"))
                .accessibilityValue(minutesLabel(customMinutes))
            iconButton("plus", help: String(localized: "timer.help.longer", defaultValue: "Longer")) {
                customMinutes = Self.step(customMinutes, up: true)
            }
            Spacer(minLength: 2)
            iconButton("play.fill", help: String(format: String(localized: "timer.preset.a11y", defaultValue: "Start a %lld-minute timer"), customMinutes)) {
                service.startCountdown(minutes: customMinutes)
            }
        }
    }

    static func step(_ minutes: Int, up: Bool) -> Int {
        let size = (up ? minutes >= 10 : minutes > 10) ? 5 : 1
        let next = up ? minutes + size : minutes - size
        return min(max(next, TimerEngine.minuteRange.lowerBound), TimerEngine.minuteRange.upperBound)
    }
}

struct StopwatchTile: View {
    @ObservedObject private var service = TimerService.shared
    var modeSwitch: AnyView?

    private var own: TimerState? {
        service.state.mode == .stopwatch && !service.state.isIdle ? service.state : nil
    }

    var body: some View {
        ToolTile(
            // Filled: the outline glyph ignores the amber tint in the panel
            // (see the mode switch's dot).
            symbol: "stopwatch.fill",
            title: TimeToolTile.title(.stopwatch),
            status: status,
            active: own?.isRunning ?? false,
            accessory: { if let modeSwitch { modeSwitch } },
            statusView: { EmptyView() }
        ) {
            if let own {
                HStack(spacing: 4) {
                    TimerClockText(state: own)
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(PageTokens.textPrimary)
                    Spacer(minLength: 4)
                    if own.isPaused {
                        iconButton("play.fill", help: String(localized: "focus.help.resume", defaultValue: "Resume")) { service.resume() }
                    } else {
                        iconButton("pause.fill", help: String(localized: "focus.help.pause", defaultValue: "Pause")) { service.pause() }
                        iconButton("flag.fill", help: String(localized: "stopwatch.help.lap", defaultValue: "Lap")) { service.lap() }
                    }
                    iconButton("stop.fill", help: String(localized: "timer.help.reset", defaultValue: "Reset")) { service.reset() }
                }
            } else {
                Button {
                    service.startStopwatch()
                } label: {
                    Label(String(localized: "stopwatch.start", defaultValue: "Start"), systemImage: "play.fill")
                }
                .buttonStyle(ToolChipStyle())
            }
        }
    }

    private var status: String {
        guard let own else {
            return String(localized: "stopwatch.idle", defaultValue: "Measure elapsed time")
        }
        if let lap = own.lastLapLength {
            return String(format: String(localized: "stopwatch.lap", defaultValue: "Lap %1$lld: %2$@"),
                          own.laps.count, TimerFormat.elapsed(lap))
        }
        return own.isPaused
            ? String(localized: "timer.paused", defaultValue: "Paused")
            : String(localized: "stopwatch.running", defaultValue: "Running")
    }
}

// MARK: - Closed island

/// The timer's ear on the closed island's leading edge, in the one slot it
/// shares with the focus timer (LeadingTimeEarPolicy picks the owner).
struct TimerClosedBadge: View {
    @ObservedObject private var timer = TimerService.shared
    @ObservedObject private var focus = FocusTimerService.shared
    @Default(.timerEnabled) private var enabled
    let isClosed: Bool
    let height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shown: Bool {
        isClosed && LeadingTimeEarPolicy.owner(
            focusActive: !focus.state.isIdle, timer: timer.state,
            alerting: timer.isAlerting, timerEnabled: enabled) == .timer
    }

    var body: some View {
        ZStack {
            if shown {
                TimerClosedEar(state: timer.state, alerting: timer.isAlerting, height: height)
                    .transition(.ear(inward: TimerClosedEar.width(alerting: timer.isAlerting), reduce: reduceMotion))
            }
        }
        .animation(UmbarMotion.ear(reduce: reduceMotion), value: shown)
        .animation(UmbarMotion.ear(reduce: reduceMotion), value: timer.isAlerting)
    }
}

/// The tab itself, values in, so the renderers can draw it from a fixture.
struct TimerClosedEar: View {
    let state: TimerState
    let alerting: Bool
    let height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Wider than the focus ear (48): the glyph that says which clock it is
    /// sits before the digits. The alert widens it for its two words.
    static func width(alerting: Bool) -> CGFloat { alerting ? 96 : 58 }

    var body: some View {
        let width = Self.width(alerting: alerting)
        content
            .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
            .frame(width: width, height: height)
            .background(.black, in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 8))
            .offset(x: -width)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(alerting
                ? String(localized: "timer.alert.title", defaultValue: "Time's up")
                : TimeToolTile.title(state.mode == .countdown ? .countdown : .stopwatch))
            .accessibilityValue(alerting ? "" : TimerFormat.display(state, at: Date()))
    }

    @ViewBuilder private var content: some View {
        if alerting {
            HStack(spacing: 4) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 9, weight: .bold))
                    .symbolEffect(.bounce, options: .repeating, isActive: !reduceMotion)
                Text(String(localized: "timer.alert.title", defaultValue: "Time's up"))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(PageTokens.live)
            .modifier(AlertPulse(active: !reduceMotion))
        } else {
            HStack(spacing: 3) {
                Image(systemName: state.mode == .countdown ? "hourglass" : "stopwatch")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(state.isPaused ? Color.gray : PageTokens.live)
                TimerClockText(state: state)
                    .foregroundStyle(state.isPaused ? Color.gray : PageTokens.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }
}

/// The alert's pulse: the ear's content breathes between full and dim while
/// it shows. Off with Reduce Motion, where the bell and the words stay still.
private struct AlertPulse: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([1.0, 0.45]) { view, opacity in
                view.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.5) }
        } else {
            content
        }
    }
}
