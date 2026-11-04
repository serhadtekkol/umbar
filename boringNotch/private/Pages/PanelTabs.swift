//
//  PanelTabs.swift
//  boringNotch
//
//  The open panel's pages (design-language §5.2's five, plus the opt-in
//  Ayna) and which of them are on. One list feeds the tab bar, ⌘1…⌘6 and
//  the page switch in ContentView, so a page that is off has no tab and no
//  shortcut.
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
    /// Errors and "overdue" only, always with a glyph: 8.3:1 on black.
    static let danger = Color(red: 0xFF / 255, green: 0x7B / 255, blue: 0x72 / 255)

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
        // With traffic off the page only shows the system row.
        case .network:
            Defaults[.netMonitorEnabled]
                ? String(localized: "panel.tab.network", defaultValue: "Network")
                : String(localized: "panel.tab.system", defaultValue: "System")
        case .tools: String(localized: "panel.tab.tools", defaultValue: "Tools")
        case .mirror: String(localized: "panel.tab.mirror", defaultValue: "Mirror")
        }
    }

    static let all: [PanelTab] = [
        PanelTab(view: .home, page: .now, icon: .asset("MenuBarIcon")),
        PanelTab(view: .shelf, page: .shelf, icon: .system("tray")),
        PanelTab(view: .calendar, page: .calendar, icon: .system("calendar")),
        PanelTab(view: .network, page: .network, icon: .system("network")),
        PanelTab(view: .tools, page: .tools, icon: .system("slider.horizontal.3")),
        // Last: the only page that turns a device on, and opt-in.
        PanelTab(view: .mirror, page: .mirror, icon: .system("person.crop.square")),
    ]

    /// Pages whose feature is on (AC-1.13: a turned-off feature loses its tab).
    /// Şimdi is always there: it is where the panel opens (K18).
    @MainActor static var available: [PanelTab] {
        all.filter { isOn($0.view) }
    }

    @MainActor static func isOn(_ view: NotchViews) -> Bool {
        switch view {
        case .home: true
        // Raf also holds the clipboard history (F21), so it stays while either is on.
        case .shelf: Defaults[.boringShelf] || Defaults[.clipboardHistoryEnabled]
        case .calendar: Defaults[.showCalendar]
        case .network: Defaults[.netMonitorEnabled] || Defaults[.sysMonitorEnabled]
        case .tools:
            Defaults[.quickTogglesEnabled] || Defaults[.caffeinateEnabled]
                || Defaults[.focusTimerEnabled] || Defaults[.eyeBreakEnabled]
        case .mirror: Defaults[.mirrorEnabled]
        }
    }
}

/// The selected page's body. Falls back to Şimdi when the selected page's
/// feature was turned off while the panel was on it.
///
/// Every page change, whichever page and however it was picked (tab click,
/// ←/→, ⌘1…⌘6, a page link), slides `UmbarMotion.pageOffset` from the side
/// its tab is on and crossfades (§3.7 `motion.page`). The animation is
/// started here, not by the caller: the shortcuts set the page without one,
/// and a page change must never depend on who changed it.
///
/// The shown page lags the selection by one run-loop turn: SwiftUI takes a
/// removed view's transition from its last render, so the leaving page has
/// to be drawn once with the new direction before it is removed.
///
/// The panel opening is not a page change: the page arrives with the rest
/// of the panel (ContentView's `islandContent`), so no page view nested in
/// here may carry an insertion transition of its own (Şimdi's used to drop
/// in from the top, on every open and every return to it).
struct PanelPageView: View {
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @EnvironmentObject private var vm: BoringViewModel
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    let albumArtNamespace: Namespace.ID

    @State private var shown: NotchViews?
    @State private var direction: PageDirection = .forward

    #if DEBUG
    private var reduceMotion: Bool { systemReduceMotion || MotionFrameRenderer.forceReduceMotion }
    #else
    private var reduceMotion: Bool { systemReduceMotion }
    #endif

    private var selected: NotchViews {
        PanelTab.isOn(coordinator.currentView) ? coordinator.currentView : .home
    }

    var body: some View {
        let page = shown ?? selected
        // A ZStack, not a Group: the leaving and arriving pages overlap
        // during the change instead of stacking in the parent VStack.
        ZStack(alignment: .topLeading) {
            content(page)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(page)
                .transition(.page(direction: direction.sign, reduce: reduceMotion))
        }
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        // Not clipped here: the island's shape already cuts a sliding page,
        // and a clip would cut the album art flying in from the closed notch
        // (matchedGeometryEffect "albumArt") on open.
        .onChange(of: selected) { old, new in
            // close() puts the selection back on Şimdi; the page that is
            // folding away keeps showing what it showed.
            guard vm.notchState == .open else { return }
            direction = PageDirection.between(old, new, in: PanelTab.all.map(\.view))
            DispatchQueue.main.async {
                withAnimation(UmbarMotion.page(reduce: reduceMotion)) { shown = new }
            }
        }
    }

    @ViewBuilder
    private func content(_ view: NotchViews) -> some View {
        switch view {
        case .home:
            // Şimdi is one compact row (player, today): centred in the page
            // so a tall budget (45 pt notch) leaves no empty band below it.
            NotchHomeView(albumArtNamespace: albumArtNamespace)
                .frame(maxHeight: .infinity, alignment: .center)
        case .shelf: ShelfPage()
        case .calendar: CalendarPage()
        case .network: NetworkPage()
        case .tools: ToolsPage()
        case .mirror: MirrorPageLive()
        }
    }
}
