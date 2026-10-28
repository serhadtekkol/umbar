//
//  SysMonitorViews.swift
//  boringNotch
//
//  F22 UI: the compact system row at the bottom of the Ağ page. One line
//  of four cells (CPU, memory, thermal state, busiest apps) so the network
//  graph above keeps most of the page. design-language §3: amber means
//  "live" and is not used here; a warning is a glyph change plus weight,
//  never colour alone.
//

import Defaults
import SwiftUI

private enum SysTokens {
    static let textPrimary = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
    static let textSecondary = Color(red: 0xA1 / 255, green: 0xA1 / 255, blue: 0xA6 / 255)
    static let hairline = Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255)
}

enum SysStrings {
    static func thermal(_ level: SysThermalLevel) -> String {
        switch level {
        case .nominal: String(localized: "sysmonitor.thermal.nominal", defaultValue: "Normal")
        case .fair: String(localized: "sysmonitor.thermal.fair", defaultValue: "Warm")
        case .serious: String(localized: "sysmonitor.thermal.serious", defaultValue: "Hot")
        case .critical: String(localized: "sysmonitor.thermal.critical", defaultValue: "Critical")
        }
    }

    static func memoryLabel(_ pressure: SysMemoryPressure?) -> String {
        switch pressure {
        case .warning: String(localized: "sysmonitor.memory.warning", defaultValue: "Memory \u{00B7} high")
        case .critical: String(localized: "sysmonitor.memory.critical", defaultValue: "Memory \u{00B7} critical")
        case .normal, nil: String(localized: "sysmonitor.memory", defaultValue: "Memory")
        }
    }
}

/// The live row: subscribes to `SysMonitor` only while it is on screen.
struct SysStatsSection: View {
    @ObservedObject private var monitor = SysMonitor.shared

    var body: some View {
        SysStatsRow(snapshot: monitor.snapshot)
            .onAppear { monitor.beginObserving() }
            .onDisappear { monitor.endObserving() }
    }
}

/// Plain-value row, so the offscreen page render can feed it a fixture.
struct SysStatsRow: View {
    let snapshot: SysSnapshot?

    static let height: CGFloat = 34
    private let dash = "\u{2014}"

    var body: some View {
        HStack(spacing: 0) {
            cpuCell.frame(width: 84, alignment: .leading)
            divider
            memoryCell.frame(width: 150, alignment: .leading)
            divider
            thermalCell.frame(width: 100, alignment: .leading)
            divider
            topAppsCell.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.height)
        .overlay(alignment: .top) {
            Rectangle().fill(SysTokens.hairline).frame(height: 1).offset(y: -6)
        }
    }

    private var divider: some View {
        Rectangle().fill(SysTokens.hairline).frame(width: 1, height: 22).padding(.horizontal, 10)
    }

    private var cpuCell: some View {
        let value = snapshot?.cpu.map { SysFormat.percent($0) } ?? dash
        let label = String(localized: "sysmonitor.cpu", defaultValue: "CPU")
        return cell(glyph: "cpu", value: value, label: label, emphasized: false)
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }

    private var memoryCell: some View {
        let memory = snapshot?.memory
        let value = memory.map { SysFormat.memory(used: $0.usedBytes, total: $0.totalBytes) } ?? dash
        let alert = memory.map { $0.pressure != .normal } ?? false
        let label = SysStrings.memoryLabel(memory?.pressure)
        return cell(glyph: alert ? "exclamationmark.triangle.fill" : "memorychip", value: value, label: label, emphasized: alert)
            .help(String(localized: "sysmonitor.memory.help",
                         defaultValue: "Used memory as Activity Monitor counts it (app, wired and compressed). Memory pressure, not this figure, tells whether the Mac is short of memory."))
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }

    private var thermalCell: some View {
        let level = snapshot?.thermal ?? .nominal
        let value = snapshot.map { SysStrings.thermal($0.thermal) } ?? dash
        let label = String(localized: "sysmonitor.thermal", defaultValue: "Thermal state")
        return cell(glyph: level.isElevated ? "thermometer.high" : "thermometer.medium", value: value, label: label,
                    emphasized: level.isElevated)
            .help(String(localized: "sysmonitor.thermal.help",
                         defaultValue: "The thermal state macOS reports. Above Warm the system slows itself down to cool off. macOS gives apps no temperature reading in degrees."))
            .accessibilityLabel(label)
            .accessibilityValue(value)
    }

    private var topAppsCell: some View {
        let label = String(localized: "sysmonitor.top", defaultValue: "Busiest apps")
        let apps = snapshot?.topApps ?? []
        let idle = String(localized: "sysmonitor.top.idle", defaultValue: "All idle")
        let spoken = apps.isEmpty
            ? (snapshot?.cpu == nil ? dash : idle)
            : apps.map { "\($0.name) \(SysFormat.percent($0.cpu))" }.joined(separator: ", ")
        return HStack(spacing: 8) {
            glyph("chart.bar.fill", emphasized: false)
            VStack(alignment: .leading, spacing: 1) {
                if apps.isEmpty {
                    valueText(snapshot?.cpu == nil ? dash : idle, emphasized: false)
                } else {
                    // Both apps when both names fit whole; otherwise only
                    // the busiest, truncated if it must be. Two truncated
                    // names ("Xc… · Saf…") name nothing.
                    ViewThatFits(in: .horizontal) {
                        appList(apps, truncating: false)
                        appList(Array(apps.prefix(1)), truncating: true)
                    }
                    .font(.system(size: 13, weight: .medium))
                }
                labelText(label)
            }
        }
        .help(String(localized: "sysmonitor.top.help",
                     defaultValue: "Your apps using the most CPU over the last second, all of an app's processes together. 100% is one full core."))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spoken)
    }

    private func appList(_ apps: [SysAppUsage], truncating: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(apps.enumerated()), id: \.offset) { index, app in
                if index > 0 {
                    Text("\u{00B7}").foregroundStyle(SysTokens.textSecondary)
                }
                Text(app.name)
                    .foregroundStyle(SysTokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: !truncating, vertical: false)
                Text(SysFormat.percent(app.cpu))
                    .monospacedDigit()
                    .foregroundStyle(SysTokens.textSecondary)
                    .fixedSize()
            }
        }
    }

    private func cell(glyph name: String, value: String, label: String, emphasized: Bool) -> some View {
        HStack(spacing: 8) {
            glyph(name, emphasized: emphasized)
            VStack(alignment: .leading, spacing: 1) {
                valueText(value, emphasized: emphasized)
                labelText(label)
            }
        }
        .accessibilityElement(children: .ignore)
    }

    private func glyph(_ name: String, emphasized: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(emphasized ? SysTokens.textPrimary : SysTokens.textSecondary)
            .frame(width: 16)
            .accessibilityHidden(true)
    }

    private func valueText(_ text: String, emphasized: Bool) -> some View {
        Text(text)
            .font(.system(size: 13, weight: emphasized ? .bold : .medium).monospacedDigit())
            .foregroundStyle(SysTokens.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func labelText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(SysTokens.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
