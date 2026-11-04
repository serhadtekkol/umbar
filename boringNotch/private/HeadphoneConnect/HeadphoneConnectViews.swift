//
//  HeadphoneConnectViews.swift
//  boringNotch
//
//  The headphone connect glance on the closed island: the island widens out
//  of the notch into two ears, the device glyph on the leading one and its
//  battery on the trailing one, and folds back after the Settings duration
//  (iPhone's AirPods connect, at notch scale). A disconnect gets the same
//  shape with a dimmed glyph and one word, shorter and without the bounce.
//
//  Drawn as an overlay on the island (ContentView), so for its few seconds
//  it covers whatever the closed island was showing and the island's own
//  layout never changes: nothing behind it reflows, and the hover rect is
//  the island's as before. Never hit-testable.
//

import SwiftUI

// MARK: - Overlay

/// Follows HeadphoneConnectMonitor and draws its glance while the island is
/// closed. A glance that arrives while the panel is open is dropped, and
/// opening the panel mid-glance ends it: the user is already looking at the
/// panel, and replaying it after a close would be a stale notice.
///
/// The morph runs on state (`progress`, `opacity`) rather than on an
/// insertion/removal transition: the glance stays in the tree until its
/// fold-back has finished, so the way out animates as reliably as the way in.
struct HeadphoneGlanceOverlay: View {
    let isClosed: Bool
    /// vm.closedNotchSize.width and effectiveClosedNotchHeight.
    let notchWidth: CGFloat
    let height: CGFloat
    /// The frame renderer's Reduce Motion case; the environment value is
    /// read-only, so a render cannot set it from outside.
    var forceReduceMotion = false

    @ObservedObject private var monitor = HeadphoneConnectMonitor.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var shown: HeadphoneGlance?
    @State private var progress: CGFloat = 0
    @State private var opacity: Double = 0
    /// The glance the panel being open swallowed; its later battery updates
    /// must not bring it on screen after a close.
    @State private var droppedID: Int?

    private var reduceMotion: Bool { forceReduceMotion || systemReduceMotion }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let shown, height > 0 {
                    HeadphoneGlanceIsland(
                        glance: shown, notchWidth: notchWidth, height: height,
                        collapsedWidth: max(proxy.size.width, notchWidth),
                        // Reduce Motion: the finished glance, faded in and out.
                        progress: reduceMotion ? 1 : progress,
                        opacity: reduceMotion ? opacity : 1)
                }
            }
            .frame(width: proxy.size.width, height: height, alignment: .top)
        }
        .frame(height: height)
        .allowsHitTesting(false)
        .onReceive(monitor.$glance) { accept($0) }
        .onChange(of: isClosed) { _, closed in
            guard !closed, let current = shown else { return }
            droppedID = current.id
            hide()
        }
    }

    private func accept(_ glance: HeadphoneGlance?) {
        guard let glance else {
            hide()
            return
        }
        guard glance.id != droppedID else { return }
        guard isClosed else {
            droppedID = glance.id
            return
        }
        show(glance)
    }

    private func show(_ glance: HeadphoneGlance) {
        // The same glance again is a level arriving; a new id while one is
        // up swaps the content in place. Either way the shape is already out.
        if let current = shown, progress > 0.5 || opacity > 0.5 {
            if current != glance {
                withAnimation(HeadphoneGlanceMotion.change(reduce: reduceMotion)) { shown = glance }
            }
            return
        }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            shown = glance
            progress = 0
            opacity = 0
        }
        // Next turn, so the folded state is drawn once and the spring has
        // somewhere to start from.
        DispatchQueue.main.async {
            guard self.shown?.id == glance.id else { return }
            withAnimation(HeadphoneGlanceMotion.appear(glance.phase, reduce: reduceMotion)) {
                progress = 1
                opacity = 1
            }
        }
    }

    private func hide() {
        guard let leaving = shown else { return }
        withAnimation(HeadphoneGlanceMotion.disappear(reduce: reduceMotion), completionCriteria: .logicallyComplete) {
            progress = 0
            opacity = 0
        } completion: {
            // A glance that arrived during the fold-back owns the view now.
            guard self.shown?.id == leaving.id, self.progress == 0 else { return }
            self.shown = nil
        }
    }
}

// MARK: - Island

