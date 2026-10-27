//
//  ToolsPage.swift
//  boringNotch
//
//  Araçlar: the quick toggles on one line, then one tile per tool
//  (Caffeinate, focus timer, eye break). These used to sit in the header
//  and on Şimdi; each now has room to show its state in words.
//

import Defaults
import SwiftUI

struct ToolsPage: View {
    @Default(.quickTogglesEnabled) private var togglesOn
    @Default(.caffeinateEnabled) private var caffeinateOn
    @Default(.focusTimerEnabled) private var focusOn
    @Default(.eyeBreakEnabled) private var eyeBreakOn

    var body: some View {
        VStack(alignment: .leading, spacing: PageTokens.m) {
            if togglesOn {
                QuickTogglesRow()
            }
            HStack(alignment: .top, spacing: PageTokens.s) {
                if caffeinateOn { CaffeinateTile() }
                if focusOn { FocusTimerTile() }
                if eyeBreakOn { EyeBreakTile() }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

/// A tool's tile: glyph and name, one status line, controls at the bottom.
/// `active` tints the glyph amber; the status line always says the same
/// thing in words, so colour is never the only signal.
struct ToolTile<Controls: View>: View {
    let symbol: String
    let title: String
    let status: String
    var statusTint: Color = PageTokens.textSecondary
    var active = false
    @ViewBuilder let controls: () -> Controls

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
            }
            Text(status)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(statusTint)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
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
