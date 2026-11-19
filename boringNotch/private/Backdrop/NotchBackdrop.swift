//
//  NotchBackdrop.swift
//  boringNotch
//
//  Selectable backdrop for the notch island: solid ink black (default),
//  frosted behind-window glass, or album-tinted frosted glass.
//

import AppKit
import Defaults
import SwiftUI

enum NotchBackdropStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case solid
    case frosted
    case tintedGlass
    case liquidGlass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .solid:
            return String(localized: "backdrop.style.solid", defaultValue: "Solid black")
        case .frosted:
            return String(localized: "backdrop.style.frosted", defaultValue: "Frosted glass")
        case .tintedGlass:
            return String(localized: "backdrop.style.tintedGlass", defaultValue: "Album-tinted glass")
        case .liquidGlass:
            return String(localized: "backdrop.style.liquidGlass", defaultValue: "Liquid glass")
        }
    }
}

extension Defaults.Keys {
    static let notchBackdropStyle = Key<NotchBackdropStyle>("notchBackdropStyle", default: .solid)
    /// Dark scrim opacity layered over the behind-window blur (0.15…0.75)
    /// so white labels remain legible over bright windows.
    static let notchGlassOpacity = Key<Double>("notchGlassOpacity", default: 0.42)
    /// When false, the closed notch stays solid black to blend with the
    /// physical MacBook display bezel and transitions to glass when opened.
    static let notchGlassWhenClosed = Key<Bool>("notchGlassWhenClosed", default: false)
    /// When true, removes the reserved camera notch gap in the center so
    /// non-notch displays utilize the full bar for song titles and header content.
    static let useNotchAreaForContent = Key<Bool>("useNotchAreaForContent", default: true)
}

/// Behind-window macOS blur view locked to Dark Aqua so text stays legible
/// regardless of the system light/dark mode.
struct NotchVisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material {
            nsView.material = material
        }
        nsView.blendingMode = .behindWindow
        nsView.state = .active
        nsView.appearance = NSAppearance(named: .darkAqua)
    }
}

struct NotchBackdropView: View {
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let isOpen: Bool
    let hasPhysicalNotch: Bool
    let albumColor: NSColor
    let isPlaying: Bool
    let dripEnabled: Bool
    @ObservedObject var dripPointer: DripPointer

    static let magneticReserve: CGFloat = 14

    @Default(.notchBackdropStyle) private var style
    @Default(.notchGlassOpacity) private var glassOpacity
    @Default(.notchGlassWhenClosed) private var glassWhenClosed
    @Default(.useNotchAreaForContent) private var useNotchAreaForContent
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var magneticPull: CGFloat = 0
    @State private var magneticX: CGFloat = 0.5

    private var usesGlass: Bool {
        !reduceTransparency && style != .solid && (isOpen || glassWhenClosed || (useNotchAreaForContent && !hasPhysicalNotch))
    }

    private var shape: NotchShape {
        let activePull = (!isOpen && dripEnabled && !reduceMotion) ? magneticPull : 0
        return NotchShape(
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            magneticPull: activePull,
            magneticX: magneticX,
            bottomReserve: Self.magneticReserve
        )
    }

