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
    static func close(reduce: Bool = reduceMotion) -> Animation {
        reduce ? .easeIn(duration: 0.12) : .spring(response: 0.32, dampingFraction: 1).delay(0.04)
    }

    /// The closed island changing width or height (music starts, the live
    /// strip appears): the same family as open, without the overshoot.
    static func ear(reduce: Bool = reduceMotion) -> Animation {
        reduce ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.86)
    }

    /// Hover hint: the closed island reaches 4 pt down before it opens.
    static func hoverHint(reduce: Bool = reduceMotion) -> Animation {
        reduce ? .easeOut(duration: 0.12) : .spring(response: 0.24, dampingFraction: 0.8)
    }

    static let hoverHintGrow: CGFloat = 4

    // MARK: Content

    /// Panel content arriving: scale and drop on a spring, staggered.
    static func contentIn(delay: Double, reduce: Bool = reduceMotion) -> Animation {
        reduce
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.3, dampingFraction: 0.84).delay(delay)
    }

    /// Panel content leaving: fast, before the shape closes over it.
    static func contentOut(reduce: Bool = reduceMotion) -> Animation {
        reduce ? .easeIn(duration: 0.12) : .easeIn(duration: 0.1)
    }

    static let headerDelay: Double = 0.03
    static let pageDelay: Double = 0.07
    static let contentScale: CGFloat = 0.92
    static let contentDrop: CGFloat = 6

    // MARK: Pages and tabs

    static func page(reduce: Bool = reduceMotion) -> Animation {
        reduce ? .easeOut(duration: 0.15) : .spring(response: 0.26, dampingFraction: 0.9)
    }

    static let pageOffset: CGFloat = 8

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
