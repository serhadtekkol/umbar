//
//  CaffeinateControl.swift
//  boringNotch
//
//  F11 UI: the open-panel control and the always-visible closed badge.
//

import SwiftUI

/// Header control. Off: a cup button that reveals the duration chips inline
/// (no popup, so the notch's hover-to-close logic is not disturbed).
/// On: filled cup plus remaining time; one tap turns it off.
struct CaffeinateControl: View {
    @ObservedObject private var service = CaffeinateService.shared
    @State private var showDurations = false

    var body: some View {
        HStack(spacing: 4) {
            if let notice = service.notice {
                Text(notice)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.orange)
            }
            if service.isActive {
                if let remaining = service.remaining {
                    Text(CaffeinatePolicy.remainingLabel(remaining))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                }
                cupButton(filled: true)
            } else {
                if showDurations {
                    ForEach(CaffeinateDuration.allCases, id: \.self) { duration in
                        Button(Self.label(for: duration)) {
                            showDurations = false
                            service.start(duration)
                        }
                        .buttonStyle(.plain)
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                        .background(Capsule().fill(.white.opacity(0.18)))
                        .accessibilityLabel(Self.accessibilityLabel(for: duration))
                    }
                }
                cupButton(filled: false)
            }
        }
        .animation(.smooth(duration: 0.2), value: showDurations)
        .onChange(of: service.isActive) { _, _ in showDurations = false }
    }

    private func cupButton(filled: Bool) -> some View {
        Button {
            if service.isActive { service.stop() } else { showDurations.toggle() }
        } label: {
            Capsule()
                .fill(.black)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: filled ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .foregroundColor(filled ? .orange : .white)
                        .imageScale(.medium)
                }
        }
        .buttonStyle(PlainButtonStyle())
        .help(filled
            ? String(localized: "caffeinate.help.on", defaultValue: "Keeping the Mac awake. Click to turn off.")
            : String(localized: "caffeinate.help.off", defaultValue: "Keep the Mac awake"))
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

    var body: some View {
        if isClosed && service.isActive {
            Image(systemName: "cup.and.saucer.fill")
                .font(.system(size: max(9, side - 8)))
                .foregroundStyle(.orange)
                .frame(width: side + 6, height: height)
                .background(.black, in: UnevenRoundedRectangle(bottomTrailingRadius: 8, topTrailingRadius: 0))
                .offset(x: side + 6)
                .allowsHitTesting(false)
                .accessibilityLabel(String(localized: "caffeinate.badge.a11y", defaultValue: "Caffeinate is on"))
                .transition(.opacity)
        }
    }
}
