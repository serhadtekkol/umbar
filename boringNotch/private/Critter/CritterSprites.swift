//
//  CritterSprites.swift
//  boringNotch
//
//  How each critter and its crumbs are drawn into the crossing's Canvas.
//  The critters are umbar's own: none is a round yellow mouth, and none is
//  chased by anything. They cross whatever is under the menu bar (a light
//  page, a dark editor, a photo), so every shape carries a thin dark halo
//  and bright fills: one or the other always separates it from the ground.
//

import SwiftUI

enum CritterArt {
    // Fixed colours, not theme tokens: the ground is the user's desktop
    // (any page, editor or photo under the menu bar), not umbar's surface.
    // Two things separate a critter from it, one per kind of ground:
    // - light ground: the halo, black at 50 %, is #808080 on white (3.9:1)
    //   and #757575 on #EBEBEB (3.9:1);
    // - dark ground (#1F1F1F): the fills, shell 9.8:1, lime 11.2:1, comet
    //   core 14.4:1, crumb 9.5:1; the darkest parts that touch the ground
    //   (beetle ink 5.0:1, caterpillar antennae 5.2:1) clear 3:1 as well.
    // Decorative only, so nothing needs 4.5:1; the comet's tail has no halo
    // and is 2.6:1 on #EBEBEB, which is fine for a trail behind a haloed head.
    static let halo = Color.black.opacity(0.5)
    /// Biscuit crumbs of uneven size, not a row of identical pellets.
    static let crumbFill = Color(red: 0.93, green: 0.74, blue: 0.45)

    enum Beetle {
        static let shell = Color(red: 0.43, green: 0.86, blue: 0.73)
        static let shine = Color(red: 0.80, green: 0.97, blue: 0.91)
        static let belly = Color(red: 0.31, green: 0.76, blue: 0.66)
        /// #2F9E8C: the head, legs and antennae.
        static let ink = Color(red: 0.18, green: 0.62, blue: 0.55)
        static let eye = Color.white
    }

    enum Caterpillar {
        static let lime = Color(red: 0.73, green: 0.89, blue: 0.36)
        static let leaf = Color(red: 0.52, green: 0.77, blue: 0.27)
        static let head = Color(red: 1.00, green: 0.56, blue: 0.48)
        /// #E0705F: the antennae, which stand against the ground.
        static let feelers = Color(red: 0.88, green: 0.44, blue: 0.37)
        /// The pupil, drawn on the white of the eye only.
        static let ink = Color(red: 0.16, green: 0.12, blue: 0.14)
    }

    enum Comet {
        static let core = Color(red: 0.95, green: 0.93, blue: 1.00)
        static let glow = Color(red: 0.66, green: 0.60, blue: 1.00)
        static let tail = Color(red: 0.58, green: 0.50, blue: 1.00)
    }

    /// Draws the crumbs and the critter `elapsed` seconds into `path`'s run.
    /// `origin` is the island's top centre in the canvas.
    static func draw(_ kind: CritterKind, path: CritterPath, elapsed: TimeInterval,
                     in context: inout GraphicsContext, origin: CGPoint) {
        drawCrumbs(path: path, elapsed: elapsed, in: &context, origin: origin)
        let pose = path.pose(at: elapsed)
        guard pose.opacity > 0 else { return }
        if kind == .comet {
            drawCometTail(path: path, elapsed: elapsed, in: &context, origin: origin)
        }
        var sprite = context
        sprite.opacity = pose.opacity
        sprite.translateBy(x: origin.x + pose.x, y: origin.y + pose.y)
        sprite.scaleBy(x: path.direction.sign, y: 1)
        sprite.rotate(by: .radians(pose.pitch))
        let lastBite = path.crumbs.last { $0.eatenAt <= elapsed }.map { elapsed - $0.eatenAt }
        switch kind {
        case .beetle:
            drawBeetle(elapsed: elapsed, munching: (lastBite ?? 1) < 0.12, in: &sprite)
        case .caterpillar:
            drawCaterpillar(elapsed: elapsed, path: path, in: &sprite)
        case .comet:
            drawCometHead(elapsed: elapsed, in: &sprite)
        }
    }

