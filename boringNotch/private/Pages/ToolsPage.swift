//
//  ToolsPage.swift
//  boringNotch
//
//  Araçlar: the quick toggles on one line, then one tile per tool
//  (Caffeinate, time card, eye break). These used to sit in the header
//  and on Şimdi; each now has room to show its state in words. The time
//  card switches between the focus timer, a countdown and a stopwatch
//  (F25): a fourth tile would leave each ~128 pt inside, too narrow for
//  Caffeinate's duration chips or the focus timer's running controls.
//

import Defaults
import SwiftUI

struct ToolsPage: View {
    @Default(.quickTogglesEnabled) private var togglesOn
    @Default(.caffeinateEnabled) private var caffeinateOn
    @Default(.focusTimerEnabled) private var focusOn
    @Default(.timerEnabled) private var timerOn
    @Default(.eyeBreakEnabled) private var eyeBreakOn
    @Default(.btBatteryEnabled) private var btBatteryOn
    #if DEBUG
    /// The frame renderer's Bluetooth devices; nil reads the monitor.
    private var btFixture: [BTBatteryDevice]?
    /// The frame renderer's time-card mode; nil reads the user's choice.
    private var timeModeFixture: TimeToolMode?

    init(btFixture: [BTBatteryDevice]? = nil, timeModeFixture: TimeToolMode? = nil) {
        self.btFixture = btFixture
        self.timeModeFixture = timeModeFixture
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: PageTokens.m) {
            if togglesOn || btBatteryOn {
                // F24 batteries sit with the Bluetooth tile they belong to,
                // tighter than the gap to the tool tiles below.
                VStack(alignment: .leading, spacing: 6) {
                    if togglesOn { QuickTogglesRow() }
                    if btBatteryOn { btBatteryStrip }
                }
            }
            HStack(alignment: .top, spacing: PageTokens.s) {
                if caffeinateOn { CaffeinateTile() }
                if focusOn || timerOn { timeTile }
                if eyeBreakOn { EyeBreakTile() }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

extension ToolsPage {
    @ViewBuilder
    private var timeTile: some View {
        #if DEBUG
        TimeToolTile(modeFixture: timeModeFixture)
        #else
        TimeToolTile()
        #endif
    }

    @ViewBuilder
    private var btBatteryStrip: some View {
        #if DEBUG
        if let btFixture { BTBatteryStrip(fixture: btFixture) } else { BTBatteryStrip() }
        #else
        BTBatteryStrip()
        #endif
    }
}

/// A tool's tile: glyph and name, one status line, controls at the bottom.
/// `active` tints the glyph amber; the status line always says the same
/// thing in words, so colour is never the only signal.
///
/// `accessory` sits at the trailing end of the title row (the time card's
/// mode switch); `statusView` replaces the status line with a view when a tool
/// needs a control there instead of words.
struct ToolTile<Controls: View, Accessory: View, Status: View>: View {
    let symbol: String
    let title: String
    let status: String
    var statusTint: Color = PageTokens.textSecondary
    var active = false
    let accessory: () -> Accessory
    let statusView: () -> Status
    let controls: () -> Controls

    init(symbol: String, title: String, status: String,
         statusTint: Color = PageTokens.textSecondary, active: Bool = false,
         @ViewBuilder accessory: @escaping () -> Accessory,
         @ViewBuilder statusView: @escaping () -> Status,
         @ViewBuilder controls: @escaping () -> Controls) {
        self.symbol = symbol
        self.title = title
        self.status = status
        self.statusTint = statusTint
        self.active = active
        self.accessory = accessory
        self.statusView = statusView
        self.controls = controls
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? PageTokens.live : PageTokens.textSecondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PageTokens.textPrimary)
                    .lineLimit(1)
                if Accessory.self != EmptyView.self {
                    Spacer(minLength: 4)
                    accessory()
                }
            }
            if Status.self == EmptyView.self {
                Text(status)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(statusTint)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                statusView()
            }
            Spacer(minLength: 0)
            controls()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(PageTokens.raised, in: RoundedRectangle(cornerRadius: PageTokens.tileRadius, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension ToolTile where Accessory == EmptyView, Status == EmptyView {
    init(symbol: String, title: String, status: String,
         statusTint: Color = PageTokens.textSecondary, active: Bool = false,
         @ViewBuilder controls: @escaping () -> Controls) {
        self.init(symbol: symbol, title: title, status: status, statusTint: statusTint, active: active,
                  accessory: { EmptyView() }, statusView: { EmptyView() }, controls: controls)
    }
}

/// §3 secondary capsule: `raisedStrong` fill, primary text, 24 pt tall.
struct ToolChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PageTokens.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(minWidth: 28, minHeight: 24)
            .background(Capsule().fill(PageTokens.raisedStrong))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct EyeBreakTile: View {
    @ObservedObject private var manager = EyeBreakManager.shared
    @Default(.eyeBreakIntervalMinutes) private var interval

    var body: some View {
        ToolTile(symbol: "eye", title: String(localized: "Eye break"), status: status, active: isPrompting) {
            if case .snoozed = manager.phase {
                Button(String(localized: "eyebreak.skip", defaultValue: "Skip")) { manager.skip() }
                    .buttonStyle(ToolChipStyle())
            }
        }
    }

    private var isPrompting: Bool {
        if case .prompting = manager.phase { return true }
        return false
    }

    private var status: String {
        switch manager.phase {
        case .counting:
            return String(format: String(localized: "tools.eyeBreak.every", defaultValue: "Every %lld min of screen time"), interval)
        case .prompting:
            return String(localized: "tools.eyeBreak.now", defaultValue: "Break time")
        case .snoozed(let until):
            return String(format: String(localized: "tools.eyeBreak.snoozed", defaultValue: "Snoozed until %@"),
                          until.formatted(date: .omitted, time: .shortened))
        }
    }
}
