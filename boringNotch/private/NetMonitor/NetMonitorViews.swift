//
//  NetMonitorViews.swift
//  boringNotch
//
//  F17 UI: the network column on the Şimdi page and the optional closed-
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
    static let columnWidth: CGFloat = 150
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

// MARK: - Şimdi column

/// The network column for the open panel's Şimdi page. Draws nothing when
/// the feature is off, so it can be dropped into the page's HStack as is.
struct NetMonitorPanelView: View {
    @Default(.netMonitorEnabled) private var enabled

    var body: some View {
        if enabled {
            NetMonitorPanelContent()
                .frame(width: NetTokens.columnWidth)
                .transition(.opacity)
        }
    }
}

private struct NetMonitorPanelContent: View {
    @ObservedObject private var monitor = NetMonitor.shared
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            speeds
            NetSparkline(history: monitor.history)
                .frame(height: 28)
                .accessibilityHidden(true)
            totals
        }
        .onAppear { monitor.beginObserving() }
        .onDisappear { monitor.endObserving() }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: NetStrings.glyph(monitor.network?.kind))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NetTokens.textSecondary)
                .accessibilityHidden(true)
            Text(NetStrings.networkName(monitor.network))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NetTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(NetStrings.networkName(monitor.network))
        }
    }

    private var speeds: some View {
        HStack(spacing: 10) {
            speed(symbol: "arrow.down", value: monitor.rxRate, tint: NetTokens.live,
                  label: String(localized: "netmonitor.download.a11y", defaultValue: "Download"))
            speed(symbol: "arrow.up", value: monitor.txRate, tint: NetTokens.textPrimary,
                  label: String(localized: "netmonitor.upload.a11y", defaultValue: "Upload"))
        }
    }

    private func speed(symbol: String, value: Double, tint: Color, label: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
            Text(NetByteFormat.rate(value))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(NetTokens.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(NetByteFormat.rate(value))
    }

    private var totals: some View {
        VStack(alignment: .leading, spacing: 2) {
            totalRow(String(localized: "netmonitor.total.session", defaultValue: "This session"), monitor.session)
            totalRow(String(localized: "netmonitor.total.today", defaultValue: "Today"), monitor.today)
            totalRow(String(localized: "netmonitor.total.month", defaultValue: "This month"), monitor.month)
            resetButton
                .padding(.top, 2)
        }
    }

    /// One figure per row (download + upload together). The split is in
    /// the tooltip and the VoiceOver value; the row stays one line at
    /// 150 pt.
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
        .font(.system(size: 11))
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
                    monitor.resetCurrentNetwork()
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
                .disabled(monitor.network == nil)
            }
        }
        .animation(.smooth(duration: 0.15), value: confirmReset)
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
            .padding(.horizontal, 8)
            .frame(height: 20)
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

    var body: some View {
        if isClosed && enabled && showInClosed && height > 0 {
            NetMonitorEar(height: height)
                .transition(.opacity)
        }
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