/// The glance: its black and its two ears, at `progress` (0 = folded into
/// the island it overlays, 1 = out, a little past 1 on the bounce) and
/// `opacity`. Animatable, so the overlay's state animation redraws it every
/// frame. Also drawn directly by the frame renderer.
///
/// The ears are as wide as their content, each anchored to its edge of the
/// notch: a glyph on the left, the levels on the right. The frame is
/// symmetric (twice the wider ear) so the notch stays centred; the black
/// only covers what the ears use.
struct HeadphoneGlanceIsland: View, Animatable {
    let glance: HeadphoneGlance
    /// vm.closedNotchSize.width: the island's width at rest, flares included.
    let notchWidth: CGFloat
    let height: CGFloat
    /// The island's current width, at least `notchWidth`. The folded glance
    /// is exactly this wide, and each ear reaches at least as far, so a wide
    /// closed island (music) is covered rather than poking out.
    var collapsedWidth: CGFloat
    var progress: CGFloat = 1
    var opacity: Double = 1

    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, Double> {
        get { AnimatablePair(progress, opacity) }
        set {
            progress = newValue.first
            opacity = newValue.second
        }
    }

    var body: some View {
        // How far the island already reaches past the notch on each side.
        let resting = max(0, (collapsedWidth - notchWidth) / 2)
        let leadingEar = max(leadingWidth, resting)
        let trailingEar = max(trailingWidth, resting)
        let half = max(leadingEar, trailingEar)
        let shape = HeadphoneGlanceShape(
            leadingReach: resting + (leadingEar - resting) * progress,
            trailingReach: resting + (trailingEar - resting) * progress,
            notchWidth: notchWidth)
        HStack(spacing: 0) {
            leadingEarView
                .frame(width: half, alignment: .trailing)
            // The hardware notch (and the island's flares): nothing drawn here.
            Color.clear.frame(width: notchWidth)
            trailingEarView
                .frame(width: half, alignment: .leading)
        }
        // Ears show fully only near the end, as the black uncovers them.
        .opacity(Double(min(1, max(0, (progress - 0.35) / 0.65))))
        .clipShape(shape)
        .background(shape.fill(.black))
        .frame(width: notchWidth + 2 * half, height: height)
        .opacity(opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var leadingEarView: some View {
        leading
            .padding(.leading, outerPadding)
            .padding(.trailing, 6)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leadingWidth = $0 }
    }

    private var trailingEarView: some View {
        trailing
            .padding(.leading, 6)
            .padding(.trailing, outerPadding)
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
    }

    /// Clear of the bottom corner's curve.
    private var outerPadding: CGFloat { max(10, cornerRadiusInsets.closed.bottom - 2) }

    private var glyphSize: CGFloat { min(22, max(14, height * 0.5)) }
    private var textSize: CGFloat { height >= 40 ? 13 : 12 }

    private var leading: some View {
        Image(systemName: glance.output.model.symbol)
            .font(.system(size: glyphSize, weight: .medium))
            .foregroundStyle(glance.phase == .connected ? HeadphoneGlanceTokens.textPrimary : HeadphoneGlanceTokens.textSecondary)
            .frame(height: height)
    }

    @ViewBuilder
    private var trailing: some View {
        switch glance.phase {
        case .disconnected:
            label(String(localized: "headphoneGlance.disconnected", defaultValue: "Disconnected"))
        case .connected:
            if let battery = glance.battery, !battery.isEmpty {
                HeadphoneBatteryLevels(battery: battery, textSize: textSize)
                    .frame(height: height)
                    .transition(.opacity)
            } else {
                label(String(localized: "liveActivity.bluetooth.connected", defaultValue: "Connected"))
                    .transition(.opacity)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: textSize, weight: .medium))
            .foregroundStyle(HeadphoneGlanceTokens.textSecondary)
            .lineLimit(1)
            .fixedSize()
            .frame(height: height)
    }

    private var accessibilityText: String {
        let name = glance.output.name
        switch glance.phase {
        case .disconnected:
            return String(format: String(localized: "headphoneGlance.a11y.disconnected", defaultValue: "%@ disconnected"), name)
        case .connected:
            let connected = String(format: String(localized: "headphoneGlance.a11y.connected", defaultValue: "%@ connected"), name)
            guard let battery = glance.battery, !battery.isEmpty else { return connected }
            return "\(connected), \(BTBatteryText.spoken(battery))"
        }
    }
}

/// "%80" when both buds agree (or for one level), "L %80  R %75" when they
/// do not, then the case with its glyph. Low levels turn orange and get a
/// low-battery glyph, so colour is never the only signal.
private struct HeadphoneBatteryLevels: View {
    let battery: QuickBattery
    let textSize: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            if isLow {
                Image(systemName: "battery.25")
                    .font(.system(size: textSize - 1, weight: .semibold))
                    .foregroundStyle(Color.orange)
            }
            ForEach(Array(budTexts.enumerated()), id: \.offset) { _, piece in
                level(piece.text, low: piece.low, primary: true)
            }
            if let caseLevel = battery.caseLevel {
                HStack(spacing: 3) {
                    Image(systemName: "airpods.chargingcase")
                        .font(.system(size: textSize - 2))
                    level(BTBatteryText.percent(caseLevel), low: caseLevel < BTBatteryText.lowThreshold, primary: false)
                }
                .foregroundStyle(HeadphoneGlanceTokens.textSecondary)
            }
        }
        .fixedSize()
    }

    private var budTexts: [(text: String, low: Bool)] {
        let low = { (v: Int) in v < BTBatteryText.lowThreshold }
        switch (battery.left, battery.right) {
        case let (l?, r?) where l != r:
            return [
                (String(format: String(localized: "btBattery.left", defaultValue: "L %@"), BTBatteryText.percent(l)), low(l)),
                (String(format: String(localized: "btBattery.right", defaultValue: "R %@"), BTBatteryText.percent(r)), low(r)),
            ]
        case let (l?, _), let (nil, l?):
            return [(BTBatteryText.percent(l), low(l))]
        case (nil, nil):
            return battery.single.map { [(BTBatteryText.percent($0), low($0))] } ?? []
        }
    }

    private var isLow: Bool {
        [battery.left, battery.right, battery.single, battery.caseLevel].compactMap { $0 }
            .contains { $0 < BTBatteryText.lowThreshold }
    }

    private func level(_ text: String, low: Bool, primary: Bool) -> some View {
        Text(text)
            .font(.system(size: textSize, weight: primary ? .semibold : .medium).monospacedDigit())
            .foregroundStyle(low ? Color.orange : (primary ? HeadphoneGlanceTokens.textPrimary : HeadphoneGlanceTokens.textSecondary))
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Shape and motion

// TODO(emrullah): replace with UmbarTokens once #6 adds it (design-language §3).
private enum HeadphoneGlanceTokens {
    static let textPrimary = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
    static let textSecondary = Color(red: 0xA1 / 255, green: 0xA1 / 255, blue: 0xA6 / 255)
}

/// The glance's black: NotchShape spanning the notch plus `leadingReach`
/// and `trailingReach` on either side, centred in its rect on the notch.
/// The reaches grow from the island's own (folded) to the ears' (out); on
/// the spring's overshoot they pass the ears by a few points, which is the
/// bounce.
struct HeadphoneGlanceShape: Shape {
    var leadingReach: CGFloat
    var trailingReach: CGFloat
    let notchWidth: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(leadingReach, trailingReach) }
        set {
            leadingReach = newValue.first
            trailingReach = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let left = rect.midX - notchWidth / 2 - max(0, leadingReach)
        let width = notchWidth + max(0, leadingReach) + max(0, trailingReach)
        return NotchShape(
            topCornerRadius: cornerRadiusInsets.closed.top,
            bottomCornerRadius: cornerRadiusInsets.closed.bottom
        )
        .path(in: CGRect(x: left, y: rect.minY, width: width, height: rect.height))
    }
}

enum HeadphoneGlanceMotion {
    /// The connect: out of the notch on a spring with a visible bounce, the
    /// one place on the closed island that overshoots on purpose (it is a
    /// moment, not a state). The disconnect is plainer: no bounce.
    /// Reduce Motion: a fade.
    static func appear(_ phase: HeadphoneGlance.Phase, reduce: Bool) -> Animation {
        if reduce { return .easeOut(duration: 0.2) }
        return phase == .connected
            ? .spring(response: 0.42, dampingFraction: 0.68)
            : .spring(response: 0.32, dampingFraction: 0.95)
    }

    /// Back into the notch, quicker than it came.
    static func disappear(reduce: Bool) -> Animation {
        reduce ? .easeIn(duration: 0.2) : .spring(response: 0.3, dampingFraction: 1)
    }

    /// A level arriving while the glance is up, or the glance changing.
    static func change(reduce: Bool) -> Animation {
        reduce ? .easeOut(duration: 0.2) : .spring(response: 0.34, dampingFraction: 0.86)
    }
}
