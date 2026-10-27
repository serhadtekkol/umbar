//
//  CaffeinateControl.swift
//  boringNotch
//
//  F11 UI: the Araçlar tile and the always-visible closed badge.
//

import SwiftUI

/// Araçlar tile. Off: the duration chips, one tap starts. On: remaining
/// time and "Turn off". Inline only, no popup, so the notch's
/// hover-to-close logic is not disturbed.
struct CaffeinateTile: View {
    @ObservedObject private var service = CaffeinateService.shared

    var body: some View {
        ToolTile(
            symbol: service.isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
            title: String(localized: "Caffeinate"),
            status: status,
            statusTint: service.notice == nil ? PageTokens.textSecondary : Color(red: 0xFF / 255, green: 0x7B / 255, blue: 0x72 / 255),
            active: service.isActive
        ) {
            if service.isActive {
                Button(String(localized: "tools.turnOff", defaultValue: "Turn off")) { service.stop() }
                    .buttonStyle(ToolChipStyle())
                    .help(String(localized: "caffeinate.help.on", defaultValue: "Keeping the Mac awake. Click to turn off."))
            } else {
                HStack(spacing: 4) {
                    ForEach(CaffeinateDuration.allCases, id: \.self) { duration in
                        Button(Self.label(for: duration)) { service.start(duration) }
                            .buttonStyle(ToolChipStyle())
                            .accessibilityLabel(Self.accessibilityLabel(for: duration))
                    }
                }
            }
        }
    }

    private var status: String {
        if let notice = service.notice { return notice }
        guard service.isActive else {
            return String(localized: "caffeinate.help.off", defaultValue: "Keep the Mac awake")
        }
        if let remaining = service.remaining {
            return String(format: String(localized: "tools.remaining", defaultValue: "%@ left"), CaffeinatePolicy.remainingLabel(remaining))
        }
        return String(localized: "caffeinate.duration.indefinite.a11y", defaultValue: "Until turned off")
    }

    private static func label(for duration: CaffeinateDuration) -> String {
        switch duration {
        case .indefinite: return "∞"
        case .minutes15: return String(localized: "caffeinate.duration.15m", defaultValue: "15m")
        case .hour1: return String(localized: "caffeinate.duration.1h", defaultValue: "1h")
        case .hours2: return String(localized: "caffeinate.duration.2h", defaultValue: "2h")
        }
    }

    /// What VoiceOver reads for each chip; "∞" alone says nothing.
    private static func accessibilityLabel(for duration: CaffeinateDuration) -> String {
        switch duration {
        case .indefinite: return String(localized: "caffeinate.duration.indefinite.a11y", defaultValue: "Until turned off")
        case .minutes15: return String(localized: "caffeinate.duration.15m.a11y", defaultValue: "15 minutes")
        case .hour1: return String(localized: "caffeinate.duration.1h.a11y", defaultValue: "1 hour")
        case .hours2: return String(localized: "caffeinate.duration.2h.a11y", defaultValue: "2 hours")
        }
    }
}

/// Closed-notch badge (AC-11.3). Drawn as a small black tab attached to the
/// trailing edge of the notch shape so it shows next to the hardware notch
/// whatever else (music, face) is occupying the ears.
struct CaffeinateClosedBadge: View {
    @ObservedObject private var service = CaffeinateService.shared
    let isClosed: Bool
    let height: CGFloat

    private var side: CGFloat { max(16, height - 8) }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The container stays so the ear's insertion and removal animate on
        // their own spring, whatever transaction flipped the service state.
        ZStack {
            if isClosed && service.isActive { badge }
        }
        .animation(UmbarMotion.ear(reduce: reduceMotion), value: isClosed && service.isActive)
    }

    private var badge: some View {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: max(9, side - 8)))
                .foregroundStyle(.orange)
                .frame(width: side + 6, height: height)
                .background(.black, in: UnevenRoundedRectangle(bottomTrailingRadius: 8, topTrailingRadius: 0))
                .offset(x: side + 6)
                .allowsHitTesting(false)
                .accessibilityLabel(String(localized: "caffeinate.badge.a11y", defaultValue: "Caffeinate is on"))
                // Slides out from under the island's trailing edge.
                .transition(.ear(inward: -(side + 6), reduce: reduceMotion))
    }
}
