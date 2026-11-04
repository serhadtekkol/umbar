//
//  ScreenEdgeGlowView.swift
//  boringNotch
//
//  The light along the screen's top edge beside the notch: on each side a
//  soft band that leaves the notch's edge and runs a short way outward
//  (`screenEdgeGlowSpread` notch widths), fading out toward its end, with
//  a glint travelling the same way. It never reaches the corners.
//
//  Drawn as a stroke along the very top edge, centred on it so half falls
//  off screen and the band reads as light coming in from the bezel.
//  Shadows soften it rather than blur: they are what the window server
//  and the frame renderer both draw (a blur filter does not show in a
//  cached frame). A frame changes only the trims, colour and opacity of a
//  handful of strokes. The clock runs only while the window is on screen
//  and something moves, at most 30 fps (ScreenEdgeGlowPolicy).
//

import Defaults
import SwiftUI

/// One side's band: a line along the top of its frame, from the notch
/// end (leading) outward. `trim` along it is a fraction of the band, as
/// ScreenEdgeGlowPolicy measures it.
struct ScreenEdgeBandLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

/// The two bands for one frame, values in, so the renderer draws
/// fixtures. Laid out from the top centre of whatever holds it.
struct ScreenEdgeGlowRim: View {
    let frame: ScreenEdgeGlowFrame
    let style: EdgeGlowStyle
    /// The band's width on screen, points.
    let thickness: CGFloat
    /// 0.3…1, the user's intensity.
    let intensity: Double
    let notchWidth: CGFloat
    /// One side's length, points (ScreenEdgeGlowPolicy.bandLength).
    let bandLength: CGFloat

    /// The band starts this far under the notch, so the light comes out
    /// from behind it rather than beside it.
    private static let tuck: CGFloat = 6

    var body: some View {
        let width = thickness * CGFloat(frame.spread)
        let length = bandLength + Self.tuck
        HStack(spacing: 0) {
            side(width: width).frame(width: length).scaleEffect(x: -1, y: 1)
            Color.clear.frame(width: max(0, notchWidth - 2 * Self.tuck))
            side(width: width).frame(width: length)
        }
        .frame(height: 1, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(frame.level * intensity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func side(width: CGFloat) -> some View {
        ZStack {
            band(width: width)
            if let glint = frame.glint {
                self.glint(glint, width: width)
            }
        }
    }

    /// The travelling highlight. Three nested lengths of a third of its
    /// strength each, so it tapers at both ends instead of stopping short.
    private func glint(_ glint: ScreenEdgeGlowFrame.Glint, width: CGFloat) -> some View {
        ZStack {
            ForEach([1.0, 0.6, 0.3], id: \.self) { k in
                let half = ScreenEdgeGlowPolicy.glintLength * k / 2
                ScreenEdgeBandLine()
                    .trim(from: max(0, glint.position - half), to: min(1, glint.position + half))
                    .stroke(glint.color, lineWidth: width * 2)
                    .opacity(1.0 / 3)
            }
        }
        .shadow(color: glint.color, radius: width * 1.5)
        .shadow(color: glint.color.opacity(0.6), radius: width * 4)
        .opacity(glint.strength)
    }

    /// The lit part of the band: full at the notch, gone by its end.
    @ViewBuilder
    private func band(width: CGFloat) -> some View {
        let falloff = LinearGradient(stops: [.init(color: frame.color, location: 0),
                                             .init(color: frame.color.opacity(0.6), location: 0.45),
                                             .init(color: frame.color.opacity(0), location: 1)],
                                     startPoint: .leading, endPoint: .trailing)
        let lit = ScreenEdgeBandLine().trim(from: 0, to: frame.reach)
        switch style {
        // A soft edge and the light it throws down over the menu bar.
        case .soft, .pulse:
            lit.stroke(falloff, lineWidth: width * 2)
                .shadow(color: frame.color, radius: width * 1.5)
                .shadow(color: frame.color.opacity(0.8), radius: width * 4)
        // A crisp line at the glass edge with a little bloom.
        case .neon:
            lit.stroke(falloff, lineWidth: width * 0.8)
                .shadow(color: frame.color, radius: 1)
                .shadow(color: frame.color.opacity(0.7), radius: width * 1.6)
        }
    }
}

/// A screen's window content: the shared model's frame, on a clock.
struct ScreenEdgeGlowView: View {
    let screenWidth: CGFloat
    let notchWidth: CGFloat

    @ObservedObject private var model = ScreenEdgeGlowModel.shared
    @Default(.edgeGlowStyle) private var style
    @Default(.screenEdgeGlowThickness) private var thickness
    @Default(.screenEdgeGlowIntensity) private var intensity
    @Default(.screenEdgeGlowSpread) private var spread

    var body: some View {
        let interval = ScreenEdgeGlowPolicy.frameInterval(model.envelope.frameInterval)
        TimelineView(.animation(minimumInterval: interval ?? 1, paused: interval == nil)) { context in
            // Paused, the timeline's date is when it stopped; a steady or
            // an audio frame is drawn now.
            let now = interval == nil ? Date() : context.date
            if let frame = model.frame(at: now) {
                ScreenEdgeGlowRim(frame: frame, style: style, thickness: CGFloat(thickness), intensity: intensity,
                                  notchWidth: notchWidth,
                                  bandLength: ScreenEdgeGlowPolicy.bandLength(
                                      screenWidth: screenWidth, notchWidth: notchWidth, spread: spread))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}
