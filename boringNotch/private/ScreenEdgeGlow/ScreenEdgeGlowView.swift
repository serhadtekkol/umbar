//
//  ScreenEdgeGlowView.swift
//  boringNotch
//
//  The light along the screen's edges: a soft band that starts at the
//  notch, runs along the top edge to the corners and down the sides,
//  fading as it goes, with a glint travelling the same way. It follows
//  the display's own corner rounding.
//
//  Drawn as strokes of the screen's outline, centred on the edge so half
//  of each falls off screen and the band reads as light coming in from
//  the bezel. Shadows soften it rather than blur: they are what the
//  window server and the frame renderer both draw (a blur filter does not
//  show in a cached frame). A frame changes only the trims, colour and
//  opacity of a handful of strokes; the window holds no other view. The
//  clock runs only while the window is on
//  screen and something moves, at most 30 fps (ScreenEdgeGlowPolicy).
//

import Defaults
import SwiftUI

/// One half of the screen's outline: top centre (the notch) round the
/// corner and down the side to the bottom centre. `trim` along it is a
/// fraction of the half rim, as ScreenEdgeGlowPolicy measures it.
struct ScreenEdgeHalfRim: Shape {
    enum Side { case leading, trailing }

    let side: Side
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, rect.width / 2, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.minY + r), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        guard side == .leading else { return p }
        return p.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0))
    }
}

/// The rim for one frame, values in, so the renderer draws fixtures.
struct ScreenEdgeGlowRim: View {
    let frame: ScreenEdgeGlowFrame
    let style: EdgeGlowStyle
    /// The band's width on screen, points.
    let thickness: CGFloat
    /// 0.3…1, the user's intensity.
    let intensity: Double
    let cornerRadius: CGFloat

    var body: some View {
        let width = thickness * CGFloat(frame.spread)
        ZStack {
            ForEach([ScreenEdgeHalfRim.Side.leading, .trailing], id: \.self) { side in
                let rim = ScreenEdgeHalfRim(side: side, cornerRadius: cornerRadius)
                band(rim, width: width)
                if let glint = frame.glint {
                    self.glint(glint, on: rim, width: width)
                }
            }
        }
        .opacity(frame.level * intensity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The travelling highlight. Three nested lengths of a third of its
    /// strength each, so it tapers at both ends instead of stopping short.
    private func glint(_ glint: ScreenEdgeGlowFrame.Glint, on rim: ScreenEdgeHalfRim, width: CGFloat) -> some View {
        ZStack {
            ForEach([1.0, 0.6, 0.3], id: \.self) { k in
                let half = ScreenEdgeGlowPolicy.glintLength * k / 2
                rim.trim(from: max(0, glint.position - half), to: min(1, glint.position + half))
                    .stroke(glint.color, lineWidth: width * 2)
                    .opacity(1.0 / 3)
            }
        }
        .shadow(color: glint.color, radius: width * 1.5)
        .shadow(color: glint.color.opacity(0.6), radius: width * 5)
        .opacity(glint.strength)
    }

    /// The lit part of the rim, brightest at the notch.
    @ViewBuilder
    private func band(_ rim: ScreenEdgeHalfRim, width: CGFloat) -> some View {
        let falloff = LinearGradient(stops: [.init(color: frame.color, location: 0),
                                             .init(color: frame.color.opacity(0.55), location: 0.5),
                                             .init(color: frame.color.opacity(0.2), location: 1)],
                                     startPoint: .top, endPoint: .bottom)
        let lit = rim.trim(from: 0, to: frame.reach)
        switch style {
        // A soft edge and the light it throws inward.
        case .soft, .pulse:
            lit.stroke(falloff, lineWidth: width * 2)
                .shadow(color: frame.color, radius: width * 1.5)
                .shadow(color: frame.color.opacity(0.8), radius: width * 5)
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
    let cornerRadius: CGFloat

    @ObservedObject private var model = ScreenEdgeGlowModel.shared
    @Default(.edgeGlowStyle) private var style
    @Default(.screenEdgeGlowThickness) private var thickness
    @Default(.screenEdgeGlowIntensity) private var intensity

    var body: some View {
        let interval = ScreenEdgeGlowPolicy.frameInterval(model.envelope.frameInterval)
        TimelineView(.animation(minimumInterval: interval ?? 1, paused: interval == nil)) { context in
            // Paused, the timeline's date is when it stopped; a steady or
            // an audio frame is drawn now.
            let now = interval == nil ? Date() : context.date
            if let frame = model.frame(at: now) {
                ScreenEdgeGlowRim(frame: frame, style: style, thickness: CGFloat(thickness),
                                  intensity: intensity, cornerRadius: cornerRadius)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }
}
