//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Home", icon: "house.fill", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf)
]

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @EnvironmentObject var vm: BoringViewModel
    @Namespace var animation
    /// Keyboard focus on the tab group. A keyboard opening (shortcut, menu)
    /// puts it here so the selected tab is the first thing the keyboard and
    /// VoiceOver reach (AC-1.18, AC-1.21). ←/→ move between tabs (AC-1.19).
    @FocusState private var tabGroupFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
        .focusable()
        .focused($tabGroupFocused)
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
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

    private func moveSelection(by step: Int) -> KeyPress.Result {
        guard let index = tabs.firstIndex(where: { $0.view == coordinator.currentView }) else { return .ignored }
        let next = index + step
        guard tabs.indices.contains(next) else { return .handled }
        withAnimation(.smooth) {
            coordinator.currentView = tabs[next].view
        }
        return .handled
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
