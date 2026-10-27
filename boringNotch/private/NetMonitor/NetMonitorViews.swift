//
//  NetMonitorViews.swift
//  boringNotch
//
//  F17 UI: the Ağ page of the open panel and the optional closed-
//  notch ear. Colours and type follow docs/design/design-language.md §3:
//  the island is always black, amber (`island.live`) marks the live
//  download line and arrow only, and always comes with a shape (the
//  arrow, the line), never as colour alone.
//

import Defaults
import SwiftUI

/// §3 tokens this feature uses. Local until UmbarTokens lands, like
/// `MusicSpace` in NotchHomeView.
private enum NetTokens {
    static let textPrimary = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
    static let textSecondary = Color(red: 0xA1 / 255, green: 0xA1 / 255, blue: 0xA6 / 255)
    static let raised = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
    static let track = Color(red: 0x7C / 255, green: 0x7C / 255, blue: 0x80 / 255)
    static let live = Color(red: 0xFF / 255, green: 0xC3 / 255, blue: 0x5C / 255)
}

private enum NetStrings {
    static func networkName(_ network: NetMonitor.CurrentNetwork?) -> String {
        guard let network else {
            return String(localized: "netmonitor.network.none", defaultValue: "Not connected")
        }
        if let name = network.wifiName { return name }
        switch network.kind {
        case .wifi: return String(localized: "netmonitor.network.wifi", defaultValue: "This network (Wi-Fi)")
        case .ethernet: return String(localized: "netmonitor.network.ethernet", defaultValue: "This network (Ethernet)")
        case .cellular: return String(localized: "netmonitor.network.cellular", defaultValue: "This network (cellular)")
        case .other: return String(localized: "netmonitor.network.other", defaultValue: "This network")
        }
    }

    static func glyph(_ kind: NetLinkKind?) -> String {
        switch kind {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .other: return "network"
        case nil: return "wifi.slash"
        }
    }
}

// MARK: - Ağ page

/// The open panel's Ağ page. Draws nothing when the feature is off (the tab
/// is gone then too, see `PanelTab`).
struct NetworkPage: View {
    @Default(.netMonitorEnabled) private var enabled
    @ObservedObject private var monitor = NetMonitor.shared

    var body: some View {
        if enabled {
            NetworkPageContent(
                snapshot: NetPageSnapshot(
                    network: monitor.network, rxRate: monitor.rxRate, txRate: monitor.txRate,
                    history: monitor.history, session: monitor.session, today: monitor.today, month: monitor.month),
                onReset: { monitor.resetCurrentNetwork() })
                .onAppear { monitor.beginObserving() }
                .onDisappear { monitor.endObserving() }
        }
    }
}

/// What the page shows, as plain values, so the offscreen render can feed it.
struct NetPageSnapshot {
    var network: NetMonitor.CurrentNetwork?
    var rxRate: Double
    var txRate: Double
    var history: NetRateHistory
    var session: NetByteTotals
    var today: NetByteTotals
    var month: NetByteTotals
}

struct NetworkPageContent: View {
    let snapshot: NetPageSnapshot
    let onReset: () -> Void
    @State private var confirmReset = false

