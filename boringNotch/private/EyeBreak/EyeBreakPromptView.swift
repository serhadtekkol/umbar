//
//  EyeBreakPromptView.swift
//  boringNotch
//
//  The eye-break reminder (F14, C7-H). It is a banner that hangs from the
//  closed notch: it never opens the panel, never takes the keyboard, and a
//  click anywhere on it except its buttons reaches the app behind (a full-
//  screen browser's tab bar sits right there). Opening the panel while it
//  is up shows the same content in the panel, where the keyboard can reach
//  the buttons (shortcut, Tab).
//
//  Snooze and Skip are equal-weight secondary buttons: neither is the
//  "right" answer, so neither is emphasised. The first reminder an install
//  ever shows says what the feature is and offers to turn it off in place.
//

import AppKit
import Defaults
import SwiftUI

// MARK: - Content

/// The reminder itself, free of the manager so the renderers can draw every state.
struct EyeBreakPromptContent: View {
    let endsAt: Date
    let duration: Int
    let intervalMinutes: Int
    let isIntro: Bool
    var onSnooze: () -> Void = {}
    var onSkip: () -> Void = {}
    var onTurnOff: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: PageTokens.m) {
            Image(systemName: "eye")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(PageTokens.textPrimary)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            if isIntro { intro } else { compact }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(EyeBreakStrings.title))
    }

    private var compact: some View {
        HStack(alignment: .center, spacing: PageTokens.m) {
            VStack(alignment: .leading, spacing: 6) {
                Text(EyeBreakStrings.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PageTokens.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                EyeBreakCountdown(endsAt: endsAt, duration: duration)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: PageTokens.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Eye break"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PageTokens.textPrimary)
                Text(String(
                    localized: "eyebreak.intro.body",
                    defaultValue: "Look 20 feet away for \(duration) seconds. This reminder comes every \(intervalMinutes) minutes."))
                    .font(.system(size: 12))
                    .foregroundStyle(PageTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            EyeBreakCountdown(endsAt: endsAt, duration: duration)
            HStack(spacing: PageTokens.s) {
                actions
                Spacer(minLength: PageTokens.s)
                Button(String(localized: "eyebreak.turnOff", defaultValue: "Turn off eye breaks"), action: onTurnOff)
                    .buttonStyle(EyeBreakQuietButtonStyle())
                    .eyeBreakHitTarget()
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One style for both: the layout does not suggest an answer.
    private var actions: some View {
        HStack(spacing: PageTokens.s) {
            Button(String(localized: "eyebreak.snooze", defaultValue: "Snooze 5 min"), action: onSnooze)
                .eyeBreakHitTarget()
            Button(String(localized: "eyebreak.skip", defaultValue: "Skip"), action: onSkip)
                .eyeBreakHitTarget()
        }
        .buttonStyle(EyeBreakButtonStyle())
    }
}

enum EyeBreakStrings {
    static var title: String { String(localized: "eyebreak.title", defaultValue: "Look 20 feet away") }
}

/// Remaining time as a draining bar plus seconds. Redrawn once a second by
/// the view (TimelineView) so the manager does not publish every second.
struct EyeBreakCountdown: View {
    let endsAt: Date
    let duration: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let barWidth: CGFloat = 96

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int(endsAt.timeIntervalSince(ctx.date).rounded(.up)))
            let fraction = duration > 0 ? min(1, CGFloat(left) / CGFloat(duration)) : 0
            HStack(spacing: PageTokens.s) {
                ZStack(alignment: .leading) {
                    Capsule().fill(PageTokens.raisedStrong)
                    Capsule().fill(PageTokens.textSecondary)
                        .scaleEffect(x: fraction, anchor: .leading)
                        // A one-second linear drain reads as continuous;
                        // Reduce Motion steps once a second instead.
                        .animation(reduceMotion ? nil : .linear(duration: 1), value: left)
                }
                .frame(width: Self.barWidth, height: 3)
                Text(String(localized: "eyebreak.countdown", defaultValue: "\(left) s"))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(PageTokens.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(String(localized: "eyebreak.remaining.a11y", defaultValue: "\(left) seconds left")))
        }
    }
}

// MARK: - Buttons

/// Neutral secondary button, used for both Snooze and Skip.
struct EyeBreakButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(PageTokens.textPrimary)
            .lineLimit(1)
            // Never truncated: the body text and the quiet button give way first.
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(minWidth: 64, minHeight: 26)
            .background {
                // Border as an inset fill: crisper at 1x than strokeBorder.
                Capsule().fill(EyeBreakBannerTokens.buttonBorder)
                    .overlay(Capsule().fill(PageTokens.raisedStrong).padding(1))
            }
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? UmbarMotion.pressScale : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(UmbarMotion.press, value: configuration.isPressed)
    }
}

/// Text-only, for "Turn off eye breaks": a way out, not an answer to the prompt.
struct EyeBreakQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(PageTokens.textSecondary)
            .underline(configuration.isPressed)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(minHeight: 26)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

enum EyeBreakBannerTokens {
    /// 3.06:1 against the black banner, so the button's edge is a real
    /// boundary (WCAG 1.4.11), not only its 1.5:1 fill.
    static let buttonBorder = Color(red: 0x5A / 255, green: 0x5A / 255, blue: 0x5F / 255)
    static let width: CGFloat = 420
    static let bottomRadius: CGFloat = 20
    /// The body's top corners, beside the notch.
    static let shoulderRadius: CGFloat = 14
    /// The concave curve where the notch meets the body.
    static let neckFillet: CGFloat = 8
}

// MARK: - Manager-bound views

/// In the open panel (the user opened it while the reminder was up).
struct EyeBreakPromptView: View {
    @ObservedObject var manager = EyeBreakManager.shared

    var body: some View {
        if case .prompting(let endsAt) = manager.phase {
            EyeBreakPromptContent(
                endsAt: endsAt,
                duration: manager.breakDurationSeconds,
                intervalMinutes: manager.intervalMinutes,
                isIntro: manager.isIntroPrompt,
                onSnooze: manager.snooze,
                onSkip: manager.skip,
                onTurnOff: manager.turnOff
            )
            .frame(maxWidth: EyeBreakBannerTokens.width - 2 * PageTokens.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// ContentView's slot for the banner. Shows it only while the panel is
/// closed; an open panel draws EyeBreakPromptView instead.
struct EyeBreakBannerSlot: View {
    /// The closed island's width, music ears included, so the banner's neck
    /// joins its sides.
    let neckWidth: CGFloat

    @EnvironmentObject private var vm: BoringViewModel
    @ObservedObject private var manager = EyeBreakManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let endsAt: Date? = {
            guard manager.isPromptingInPanel, vm.notchState == .closed,
                  case .prompting(let endsAt) = manager.phase else { return nil }
            return endsAt
        }()
        ZStack(alignment: .top) {
            if let endsAt {
                EyeBreakBanner(notch: CGSize(width: neckWidth, height: vm.closedNotchSize.height)) {
                    EyeBreakPromptContent(
                        endsAt: endsAt,
                        duration: manager.breakDurationSeconds,
                        intervalMinutes: manager.intervalMinutes,
                        isIntro: manager.isIntroPrompt,
                        onSnooze: manager.snooze,
                        onSkip: manager.skip,
                        onTurnOff: manager.turnOff
                    )
                }
                .transition(.islandContent(delay: 0, reduce: reduceMotion))
            }
        }
        .animation(UmbarMotion.ear(reduce: reduceMotion), value: endsAt)
    }
}

// MARK: - Banner

/// Black island that comes out of the notch and widens below the menu bar,
/// so the menu bar beside the notch stays visible and clickable. The content
/// sits below the notch's height (the hardware cut-out hides anything drawn
/// in it). The neck is not hit-testable, so hovering the notch still opens
/// the panel.
struct EyeBreakBanner<Content: View>: View {
    let notch: CGSize
    @ViewBuilder let content: Content

    private var notchHeight: CGFloat { notch.height }

    @EnvironmentObject private var vm: BoringViewModel
    @State private var clickThrough = EyeBreakClickThrough()
    @State private var targets: [CGRect] = []
    @State private var frame: CGRect = .zero

    var body: some View {
        content
            .padding(.horizontal, PageTokens.l)
            .padding(.top, PageTokens.s)
            .padding(.bottom, PageTokens.m + 2)
            .padding(.top, notchHeight)
            .frame(width: EyeBreakBannerTokens.width, alignment: .leading)
            .background {
                EyeBreakBannerShape(neckWidth: notch.width, neckHeight: notchHeight)
                    .fill(.black)
                    .allowsHitTesting(false)
            }
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .onPreferenceChange(EyeBreakHitTargetsKey.self) { targets = $0 }
            .onChange(of: frame, initial: true) { clickThrough.update(banner: frame, notchHeight: notchHeight, targets: targets) }
            .onChange(of: targets) { clickThrough.update(banner: frame, notchHeight: notchHeight, targets: targets) }
            .onAppear {
                clickThrough.start(window: Self.window(for: vm))
                Self.announce()
            }
            .onDisappear { clickThrough.stop() }
    }

    private static func window(for vm: BoringViewModel) -> NSWindow? {
        NSApp.windows.first { ($0 as? BoringNotchSkyLightWindow)?.viewModel === vm }
    }

    /// The banner never takes focus, so VoiceOver would not notice it.
    private static func announce() {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: EyeBreakStrings.title,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

/// A neck the size of the notch on top of a wider body with rounded
/// shoulders, joined by concave fillets.
struct EyeBreakBannerShape: Shape {
    let neckWidth: CGFloat
    let neckHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let neck = min(neckWidth, w)
        let top = min(neckHeight, h)
        let x0 = rect.minX + (w - neck) / 2, x1 = x0 + neck
        let f = min(EyeBreakBannerTokens.neckFillet, (w - neck) / 2, top)
        let s = EyeBreakBannerTokens.shoulderRadius
        let b = EyeBreakBannerTokens.bottomRadius
        var p = Path()
        p.move(to: CGPoint(x: x0, y: rect.minY))
        p.addLine(to: CGPoint(x: x1, y: rect.minY))
        p.addLine(to: CGPoint(x: x1, y: rect.minY + top - f))
        p.addQuadCurve(to: CGPoint(x: x1 + f, y: rect.minY + top), control: CGPoint(x: x1, y: rect.minY + top))
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + top))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + top + s), control: CGPoint(x: rect.maxX, y: rect.minY + top))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + h - b))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - b, y: rect.minY + h), control: CGPoint(x: rect.maxX, y: rect.minY + h))
        p.addLine(to: CGPoint(x: rect.minX + b, y: rect.minY + h))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + h - b), control: CGPoint(x: rect.minX, y: rect.minY + h))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top + s))
        p.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + top), control: CGPoint(x: rect.minX, y: rect.minY + top))
        p.addLine(to: CGPoint(x: x0 - f, y: rect.minY + top))
        p.addQuadCurve(to: CGPoint(x: x0, y: rect.minY + top - f), control: CGPoint(x: x0, y: rect.minY + top))
        p.closeSubpath()
        return p
    }
}

