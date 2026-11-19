//
//  UmbarMotion.swift
//  boringNotch
//
//  Motion tokens (design-language §3.7) as code. Every animation on the
//  island reads one of these, so open, close, page and ear motion stay one
//  system and the Reduce Motion variant lives next to the full one.
//
//  Only transform and opacity move; nothing here animates a blur radius or
//  a window frame. The island window keeps its fixed size (windowSize), so
//  the hover rects NotchHoverPolicy reads never change mid-animation: the
//  shape and its content morph inside the window.
//

import AppKit
import SwiftUI

enum UmbarMotion {
    /// System Reduce Motion, for code outside a view's environment
    /// (withAnimation calls in handlers).
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Island shape

    /// The shape grows out of the notch: width, height and corner radii on
    /// one spring with a slight overshoot. Visually settled by ~0.3 s.
    static func open(reduce: Bool = reduceMotion) -> Animation {
        reduce ? .easeOut(duration: 0.15) : .spring(response: 0.36, dampingFraction: 0.78)
    }

    /// Critically damped, and a beat late so the content leaves first.
    /// Quicker than open: settled by ~0.3 s, so a fold reads as decisive.
    static func close(reduce: Bool = reduceMotion) -> Animation {
        reduce ? .easeIn(duration: 0.12) : .spring(response: 0.26, dampingFraction: 1).delay(0.02)
    }

    /// How long `close` takes to come to rest, for motion that must not
    /// start until the island has folded (the hover hint).
    static let closeSettle: TimeInterval = 0.34

    /// The closed island changing width or height (music starts, the live
    /// strip appears): the same family as open, without the overshoot.
    static func ear(reduce: Bool = reduceMotion) -> Animation {
        reduce ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.86)
    }

    // MARK: Hover hint

    /// The hover state itself (the island's shadow fading in and out). The
    /// shape's growth runs on the three springs below; under Reduce Motion
    /// this fade is the whole hint.
    static func hoverHint(reduce: Bool = reduceMotion) -> Animation {
        reduce ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.8)
    }

    /// The island widening toward the pointer: crisp magnetic response.
    static let hoverHintWiden: Animation = .spring(response: 0.20, dampingFraction: 0.68)

    /// The island deepening, a beat after it widens: smooth magnetic swell.
    static let hoverHintDeepen: Animation = .spring(response: 0.24, dampingFraction: 0.72)

    /// The pointer gone: back to the notch without a bounce.
    static let hoverHintRelease: Animation = .spring(response: 0.28, dampingFraction: 0.94)

    /// The full hint, pointer on the island: points added below, on each
    /// side, and to the bottom corner radius.
    static let hoverHintDown: CGFloat = 6.5
    static let hoverHintSide: CGFloat = 4.5
    static let hoverHintRadius: CGFloat = 4

    /// The pointer within `hoverApproachReach` points of the island leans
    /// it up to `hoverApproachShare` of the full hint, in
    /// `hoverApproachSteps` levels (NotchApproachPolicy).
    static let hoverApproachReach: CGFloat = 58
    static let hoverApproachShare: CGFloat = 0.62
    static let hoverApproachSteps = 24

    // MARK: Drip

    /// The liquid drip under the closed island (NotchDripPolicy, DripLayer).
    /// Tuned for a responsive, high-surface-tension magnetic meniscus that
    /// tracks the pointer closely and snaps back cleanly.
    static let drip = NotchDripTuning(
        reach: 62, near: 8, inset: 6,
        stretchResponse: 0.26, stretchDamping: 0.72,
        retractResponse: 0.22, retractDamping: 0.92,
        followResponse: 0.16, followDamping: 0.86,
        detachLength: 0.62, detachGap: 0.44,
        recoil: 7, refractory: 0.28,
        dropSpeed: 1.6, gravity: 36, fall: 2.4,
        rippleLife: 0.5, maxDrops: 3
    )
    /// Sleek magnetic meniscus: wide, smooth root fillet tapering into a
    /// compact 18 pt liquid pull rather than an oversized hanging blob.
    static let dripLook = NotchDripLook(
        maxLength: 18, bulbRadius: 4.5...7.5, rootHalfWidth: 22...32, neck: 0.56, lean: 4
    )
    /// Gooey merge: the blur the alpha threshold cuts at half coverage.
    static let dripGoo: CGFloat = 4.2
    /// The drip leaving when the panel opens over it.
    static let dripOut: Animation = .easeIn(duration: 0.1)

    // MARK: Content

    /// Panel content arriving: scale and drop on a spring, staggered, once
    /// the shape has opened far enough to hold it. The shape carries the
    /// bounce; the content only settles.
    static func contentIn(delay: Double, reduce: Bool = reduceMotion) -> Animation {
        reduce
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.28, dampingFraction: 0.9).delay(delay)
    }

    /// Panel content leaving: fast, before the shape closes over it.
    static func contentOut(reduce: Bool = reduceMotion) -> Animation {
        reduce ? .easeIn(duration: 0.12) : .easeIn(duration: 0.08)
    }

    static let headerDelay: Double = 0.06
    static let pageDelay: Double = 0.1
    static let contentScale: CGFloat = 0.96
    static let contentDrop: CGFloat = 4

    // MARK: Pages and tabs

    /// One page of the open panel replacing another (every tab, Şimdi
    /// included): the new page slides `pageOffset` in from its tab's side
    /// while the old one slides out the other way, both fading. A soft
    /// spring, no visible overshoot, settled by ~0.35 s. Reduce Motion: a
    /// plain crossfade, nothing moves.
    static func page(reduce: Bool = reduceMotion) -> Animation {
        reduce ? .easeInOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.88)
    }

    /// How far a page travels. 8 pt read as a crossfade on the 800 pt
    /// panel; 32 pt shows the direction without the page seeming to leave.
    static let pageOffset: CGFloat = 32

    /// The selected-tab capsule moving and the label widening its tab.
    static func tab(reduce: Bool = reduceMotion) -> Animation {
        reduce ? .easeOut(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.82)
    }

    // MARK: Micro-interactions

    static let pressScale: CGFloat = 0.94
    static let press: Animation = .spring(response: 0.18, dampingFraction: 0.7)
}

