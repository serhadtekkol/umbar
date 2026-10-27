//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @EnvironmentObject var vm: BoringViewModel
    @Namespace var animation
    /// Keyboard focus on the tab group. A keyboard opening (shortcut, menu)
    /// puts it here so the selected tab is the first thing the keyboard and
    /// VoiceOver reach (AC-1.18, AC-1.21). ←/→ move between tabs (AC-1.19).
    @FocusState private var tabGroupFocused: Bool

    // Read so the bar redraws when a page's feature is switched in Settings
    // while the panel is open; `PanelTab.available` reads the same keys.
    @Default(.boringShelf) private var shelfOn
    @Default(.showCalendar) private var calendarOn
    @Default(.netMonitorEnabled) private var networkOn
    @Default(.quickTogglesEnabled) private var togglesOn
    @Default(.caffeinateEnabled) private var caffeinateOn
    @Default(.focusTimerEnabled) private var focusOn
    @Default(.eyeBreakEnabled) private var eyeBreakOn

    private var tabs: [PanelTab] { PanelTab.available }

    /// The page actually shown: Şimdi stands in for a page that was turned off.
    private var shownView: NotchViews {
        PanelTab.isOn(coordinator.currentView) ? coordinator.currentView : .home
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                TabButton(tab: tab, selected: tab.view == shownView, capsuleNamespace: animation) {
                    select(tab.view)
                }
            }
        }
        // Any change of the selected tab moves the capsule, widens the new
        // tab and slides the neighbours on one spring, including the ⌘1…⌘5
        // shortcuts, which set the page without an animation of their own.
        .animation(UmbarMotion.tab(reduce: reduceMotion), value: shownView)
        .padding(2)
        // System focus ring (design-language §3.1 `island.focus`), not a drawn one.
        .focusable()
        .focused($tabGroupFocused)
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "panel.tabs.a11y", defaultValue: "Pages"))
        .onAppear {
            // The tabs are built when the panel opens, which can be after the
            // notification below was posted.
            if PanelKeyController.shared.isKey(vm) { tabGroupFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelDidTakeKeyboard)) { note in
            guard (note.object as? BoringViewModel) === vm else { return }
            tabGroupFocused = true
        }
    }

    private func select(_ view: NotchViews) {
        withAnimation(UmbarMotion.tab(reduce: reduceMotion)) {
            coordinator.currentView = view
        }
    }

    private func moveSelection(by step: Int) -> KeyPress.Result {
        guard let index = tabs.firstIndex(where: { $0.view == shownView }) else { return .ignored }
        let next = index + step
        guard tabs.indices.contains(next) else { return .handled }
        select(tabs[next].view)
        return .handled
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