// MARK: - Click-through

/// Frames of the banner's buttons in the window's SwiftUI global space.
struct EyeBreakHitTargetsKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    /// Marks a control on the banner that must receive clicks.
    func eyeBreakHitTarget() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(key: EyeBreakHitTargetsKey.self, value: [proxy.frame(in: .global)])
            }
        }
    }
}

/// While the banner is up, makes the window ignore the mouse whenever the
/// pointer is on the banner but not on one of its buttons, so the click
/// lands in the app behind. The window server delivers a click to whichever
/// window is under it before any view sees it, so this cannot be done in
/// hit testing; the pointer is sampled instead (60 Hz, only while shown).
@MainActor
final class EyeBreakClickThrough {
    private weak var window: NSWindow?
    private var timer: Timer?
    private var banner: CGRect = .zero
    private var notchHeight: CGFloat = 0
    private var targets: [CGRect] = []

    func start(window: NSWindow?) {
        guard let window, timer == nil else { return }
        self.window = window
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        sample()
    }

    func update(banner: CGRect, notchHeight: CGFloat, targets: [CGRect]) {
        self.banner = banner
        self.notchHeight = notchHeight
        self.targets = targets
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        // Never leave the notch deaf to the mouse.
        window?.ignoresMouseEvents = false
        window = nil
    }

    private func sample() {
        guard let window else { return }
        let point = EyeBreakBannerHitPolicy.windowPoint(screen: NSEvent.mouseLocation, windowFrame: window.frame)
        let ignore = EyeBreakBannerHitPolicy.passesThrough(point, banner: banner, notchHeight: notchHeight, targets: targets)
        if window.ignoresMouseEvents != ignore { window.ignoresMouseEvents = ignore }
    }
}