    // MARK: Crumbs

    private static func drawCrumbs(path: CritterPath, elapsed: TimeInterval,
                                   in context: inout GraphicsContext, origin: CGPoint) {
        let count = max(1, path.crumbs.count)
        // Walking order, so they pop in the way the critter will eat them.
        for (index, crumb) in path.crumbs.enumerated() {
            let center = CGPoint(x: origin.x + crumb.x, y: origin.y + crumb.y)
            if elapsed < crumb.eatenAt {
                let appearsAt = CritterPath.leadIn * 0.8 * Double(index) / Double(count)
                let grow = min(1, max(0, (elapsed - appearsAt) / 0.15))
                guard grow > 0 else { continue }
                let r = (1.2 + 0.25 * CGFloat(index * 5 % 3)) * CGFloat(grow)
                context.fill(Path(ellipseIn: CGRect(x: center.x - r - 0.8, y: center.y - r - 0.8,
                                                    width: 2 * (r + 0.8), height: 2 * (r + 0.8))), with: .color(halo))
                context.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                             with: .color(crumbFill))
            } else {
                // Three bits fly off and fade: the bite.
                let age = elapsed - crumb.eatenAt
                guard age < 0.25 else { continue }
                let p = CGFloat(age / 0.25)
                for k in 0..<3 {
                    let angle = -CGFloat.pi / 2 + CGFloat(k - 1) * 0.9
                    let d = 2 + 5 * p
                    let bit = CGRect(x: center.x + cos(angle) * d - 0.6, y: center.y + sin(angle) * d - 0.6,
                                     width: 1.2, height: 1.2)
                    context.fill(Path(bit), with: .color(crumbFill.opacity(Double(1 - p))))
                }
            }
        }
    }

    // MARK: Beetle (side view, facing +x, centred on the origin)

    /// 12 × 7 cells. s shell, S shine, d belly, h ink, w eye, l leg.
    private static let beetleBody = [
        "...........h",
        "...SSsss..h.",
        "..Sssssssh..",
        ".ssssssssshh",
        ".sssssssshwh",
        ".ddddddddhhh",
    ]
    private static let beetleLegs = ["..l..l..l...", ".l..l..l...."]
    private static let cell: CGFloat = 1.25

    private static func drawBeetle(elapsed: TimeInterval, munching: Bool, in context: inout GraphicsContext) {
        var rows = beetleBody
        rows.append(beetleLegs[Int(elapsed * 10) % 2])
        var cells: [(CGRect, Color)] = []
        let left = -6 * cell, top = -3.5 * cell
        for (y, row) in rows.enumerated() {
            for (x, char) in row.enumerated() {
                let color: Color? = switch char {
                case "s": Beetle.shell
                case "S": Beetle.shine
                case "d": Beetle.belly
                case "h", "l": Beetle.ink
                case "w": Beetle.eye
                default: nil
                }
                guard let color else { continue }
                cells.append((CGRect(x: left + CGFloat(x) * cell, y: top + CGFloat(y) * cell,
                                     width: cell, height: cell), color))
            }
        }
        // The mandible snaps forward on a bite.
        if munching {
            cells.append((CGRect(x: left + 12 * cell, y: top + 5 * cell, width: cell, height: cell), Beetle.ink))
        }
        var outline = Path()
        for (rect, _) in cells { outline.addRect(rect.insetBy(dx: -0.8, dy: -0.8)) }
        context.fill(outline, with: .color(halo))
        for (rect, color) in cells { context.fill(Path(rect), with: .color(color)) }
    }

    // MARK: Caterpillar (head at the origin, body trailing along -x)

    private static func drawCaterpillar(elapsed: TimeInterval, path: CritterPath, in context: inout GraphicsContext) {
        let eaten = path.crumbs.filter { $0.eatenAt <= elapsed }
        let segments = 2 + min(6, eaten.count)
        let phase = elapsed * 9
        var circles: [(CGPoint, CGFloat, Color)] = []
        for k in stride(from: segments, through: 1, by: -1) {
            // The newest segment swells in over 0.15 s after its crumb.
            var grow: CGFloat = 1
            if k > 2, k - 3 < eaten.count, k == segments {
                grow = CGFloat(min(1, max(0, (elapsed - eaten[k - 3].eatenAt) / 0.15)))
            }
            let r = (3.1 - CGFloat(k) * 0.12) * grow
            let lift = -abs(sin(phase - Double(k) * 0.8)) * 1.6
            circles.append((CGPoint(x: -CGFloat(k) * 4.8, y: CGFloat(lift) + 0.6), r, k.isMultiple(of: 2) ? Caterpillar.leaf : Caterpillar.lime))
        }
        let headLift = CGFloat(-abs(sin(phase)) * 1.0)
        let head = CGPoint(x: 0.5, y: headLift)
        circles.append((head, 3.6, Caterpillar.head))

        var outline = Path()
        for (c, r, _) in circles where r > 0 {
            outline.addEllipse(in: CGRect(x: c.x - r - 0.8, y: c.y - r - 0.8, width: 2 * (r + 0.8), height: 2 * (r + 0.8)))
        }
        // Antennae, drawn with the halo so they read on a white page.
        var antennae = Path()
        antennae.move(to: CGPoint(x: head.x - 0.5, y: head.y - 3.2))
        antennae.addLine(to: CGPoint(x: head.x - 1.5, y: head.y - 5.6))
        antennae.move(to: CGPoint(x: head.x + 1.5, y: head.y - 3.2))
        antennae.addLine(to: CGPoint(x: head.x + 2.6, y: head.y - 5.4))
        context.stroke(antennae, with: .color(halo), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        context.fill(outline, with: .color(halo))
        context.stroke(antennae, with: .color(Caterpillar.feelers), style: StrokeStyle(lineWidth: 0.9, lineCap: .round))
        for (c, r, color) in circles where r > 0 {
            context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
        }
        // One eye, looking ahead.
        context.fill(Path(ellipseIn: CGRect(x: head.x + 0.6, y: head.y - 1.9, width: 2.2, height: 2.2)), with: .color(.white))
        context.fill(Path(ellipseIn: CGRect(x: head.x + 1.5, y: head.y - 1.3, width: 1.1, height: 1.1)), with: .color(Caterpillar.ink))
    }

    // MARK: Comet

    private static func drawCometTail(path: CritterPath, elapsed: TimeInterval,
                                      in context: inout GraphicsContext, origin: CGPoint) {
        // The tail is where the head has been, so it follows the dives.
        for k in stride(from: 9, through: 1, by: -1) {
            let then = elapsed - Double(k) * 0.035
            let pose = path.pose(at: then)
            guard pose.opacity > 0 else { continue }
            let fade = 1 - Double(k) / 10
            let r = 2.7 - CGFloat(k) * 0.22
            let rect = CGRect(x: origin.x + pose.x - r, y: origin.y + pose.y - r, width: 2 * r, height: 2 * r)
            context.fill(Path(ellipseIn: rect), with: .color(Comet.tail.opacity(0.75 * fade * pose.opacity)))
        }
    }

    private static func drawCometHead(elapsed: TimeInterval, in context: inout GraphicsContext) {
        let glow = CGRect(x: -7, y: -7, width: 14, height: 14)
        context.fill(Path(ellipseIn: glow), with: .radialGradient(
            Gradient(colors: [Comet.glow.opacity(0.6), Comet.glow.opacity(0)]),
            center: .zero, startRadius: 0, endRadius: 7))
        let star = sparkle(outer: 4.4, inner: 1.5, turn: elapsed * 2.2)
        context.stroke(star, with: .color(halo), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
        context.fill(star, with: .color(Comet.core))
    }

    /// A four-point star, turned by `turn` radians.
    private static func sparkle(outer: CGFloat, inner: CGFloat, turn: Double) -> Path {
        var path = Path()
        for i in 0..<8 {
            let angle = CGFloat(turn) + CGFloat(i) * .pi / 4
            let r = i.isMultiple(of: 2) ? outer : inner
            let point = CGPoint(x: cos(angle) * r, y: sin(angle) * r)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}