// MARK: - Transitions

/// Scale + vertical offset + opacity, the one transform the island content uses.
struct IslandContentModifier: ViewModifier {
    let scale: CGFloat
    let y: CGFloat
    let opacity: Double
    let anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: anchor)
            .offset(y: y)
            .opacity(opacity)
    }
}

/// Horizontal slide + opacity, for pages and for ears leaving the notch edge.
struct SlideFadeModifier: ViewModifier {
    let x: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.offset(x: x).opacity(opacity)
    }
}

extension AnyTransition {
    /// Open-panel content: in from 0.92 and a few points above, after
    /// `delay`; out fast, shrinking a little toward the notch.
    static func islandContent(delay: Double, reduce: Bool) -> AnyTransition {
        if reduce {
            return .asymmetric(
                insertion: .opacity.animation(UmbarMotion.contentIn(delay: 0, reduce: true)),
                removal: .opacity.animation(UmbarMotion.contentOut(reduce: true))
            )
        }
        return .asymmetric(
            insertion: .modifier(
                active: IslandContentModifier(scale: UmbarMotion.contentScale, y: -UmbarMotion.contentDrop, opacity: 0, anchor: .top),
                identity: IslandContentModifier(scale: 1, y: 0, opacity: 1, anchor: .top)
            )
            .animation(UmbarMotion.contentIn(delay: delay, reduce: false)),
            removal: .modifier(
                active: IslandContentModifier(scale: 0.96, y: -UmbarMotion.contentDrop / 2, opacity: 0, anchor: .top),
                identity: IslandContentModifier(scale: 1, y: 0, opacity: 1, anchor: .top)
            )
            .animation(UmbarMotion.contentOut(reduce: false))
        )
    }

    /// Closed-island content (music ear, face, HUD) that gives way to the
    /// open panel: it leaves at once so the morph is not a crossfade of two
    /// layouts, and comes back once the shape has nearly closed.
    static func closedContent(reduce: Bool) -> AnyTransition {
        if reduce { return .opacity.animation(.easeOut(duration: 0.12)) }
        return .asymmetric(
            insertion: .modifier(
                active: IslandContentModifier(scale: 0.9, y: 0, opacity: 0, anchor: .center),
                identity: IslandContentModifier(scale: 1, y: 0, opacity: 1, anchor: .center)
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.86).delay(0.1)),
            removal: .opacity.animation(.easeIn(duration: 0.08))
        )
    }

    /// A page replacing another: `direction` +1 when the new tab is to the
    /// right of the old one. The leaving page moves the other way.
    static func page(direction: CGFloat, reduce: Bool) -> AnyTransition {
        if reduce { return .opacity }
        let d = UmbarMotion.pageOffset * direction
        return .asymmetric(
            insertion: .modifier(active: SlideFadeModifier(x: d, opacity: 0), identity: SlideFadeModifier(x: 0, opacity: 1)),
            removal: .modifier(active: SlideFadeModifier(x: -d, opacity: 0), identity: SlideFadeModifier(x: 0, opacity: 1))
        )
    }

    /// A closed-island ear sliding out from under the notch edge. `inward`
    /// is the x offset back under the island (negative for a trailing ear).
    static func ear(inward: CGFloat, reduce: Bool) -> AnyTransition {
        if reduce { return .opacity }
        return .modifier(
            active: SlideFadeModifier(x: inward, opacity: 0),
            identity: SlideFadeModifier(x: 0, opacity: 1)
        )
    }
}

// MARK: - Press

/// Buttons on the island shrink to 0.94 while pressed. Reduce Motion keeps
/// the press but drops the scale for a dim.
struct IslandPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? UmbarMotion.pressScale : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(UmbarMotion.press, value: configuration.isPressed)
    }
}