    static let totalsWidth: CGFloat = 196

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                header
                speeds
                NetSparkline(history: snapshot.history)
                    .frame(maxWidth: .infinity, minHeight: 40, maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            totals
                .frame(width: Self.totalsWidth)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: NetStrings.glyph(snapshot.network?.kind))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NetTokens.textSecondary)
                .accessibilityHidden(true)
            Text(NetStrings.networkName(snapshot.network))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(NetTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(NetStrings.networkName(snapshot.network))
        }
    }

    private var speeds: some View {
        HStack(alignment: .top, spacing: 28) {
            speed(symbol: "arrow.down", value: snapshot.rxRate, tint: NetTokens.live,
                  label: String(localized: "netmonitor.download.a11y", defaultValue: "Download"))
            speed(symbol: "arrow.up", value: snapshot.txRate, tint: NetTokens.textPrimary,
                  label: String(localized: "netmonitor.upload.a11y", defaultValue: "Upload"))
        }
    }

    private func speed(symbol: String, value: Double, tint: Color, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
                Text(NetByteFormat.rate(value))
                    .font(.system(size: 20, weight: .medium).monospacedDigit())
                    .foregroundStyle(NetTokens.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(NetTokens.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(NetByteFormat.rate(value))
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "netmonitor.totals.title", defaultValue: "Totals on this network"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NetTokens.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            totalRow(String(localized: "netmonitor.total.session", defaultValue: "This session"), snapshot.session)
            totalRow(String(localized: "netmonitor.total.today", defaultValue: "Today"), snapshot.today)
            totalRow(String(localized: "netmonitor.total.month", defaultValue: "This month"), snapshot.month)
            resetButton
                .padding(.top, 4)
        }
    }

    /// One figure per row (download + upload together). The split is in
    /// the tooltip and the VoiceOver value.
    private func totalRow(_ title: String, _ totals: NetByteTotals) -> some View {
        let detail = String(
            format: String(localized: "netmonitor.total.detail", defaultValue: "%1$@ down, %2$@ up"),
            NetByteFormat.total(totals.rx), NetByteFormat.total(totals.tx))
        return HStack {
            Text(title)
                .foregroundStyle(NetTokens.textSecondary)
            Spacer(minLength: 4)
            Text(NetByteFormat.total(totals.sum))
                .monospacedDigit()
                .foregroundStyle(NetTokens.textPrimary)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }

    /// Two-step inline confirmation instead of an alert: an alert would
    /// take focus from the panel and close it (hover-to-close).
    private var resetButton: some View {
        HStack(spacing: 6) {
            if confirmReset {
                Button(String(localized: "netmonitor.reset.confirm", defaultValue: "Reset")) {
                    confirmReset = false
                    onReset()
                }
                .buttonStyle(NetCapsuleButtonStyle(primary: true))
                Button(String(localized: "netmonitor.reset.cancel", defaultValue: "Cancel")) {
                    confirmReset = false
                }
                .buttonStyle(NetCapsuleButtonStyle(primary: false))
            } else {
                Button(String(localized: "netmonitor.reset", defaultValue: "Reset totals")) {
                    confirmReset = true
                }
                .buttonStyle(NetCapsuleButtonStyle(primary: false))
                .help(String(localized: "netmonitor.reset.help", defaultValue: "Forget this network's totals. Stored only on this Mac."))
                .disabled(snapshot.network == nil)
            }
        }
        .animation(.easeOut(duration: 0.15), value: confirmReset)
    }
}

/// §3 button rule: primary = white capsule with black text; secondary =
/// `raisedStrong` capsule. Not amber, which only means "live".
private struct NetCapsuleButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(primary ? Color.black : NetTokens.textPrimary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(
                Capsule().fill(primary ? NetTokens.textPrimary : Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Last 60 s of download (amber, filled) and upload (white line), on one
/// shared scale so the two are comparable. Drawn with a Canvas: one draw
/// call per second instead of a view per point.
struct NetSparkline: View {
    let history: NetRateHistory

    var body: some View {
        Canvas { context, size in
            let points = history.points
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            context.stroke(baseline, with: .color(NetTokens.track.opacity(0.6)), lineWidth: 1)
            guard let newest = points.last?.time, points.count >= 2 else { return }

            let peak = history.peak
            func position(_ time: TimeInterval, _ value: Double) -> CGPoint {
                let x = size.width * CGFloat(1 - (newest - time) / history.window)
                // Square-root scale: one 50 MB/s burst would otherwise flatten
                // a minute of 200 KB/s browsing into the baseline.
                let y = size.height - 1 - (size.height - 2) * CGFloat((value / peak).squareRoot())
                return CGPoint(x: x, y: y)
            }

            var download = Path()
            download.move(to: CGPoint(x: position(points[0].time, 0).x, y: size.height))
            for point in points { download.addLine(to: position(point.time, point.rx)) }
            download.addLine(to: CGPoint(x: size.width, y: size.height))
            download.closeSubpath()
            context.fill(download, with: .color(NetTokens.live.opacity(0.35)))

            var downloadEdge = Path()
            var upload = Path()
            for (index, point) in points.enumerated() {
                let rx = position(point.time, point.rx)
                let tx = position(point.time, point.tx)
                if index == 0 {
                    downloadEdge.move(to: rx)
                    upload.move(to: tx)
                } else {
                    downloadEdge.addLine(to: rx)
                    upload.addLine(to: tx)
                }
            }
            context.stroke(downloadEdge, with: .color(NetTokens.live), lineWidth: 1.25)
            context.stroke(upload, with: .color(NetTokens.textPrimary.opacity(0.85)), lineWidth: 1)
        }
    }
}

// MARK: - Closed-notch ear

/// Download/upload in the closed notch, when the user turned it on. A
/// black tab on the leading edge of the notch, mirroring
/// `CaffeinateClosedBadge` on the trailing edge. One ear wide (§4: the
/// island never grows sideways beyond W + 2H), so speeds are in the compact
/// form ("1.2M").
struct NetMonitorClosedBadge: View {
    @Default(.netMonitorEnabled) private var enabled
    @Default(.netMonitorShowInClosedNotch) private var showInClosed
    let isClosed: Bool
    let height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = isClosed && enabled && showInClosed && height > 0
        ZStack {
            if shown {
                // Slides out from under the island's leading edge.
                NetMonitorEar(height: height)
                    .transition(.ear(inward: max(30, height + 6), reduce: reduceMotion))
            }
        }
        .animation(UmbarMotion.ear(reduce: reduceMotion), value: shown)
    }
}

private struct NetMonitorEar: View {
    @ObservedObject private var monitor = NetMonitor.shared
    let height: CGFloat

    private var width: CGFloat { max(30, height + 6) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            line(symbol: "arrow.down", value: monitor.rxRate, tint: NetTokens.live)
            line(symbol: "arrow.up", value: monitor.txRate, tint: NetTokens.textSecondary)
        }
        .font(.system(size: 9, weight: .semibold).monospacedDigit())
        .frame(width: width, height: height)
        .background(.black, in: UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 8))
        .offset(x: -width)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "netmonitor.ear.a11y", defaultValue: "Network speed"))
        .accessibilityValue(String(
            format: String(localized: "netmonitor.ear.a11y.value", defaultValue: "Download %1$@, upload %2$@"),
            NetByteFormat.rate(monitor.rxRate), NetByteFormat.rate(monitor.txRate)))
        .onAppear { monitor.beginObserving() }
        .onDisappear { monitor.endObserving() }
    }

    private func line(symbol: String, value: Double, tint: Color) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(tint)
            Text(NetByteFormat.compactRate(value))
                .foregroundStyle(NetTokens.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}
