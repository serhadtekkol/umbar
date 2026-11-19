//
//  DripLayer.swift
//  boringNotch
//
//  ContentView's slot for the liquid drip: a drop of the island's black
//  that hangs from its bottom edge toward a pointer below it, follows the
//  pointer sideways, and draws back or pinches off and falls when it
//  leaves, with a small ripple where it let go (NotchDripPolicy.swift).
//
//  Drawn over the island, after EdgeGlow: the glow lights the island's
//  silhouette alone and is not recomputed while the drip moves, and the
//  drip's black sits in front of the glow like the island's own. Only the
//  part below the edge is drawn, so it never covers the island's content.
//
//  Gooey look: the drip, its drops and a strip of the edge are drawn into
//  one layer that is blurred and cut at half coverage (alpha threshold),
//  so they merge with a liquid fillet and a drop pinches off by itself as
//  it falls away. Ripples are plain strokes over it.
//
//  Cost: the simulation steps at ~60 Hz only while something moves. A
//  pointer standing still near the island, or none near, schedules
//  nothing; with the panel open the monitor is stopped and nothing steps.
//  Visual only: no hits, nothing for VoiceOver.
//

import Combine
import Defaults
import SwiftUI

/// The monitor's drip readings, handed to DripLayer without passing
/// through ContentView's state (a pointer event must not rebuild the island).
@MainActor final class DripPointer: ObservableObject {
    @Published var reading: NotchDripReading?
}

struct DripLayer: View {
    /// The closed island's width; the drip's x is a share of it.
    let width: CGFloat
    /// False once the panel opens (or the hello animation runs).
    let isClosed: Bool
    let pointer: DripPointer

    @State private var sim = NotchDripSim()
    @State private var target: NotchDripReading?
    @State private var ticking = false
    /// Readings wait for a close to finish moving (UmbarMotion.closeSettle).
    @State private var readyAt: TimeInterval = 0

    @Default(.notchBackdropStyle) private var backdropStyle
    @Default(.notchGlassOpacity) private var glassOpacity
    @Default(.notchGlassWhenClosed) private var glassWhenClosed
    @Default(.useNotchAreaForContent) private var useNotchAreaForContent
    @ObservedObject private var coordinator = BoringViewCoordinator.shared

    private var usesGlass: Bool {
        let hasPhysicalNotch = (NSScreen.screen(withUUID: coordinator.selectedScreenUUID)?.safeAreaInsets.top ?? 0) > 0
        return backdropStyle != .solid && (glassWhenClosed || (useNotchAreaForContent && !hasPhysicalNotch))
    }

    private var dripFillColor: Color {
        guard usesGlass else { return .black }
        let darkness = min(max(glassOpacity, 0.15), 0.75)
        return Color(white: 0.18, opacity: min(0.88, darkness + 0.32))
    }

    var body: some View {
        ZStack {
            if sim.isVisible {
                let fillColor = dripFillColor
                let glassRim = usesGlass
                Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                    DripArt.draw(sim, in: &context, size: size, fillColor: fillColor, glassRim: glassRim)
                }
            }
        }
        .frame(width: width, height: DripArt.height)
        // Drawn up into the edge as it fades, so the opening shape takes it in.
        .scaleEffect(x: 1, y: isClosed ? 1 : 0.3, anchor: UnitPoint(x: 0.5, y: DripArt.top / DripArt.height))
        .opacity(isClosed ? 1 : 0)
        .animation(UmbarMotion.dripOut, value: isClosed)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(pointer.$reading) { receive($0) }
        #if DEBUG
        .onReceive(DripFixture.shared.$reading.dropFirst()) { receive($0) }
        #endif
        .onChange(of: isClosed) { _, closed in
            if closed {
                readyAt = ProcessInfo.processInfo.systemUptime + UmbarMotion.closeSettle
            } else {
                // Frozen where it is while it fades into the opening shape:
                // stepping on with no pull would pinch a drop over the panel.
                target = nil
                ticking = false
            }
        }
        .task(id: isClosed) {
            guard !isClosed else { return }
            try? await Task.sleep(for: .seconds(0.12))
            guard !Task.isCancelled, !isClosed else { return }
            sim = NotchDripSim()
        }
        .task(id: ticking) {
            guard ticking else { return }
            var last = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                let now = ProcessInfo.processInfo.systemUptime
                sim.step(dt: min(now - last, 1.0 / 30), target: target, tuning: UmbarMotion.drip)
                last = now
                if sim.isAtRest(target: target) { break }
            }
            ticking = false
        }
    }

    private func receive(_ reading: NotchDripReading?) {
        guard isClosed else { return }
        let raw = ProcessInfo.processInfo.systemUptime >= readyAt ? reading : nil
        // Non-linear magnetic tension curve: subtle meniscus at outer reach,
        // accelerating smoothly as the pointer approaches the edge.
        let next = raw.map { r -> NotchDripReading in
            let t = min(max(r.pull, 0), 1)
            let smooth = t * t * (3 - 2 * t)
            return NotchDripReading(pull: pow(smooth, 1.15), x: r.x)
        }
        target = next
        if !ticking, !sim.isAtRest(target: next) { ticking = true }
    }
}

/// The drawing, in the Canvas's space: y = `top` is the island's bottom
/// edge, x is 0...width across the island.
enum DripArt {
    /// The strip of edge drawn above the island's bottom (inside the goo
    /// layer only, clipped away) so the blur has a straight edge to merge into.
    static let top: CGFloat = 12
    static var height: CGFloat {
        top + UmbarMotion.dripLook.maxLength * (UmbarMotion.drip.fall + 0.6)
    }

