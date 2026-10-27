//
//  PanelTabs.swift
//  boringNotch
//
//  The open panel's five pages (design-language §5.2) and which of them are
//  on. One list feeds the tab bar, ⌘1…⌘5 and the page switch in
//  ContentView, so a page that is off has no tab and no shortcut.
//

import Defaults
import SwiftUI

/// §3 tokens the pages share. The island is always black (§1 rule 1), so
/// there is one palette, not a light and a dark one. Local until
/// UmbarTokens lands, like `MusicSpace` and `NetTokens`.
enum PageTokens {
    static let textPrimary = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)
    /// 8.2:1 on black, 6.6:1 on `raised`, 5.4:1 on `raisedStrong`.
    static let textSecondary = Color(red: 0xA1 / 255, green: 0xA1 / 255, blue: 0xA6 / 255)
    static let raised = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
    static let raisedStrong = Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255)
    /// Amber means "live" only, and always comes with a shape.
    static let live = Color(red: 0xFF / 255, green: 0xC3 / 255, blue: 0x5C / 255)

    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let tileRadius: CGFloat = 12
}

struct PanelTab: Identifiable, Equatable {
    enum Icon: Equatable {
        case system(String)
        case asset(String)
    }

    let view: NotchViews
    let page: PanelPage
    let icon: Icon

    var id: NotchViews { view }

    var label: String {
        switch view {
        case .home: String(localized: "panel.tab.now", defaultValue: "Now")
        case .shelf: String(localized: "panel.tab.shelf", defaultValue: "Shelf")
        case .calendar: String(localized: "panel.tab.calendar", defaultValue: "Calendar")
        case .network: String(localized: "panel.tab.network", defaultValue: "Network")
        case .tools: String(localized: "panel.tab.tools", defaultValue: "Tools")
        }
    }

    static let all: [PanelTab] = [
        PanelTab(view: .home, page: .now, icon: .asset("MenuBarIcon")),
        PanelTab(view: .shelf, page: .shelf, icon: .system("tray")),
        PanelTab(view: .calendar, page: .calendar, icon: .system("calendar")),
        PanelTab(view: .network, page: .network, icon: .system("network")),
        PanelTab(view: .tools, page: .tools, icon: .system("slider.horizontal.3")),
    ]

    /// Pages whose feature is on (AC-1.13: a turned-off feature loses its tab).
    /// Şimdi is always there: it is where the panel opens (K18).
    @MainActor static var available: [PanelTab] {
        all.filter { isOn($0.view) }
    }

    @MainActor static func isOn(_ view: NotchViews) -> Bool {
        switch view {
        case .home: true
        case .shelf: Defaults[.boringShelf]
        case .calendar: Defaults[.showCalendar]
        case .network: Defaults[.netMonitorEnabled]
        case .tools:
            Defaults[.quickTogglesEnabled] || Defaults[.caffeinateEnabled]
                || Defaults[.focusTimerEnabled] || Defaults[.eyeBreakEnabled]
        }
    }
}

/// The selected page's body. Falls back to Şimdi when the selected page's
/// feature was turned off while the panel was on it.
///
/// A page change slides 8 pt in the direction of the tab bar (the new page
/// comes from the side its tab is on) and crossfades (§3.7 `motion.page`).
/// The shown page lags the selection by one run-loop turn: SwiftUI takes a
/// removed view's transition from its last render, so the leaving page has
/// to be drawn once with the new direction before it is removed.
struct PanelPageView: View {
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @EnvironmentObject private var vm: BoringViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let albumArtNamespace: Namespace.ID

    @State private var shown: NotchViews?
    @State private var direction: CGFloat = 1

    private var selected: NotchViews {
        PanelTab.isOn(coordinator.currentView) ? coordinator.currentView : .home
    }

    var body: some View {
        let page = shown ?? selected
        // A ZStack, not a Group: the leaving and arriving pages overlap
        // during the change instead of stacking in the parent VStack.
        ZStack(alignment: .topLeading) {
            content(page)
                .id(page)
                .transition(.page(direction: direction, reduce: reduceMotion))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: selected) { old, new in
            // close() puts the selection back on Şimdi; the page that is
            // folding away keeps showing what it showed.
            guard vm.notchState == .open else { return }
            direction = Self.index(of: new) >= Self.index(of: old) ? 1 : -1
            DispatchQueue.main.async {
                withAnimation(UmbarMotion.page(reduce: reduceMotion)) { shown = new }
            }
        }
    }

    @ViewBuilder
    private func content(_ view: NotchViews) -> some View {
        switch view {
        case .home: NotchHomeView(albumArtNamespace: albumArtNamespace)
        case .shelf: ShelfView()
        case .calendar: CalendarPage()
        case .network: NetworkPage()
        case .tools: ToolsPage()
        }
    }

    private static func index(of view: NotchViews) -> Int {
        PanelTab.all.firstIndex { $0.view == view } ?? 0
    }
}