    var body: some View {
        ZStack {
            if usesGlass {
                let isLiquid = (style == .liquidGlass)
                NotchVisualEffectBlur(material: isLiquid ? .fullScreenUI : .hudWindow)
                    .overlay {
                        // Base darkness scrim; liquid glass keeps a lighter, more refractive core
                        let baseAlpha = min(max(glassOpacity, 0.15), 0.75)
                        Color.black.opacity(isLiquid ? baseAlpha * 0.72 : baseAlpha)
                    }
                    .overlay {
                        if (style == .tintedGlass || isLiquid) && isPlaying {
                            LinearGradient(
                                colors: [
                                    Color(nsColor: albumColor).opacity(isLiquid ? 0.28 : 0.22),
                                    Color(nsColor: albumColor).opacity(isLiquid ? 0.10 : 0.08),
                                    .clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        }
                    }
                    .overlay {
                        if isLiquid {
                            // Liquid Glass refractive sheen + pointer-reactive specular highlight
                            GeometryReader { geo in
                                let sheenX = min(max(magneticX, 0.15), 0.85) * geo.size.width
                                ZStack {
                                    // Top curved lens highlight
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(0.22),
                                            .white.opacity(0.05),
                                            .clear,
                                            .white.opacity(0.10),
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                    // Pointer-reactive liquid caustic reflection
                                    RadialGradient(
                                        colors: [
                                            .white.opacity(0.20 + 0.12 * Double(magneticPull)),
                                            Color(nsColor: albumColor).opacity(isPlaying ? 0.14 : 0.04),
                                            .clear,
                                        ],
                                        center: UnitPoint(
                                            x: geo.size.width > 0 ? sheenX / geo.size.width : 0.5,
                                            y: isOpen ? 0.18 : 0.85
                                        ),
                                        startRadius: 4,
                                        endRadius: max(120, geo.size.width * 0.55)
                                    )
                                }
                            }
                        }
                    }
                    .clipShape(shape)
                    .overlay {
                        if isLiquid {
                            // Dual-layer Fresnel refractive glass rim (outer crisp specular + inner soft thickness)
                            ZStack {
                                shape
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                .white.opacity(0.50),
                                                .white.opacity(0.14),
                                                Color(nsColor: albumColor).opacity(isPlaying ? 0.32 : 0.18),
                                                .white.opacity(0.38),
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1.5
                                    )
                                shape
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                .white.opacity(0.18),
                                                .clear,
                                                .white.opacity(0.12),
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 1
                                    )
                                    .padding(1.2)
                            }
                            .clipShape(shape)
                        } else {
                            shape
                                .stroke(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity(0.22),
                                            .white.opacity(0.07),
                                            .white.opacity(0.16),
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    ),
                                    lineWidth: 1
                                )
                                .clipShape(shape)
                        }
                    }
            } else {
                shape.fill(.black)
            }
        }
        .onReceive(dripPointer.$reading) { reading in
            guard !isOpen, dripEnabled, !reduceMotion else {
                if magneticPull != 0 {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                        magneticPull = 0
                    }
                }
                return
            }
            if let reading {
                let t = min(max(reading.pull, 0), 1)
                let smooth = t * t * (3 - 2 * t)
                if magneticPull < 0.01 {
                    magneticX = reading.x
                }
                withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.76)) {
                    magneticPull = smooth
                    magneticX = reading.x
                }
            } else if magneticPull != 0 {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                    magneticPull = 0
                }
            }
        }
        .onChange(of: isOpen) { _, opened in
            if opened, magneticPull != 0 {
                withAnimation(.easeOut(duration: 0.1)) {
                    magneticPull = 0
                }
            }
        }
    }
}

struct NotchBackdropSettingsSection: View {
    @Default(.notchBackdropStyle) private var style
    @Default(.notchGlassOpacity) private var glassOpacity
    @Default(.notchGlassWhenClosed) private var glassWhenClosed
    @Default(.useNotchAreaForContent) private var useNotchAreaForContent

    var body: some View {
        Section {
            Picker(
                String(localized: "backdrop.settings.style", defaultValue: "Notch background"),
                selection: $style
            ) {
                ForEach(NotchBackdropStyle.allCases) { option in
                    Text(option.label).tag(option)
                }
            }

            if style != .solid {
                Slider(value: $glassOpacity, in: 0.15...0.75, step: 0.03) {
                    Text(String(localized: "backdrop.settings.tint", defaultValue: "Glass darkness"))
                }
                Defaults.Toggle(key: .notchGlassWhenClosed) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "backdrop.settings.whenClosed", defaultValue: "Keep frosted when closed"))
                        Text(String(localized: "backdrop.settings.whenClosed.detail",
                                    defaultValue: "Off keeps the closed notch solid black so it blends with the MacBook bezel."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Defaults.Toggle(key: .useNotchAreaForContent) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "backdrop.settings.useNotchArea", defaultValue: "No notch here — use center space"))
                    Text(String(localized: "backdrop.settings.useNotchArea.detail",
                                defaultValue: "Removes the empty camera notch gap in the middle and uses the full bar for song titles and content."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(String(localized: "backdrop.settings.header", defaultValue: "Backdrop"))
        }
    }
}