    static func draw(_ sim: NotchDripSim, in context: inout GraphicsContext, size: CGSize, fillColor: Color = .black, glassRim: Bool = false) {
        let edge = top
        let look = UmbarMotion.dripLook
        let unit = look.maxLength

        // Nothing above the edge, and nothing past the flat part of it:
        // half a point up seals the seam against the island's antialiased
        // bottom, where the island is still black.
        let flat = cornerRadiusInsets.closed.bottom + UmbarMotion.hoverHintRadius
        context.clip(to: Path(CGRect(x: flat, y: edge - 0.5, width: max(0, size.width - 2 * flat), height: size.height)))

        // The ripple, under the drip: a flat ring spreading from where the
        // drop let go, a dark band and a light one so it reads on any wallpaper.
        let life = UmbarMotion.drip.rippleLife
        for ripple in sim.ripples where ripple.age >= 0 {
            let t = min(max(ripple.age / life, 0), 1)
            let e = 1 - pow(1 - t, 3)
            let fade = 1 - t
            // Scaled with the drip: about as wide as its root at full size.
            let rx = 8 + (14 + 22 * ripple.size) * e
            let ry = rx * 0.3
            let center = CGPoint(x: ripple.x * size.width, y: edge)
            let dark = Path(ellipseIn: CGRect(x: center.x - rx, y: center.y - ry, width: 2 * rx, height: 2 * ry))
            context.stroke(dark, with: .color(.black.opacity(0.5 * fade)), lineWidth: 1.6)
            let light = Path(ellipseIn: CGRect(x: center.x - rx - 1.6, y: center.y - ry - 1,
                                               width: 2 * (rx + 1.6), height: 2 * (ry + 1)))
            context.stroke(light, with: .color(.white.opacity(0.28 * fade)), lineWidth: 1)
        }

        context.drawLayer { goo in
            // Applied last added first: blur, cut, then a hair of blur so
            // the cut edge is antialiased rather than stair-stepped.
            goo.addFilter(.blur(radius: 0.5))
            goo.addFilter(.alphaThreshold(min: 0.5, color: fillColor))
            goo.addFilter(.blur(radius: UmbarMotion.dripGoo))
            goo.drawLayer { layer in
                // A point short of the edge, so its own cut never shows
                // as a line under the island.
                layer.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: edge - 1)), with: .color(.black))
                if let shape = NotchDripShape(sim, width: size.width, flat: flat, look: look) {
                    // A wide sag at the root that flares down into a thick
                    // neck and the bulb, as liquid hangs off an edge.
                    let rootX = shape.rootX, rootHalf = shape.rootHalf, neckHalf = shape.neckHalf
                    let r = shape.radius
                    let bulb = CGPoint(x: shape.bulb.x, y: edge + shape.bulb.y)
                    let depth = bulb.y - edge
                    // Where each side leaves the edge's flat: never inside
                    // the neck, or a leaning bulb hooks the trailing side.
                    let rightShoulder = max(rootX + rootHalf * 0.5, bulb.x + neckHalf)
                    let leftShoulder = min(rootX - rootHalf * 0.5, bulb.x - neckHalf)
                    var neck = Path()
                    neck.move(to: CGPoint(x: rootX - rootHalf, y: edge - 2))
                    neck.addLine(to: CGPoint(x: rootX + rootHalf, y: edge - 2))
                    neck.addCurve(to: CGPoint(x: bulb.x + neckHalf, y: bulb.y),
                                  control1: CGPoint(x: rightShoulder, y: edge + depth * 0.12),
                                  control2: CGPoint(x: bulb.x + neckHalf, y: edge + depth * 0.45))
                    neck.addLine(to: CGPoint(x: bulb.x - neckHalf, y: bulb.y))
                    neck.addCurve(to: CGPoint(x: rootX - rootHalf, y: edge - 2),
                                  control1: CGPoint(x: bulb.x - neckHalf, y: edge + depth * 0.45),
                                  control2: CGPoint(x: leftShoulder, y: edge + depth * 0.12))
                    layer.fill(neck, with: .color(.black))
                    layer.fill(Path(ellipseIn: CGRect(x: bulb.x - r, y: bulb.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(.black))
                }
                for drop in sim.drops {
                    let progress = min(max(drop.y / UmbarMotion.drip.fall, 0), 1)
                    // Shrinks as it falls, and away to nothing at the end.
                    let r = look.bulbRadius(at: drop.size) * (1 - 0.45 * progress) * min(1, (1 - progress) * 4)
                    guard r > 0.3 else { continue }
                    let center = CGPoint(x: drop.x * size.width, y: edge + drop.y * unit - r)
                    layer.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(fillColor))
                }
            }
        }

        // Specular surface-tension highlight on the meniscus tip and drops
        if glassRim, let shape = NotchDripShape(sim, width: size.width, flat: flat, look: look) {
            let r = shape.radius
            let bulb = CGPoint(x: shape.bulb.x, y: edge + shape.bulb.y)
            var rimArc = Path()
            rimArc.addArc(center: bulb, radius: max(1, r - 0.5),
                          startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
            context.stroke(rimArc, with: .color(.white.opacity(0.22 * min(1, sim.length * 1.6))), lineWidth: 1)
        }
    }
}

#if DEBUG
/// Lets MotionFrameRenderer pull on the drip without a pointer.
@MainActor final class DripFixture: ObservableObject {
    static let shared = DripFixture()
    @Published var reading: NotchDripReading?
}
#endif
