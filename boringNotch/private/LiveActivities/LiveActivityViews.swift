//
//  LiveActivityViews.swift
//  boringNotch
//
//  F19 live activities in the notch:
//  - `LiveActivityClosedStrip`: the closed island grows *downward* by one
//    strip and never sideways past the closed-activity width
//    (design-language §1 rule 2, §4).
//  - `LiveActivityNowRow`: one row on the open panel's "Şimdi" page.
//
//  Self-contained on purpose (no shared island components yet): colours are
//  the design-language §3.1 token values, spelled out until UmbarTokens lands.
//

import AppKit
import Defaults
import SwiftUI

// TODO(emrullah): replace with UmbarTokens once #6 adds it (design-language §3).
private enum LiveTokens {
    static let textPrimary = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
    static let textSecondary = Color(red: 0xA1 / 255, green: 0xA1 / 255, blue: 0xA6 / 255)
    static let track = Color(red: 0x7C / 255, green: 0x7C / 255, blue: 0x80 / 255)
    static let raised = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
    /// Amber means "live" only, always with a shape (rule 3).
    static let live = Color(red: 0xFF / 255, green: 0xC3 / 255, blue: 0x5C / 255)
    static let success = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
}

// MARK: - Text

/// The words and numbers for one activity. Shared by the strip, the row and
/// the VoiceOver label so all three say the same thing.
enum LiveActivityText {
    static func title(_ a: LiveActivity) -> String {
        switch a.kind {
        case .download, .airDrop:
            return a.title.isEmpty
                ? String(localized: "liveActivity.download.unnamed", defaultValue: "Downloading…")
                : a.title
        case .timeMachine:
            return String(localized: "liveActivity.timeMachine.title", defaultValue: "Time Machine")
        case .charging:
            return String(localized: "liveActivity.charging.title", defaultValue: "Charging")
        }
    }

    static func detail(_ a: LiveActivity) -> String {
        switch (a.kind, a.phase) {
        case (.download, .running):
            var parts: [String] = []
            if let fraction = a.fraction {
                parts.append(fraction.formatted(.percent.precision(.fractionLength(0))))
            } else if let bytes = a.bytesSoFar {
                parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            }
            if let rate = a.bytesPerSecond, rate > 0 {
                let size = ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file)
                parts.append(String(localized: "liveActivity.download.speed", defaultValue: "\(size)/s"))
            }
            return parts.joined(separator: " · ")
        case (.download, .finished):
            return String(localized: "liveActivity.download.finished", defaultValue: "Downloaded")
        case (.airDrop, _):
            return String(localized: "liveActivity.airDrop.received", defaultValue: "Received via AirDrop")
        case (.timeMachine, _):
            return String(localized: "liveActivity.timeMachine.finished", defaultValue: "Backup finished")
        case (.charging, _):
            let percent = (Double(a.percent ?? 0) / 100).formatted(.percent.precision(.fractionLength(0)))
            guard let minutes = a.minutesRemaining else {
                return String(localized: "liveActivity.charging.estimating", defaultValue: "\(percent) · estimating time to full")
            }
            let duration = Self.duration.string(from: TimeInterval(minutes * 60)) ?? ""
            return String(localized: "liveActivity.charging.timeToFull", defaultValue: "\(percent) · full in \(duration)")
        }
    }

    static func symbol(_ a: LiveActivity) -> String {
        switch (a.kind, a.phase) {
        case (.download, .running): return "arrow.down.circle"
        case (.download, .finished): return "checkmark.circle"
        case (.airDrop, _): return "dot.radiowaves.left.and.right"
        case (.timeMachine, _): return "clock.arrow.circlepath"
        case (.charging, _): return "bolt.fill"
        }
    }

    /// "1 h 12 min" in the user's language.
    private static let duration: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute]
        f.unitsStyle = .abbreviated
        f.zeroFormattingBehavior = .dropAll
        return f
    }()
}

// MARK: - Closed island strip

/// The strip under the closed notch. Draws nothing when no activity is
/// live, so the island keeps its normal height.
struct LiveActivityClosedStrip: View {
    /// Notch width W and height H (vm.closedNotchSize.width / effectiveClosedNotchHeight).
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    @ObservedObject private var center = LiveActivityCenter.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Same order of size as the HUD banner (design-language §4: 34 pt).
    static let height: CGFloat = 30

