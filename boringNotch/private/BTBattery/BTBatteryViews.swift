//
//  BTBatteryViews.swift
//  boringNotch
//
//  F24 UI: the battery line on Araçlar, under the quick toggles row, and the
//  words shared with the closed-island glance (LiveActivityText) so both say
//  the same thing.
//

import Defaults
import SwiftUI

// MARK: - Text

enum BTBatteryText {
    /// "L %80 · R %75 · Case %60" for AirPods, "%64" for one level. Percent
    /// placement follows the locale (Turkish puts the sign first).
    /// `includeCase: false` is for the closed-island glance: on a 190 pt
    /// notch the case level left the device name three letters wide, and
    /// the buds are what the user is about to listen on.
    static func levels(_ battery: QuickBattery, includeCase: Bool = true) -> String {
        var parts: [String] = []
        if battery.left != nil || battery.right != nil {
            if let left = battery.left {
                parts.append(String(format: String(localized: "btBattery.left", defaultValue: "L %@"), percent(left)))
            }
            if let right = battery.right {
                parts.append(String(format: String(localized: "btBattery.right", defaultValue: "R %@"), percent(right)))
            }
        } else if let single = battery.single {
            parts.append(percent(single))
        }
        if includeCase, let caseLevel = battery.caseLevel {
            parts.append(String(format: String(localized: "btBattery.case", defaultValue: "Case %@"), percent(caseLevel)))
        }
        return parts.joined(separator: " · ")
    }

    /// The same levels in full words, for VoiceOver.
    static func spoken(_ battery: QuickBattery) -> String {
        var parts: [String] = []
        if let left = battery.left {
            parts.append(String(format: String(localized: "btBattery.spoken.left", defaultValue: "Left %@"), percent(left)))
        }
        if let right = battery.right {
            parts.append(String(format: String(localized: "btBattery.spoken.right", defaultValue: "Right %@"), percent(right)))
        }
        if battery.left == nil, battery.right == nil, let single = battery.single {
            parts.append(String(format: String(localized: "btBattery.spoken.battery", defaultValue: "Battery %@"), percent(single)))
        }
        if let caseLevel = battery.caseLevel {
            parts.append(String(format: String(localized: "btBattery.spoken.case", defaultValue: "Case %@"), percent(caseLevel)))
        }
        return parts.joined(separator: ", ")
    }

    static func percent(_ value: Int) -> String {
        (Double(value) / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    static func symbol(_ kind: BTDeviceKind) -> String {
        switch kind {
        case .headphones: return "headphones"
        case .mouse: return "computermouse"
        case .keyboard: return "keyboard"
        case .trackpad: return "hand.point.up.left"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    /// The glance only carries the name and levels; buds mean headphones.
    static func symbol(_ name: String, battery: QuickBattery?) -> String {
        if battery?.left != nil || battery?.right != nil { return symbol(.headphones) }
        return symbol(BTDeviceKind.classify(name: name, primaryUsagePage: nil, primaryUsage: nil))
    }

    /// Below this a level is drawn orange (the quick toggles' warning colour;
    /// amber is reserved for "live") with a low-battery glyph, so colour is
    /// never the only signal (macOS warns at 10 % for Magic devices; 20 %
    /// gives a day's notice).
    static let lowThreshold = 20
}

// MARK: - Araçlar line

/// One capsule per connected device with a battery level. Draws nothing
/// when there is none (or the feature is off), so the page keeps its
/// layout on a Mac with no Bluetooth accessories.
struct BTBatteryStrip: View {
    @ObservedObject private var monitor: BTBatteryMonitor
    private let fixture: [BTBatteryDevice]?

    static let height: CGFloat = 22

    init(monitor: BTBatteryMonitor = .shared) {
        self.monitor = monitor
        fixture = nil
    }

    #if DEBUG
    /// The frame renderer's devices; the monitor is not started.
    init(fixture: [BTBatteryDevice]) {
        monitor = .shared
        self.fixture = fixture
    }
    #endif

    var body: some View {
        let devices = fixture ?? monitor.devices
        Group {
            if !devices.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(devices) { BTBatteryChip(device: $0) }
                    }
                }
                .frame(height: Self.height)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(String(localized: "btBattery.group", defaultValue: "Bluetooth batteries"))
            }
        }
        .onAppear { if fixture == nil { monitor.setVisible(true) } }
        .onDisappear { if fixture == nil { monitor.setVisible(false) } }
    }
}

private struct BTBatteryChip: View {
    let device: BTBatteryDevice

    private var isLow: Bool {
        [device.battery.left, device.battery.right, device.battery.single].compactMap { $0 }.contains { $0 < BTBatteryText.lowThreshold }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isLow ? "battery.25" : BTBatteryText.symbol(device.kind))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isLow ? Color.orange : PageTokens.textSecondary)
                .frame(width: 14)
            Text(device.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(PageTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 130, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
            Text(BTBatteryText.levels(device.battery))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(isLow ? Color.orange : PageTokens.textSecondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: BTBatteryStrip.height)
        .background(Capsule().fill(PageTokens.raised))
        .help(device.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(device.name)
        .accessibilityValue(BTBatteryText.spoken(device.battery))
    }
}