    /// The width the closed music activity already uses (ContentView's
    /// `computedChinWidth`): W plus one ear of (H - 12) + 10 on each side.
    /// Matching it exactly matters because the closed layout is
    /// leading-aligned: a strip wider than the music row would push the
    /// album art off its ear. Design-language §4 asks for W + 2H; switch both
    /// together when the EarSlots model (#10) lands.
    static func width(notchWidth: CGFloat, notchHeight: CGFloat) -> CGFloat {
        notchWidth + 2 * max(0, notchHeight - 12) + 20
    }

    var body: some View {
        if let first = center.stripItems.first {
            LiveActivityLine(activity: first, extraCount: center.stripItems.count - 1, compact: true)
                .padding(.horizontal, 8)
                .frame(width: Self.width(notchWidth: notchWidth, notchHeight: notchHeight), height: Self.height)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: first)
        }
    }
}

// MARK: - "Şimdi" page row

/// A one-line list of what is live, below the music and calendar columns.
/// Draws nothing when nothing is live.
struct LiveActivityNowRow: View {
    @ObservedObject private var center = LiveActivityCenter.shared

    var body: some View {
        if !center.panelItems.isEmpty {
            HStack(spacing: 8) {
                // Three fit the 640 pt panel without truncating a typical file
                // name; the count of the rest goes on the last chip.
                ForEach(center.panelItems.prefix(3)) { item in
                    LiveActivityLine(activity: item, extraCount: 0, compact: false)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(LiveTokens.raised, in: Capsule())
                }
                if center.panelItems.count > 3 {
                    Text(verbatim: "+\(center.panelItems.count - 3)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(LiveTokens.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "liveActivity.row.label", defaultValue: "Live activities"))
        }
    }
}

// MARK: - Shared line

private struct LiveActivityLine: View {
    let activity: LiveActivity
    let extraCount: Int
    let compact: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: LiveActivityText.symbol(activity))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(glyphColor)
                .frame(width: 14)
            Text(LiveActivityText.title(activity))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LiveTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(compact ? 0 : 1)
            if compact { Spacer(minLength: 4) }
            Text(LiveActivityText.detail(activity))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(LiveTokens.textSecondary)
                .lineLimit(1)
                .fixedSize()
            if extraCount > 0 {
                Text(verbatim: "+\(extraCount)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(LiveTokens.textSecondary)
                    .fixedSize()
            }
            if !compact, let url = activity.fileURL {
                Button {
                    LiveActivityCenter.shared.addToShelf(url)
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 11))
                        .foregroundStyle(LiveTokens.textPrimary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(String(localized: "liveActivity.addToShelf", defaultValue: "Add to shelf"))
                .accessibilityLabel(String(localized: "liveActivity.addToShelf", defaultValue: "Add to shelf"))
            }
        }
        .overlay(alignment: .bottom) {
            if let fraction = activity.fraction, activity.phase == .running {
                ProgressTrack(fraction: fraction)
                    .offset(y: compact ? 6 : 4)
            }
        }
        .contentShape(Rectangle())
        // Drag a finished file straight onto the shelf, Finder or any app.
        .conditionalOnDrag(url: activity.fileURL)
        .help(LiveActivityText.title(activity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(LiveActivityText.title(activity)), \(LiveActivityText.detail(activity))")
    }

    private var glyphColor: Color {
        switch activity.phase {
        case .running: return LiveTokens.live
        case .finished: return activity.kind == .timeMachine || activity.kind == .download
            ? LiveTokens.success : LiveTokens.textPrimary
        }
    }
}

/// 2 pt track with a primary-colour fill (design-language §3.1: fill on
/// `track`, 3.82:1).
private struct ProgressTrack: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(LiveTokens.track)
                Capsule().fill(LiveTokens.textPrimary)
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}

private extension View {
    @ViewBuilder
    func conditionalOnDrag(url: URL?) -> some View {
        if let url {
            onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        } else {
            self
        }
    }
}
