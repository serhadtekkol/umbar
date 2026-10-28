//
//  QuickTogglesSettings.swift
//  boringNotch
//
//  Settings > Quick toggles (F20): show the row, pick the Focus shortcut,
//  and see each permission the toggles use. Permissions are only requested
//  from a button here or from a tile tap, never at launch.
//

import Defaults
import SwiftUI

struct QuickTogglesSettings: View {
    @Default(.quickTogglesEnabled) private var enabled
    @Default(.quickTogglesFocusShortcut) private var focusShortcut
    @ObservedObject private var store = QuickTogglesStore.shared
    @State private var shortcutNames: [String] = []
    @State private var loadingShortcuts = true
    @State private var focusPermission: QuickPermission = .notDetermined

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .quickTogglesEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show quick toggles in the notch")
                        Text("Wi-Fi, Bluetooth devices, Focus and Dark Mode, in one row on the Now page.")
                            .font(.subheadline)
                            .foregroundStyle(permissionMutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section {
                Picker("Shortcut to run", selection: $focusShortcut) {
                    Text("None").tag("")
                    ForEach(pickerNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .disabled(loadingShortcuts)
                if store.backend.focusConfigured {
                    LabeledContent("Show whether a Focus is on") {
                        permissionControl(focusPermission, deniedPane: .focus) {
                            Task { focusPermission = await store.backend.requestFocusPermission() }
                        }
                    }
                }
            } header: {
                Text("Focus")
            } footer: {
                Text("macOS does not let apps switch Focus directly. Make a shortcut in the Shortcuts app with the \"Set Focus\" action (for example, turn Do Not Disturb on or off) and choose it here; the Focus tile runs it in the background.")
                    .font(.caption)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!enabled)

            Section {
                Defaults.Toggle(key: .btBatteryEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Bluetooth device batteries")
                        Text("Levels of connected AirPods, Magic Mouse, Keyboard and Trackpad on the Tools page, and a short notice under the notch when one connects.")
                            .font(.subheadline)
                            .foregroundStyle(permissionMutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } footer: {
                Text("AirPods levels need the Bluetooth permission below; Magic devices show theirs without it. Per-ear levels appear only for models that report them to macOS.")
                    .font(.caption)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent("Bluetooth devices") {
                    if store.backend.bluetoothConfigured {
                        permissionControl(store.bluetoothPermission, deniedPane: .bluetoothPrivacy) {
                            Task { await store.activate(.bluetooth) }
                        }
                    } else {
                        Text("Not available in this build")
                            .foregroundStyle(permissionMutedText)
                    }
                }
                LabeledContent("Dark Mode") {
                    Text("Asks to control System Events on first use")
                        .foregroundStyle(permissionMutedText)
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Bluetooth itself cannot be switched on or off by apps; when it is off, the tile opens Bluetooth Settings. Changing Dark Mode from umbar turns off the Auto appearance, as choosing Light or Dark in System Settings does.")
                    .font(.caption)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!enabled)
        }
        .accentColor(.effectiveAccent)
        .navigationTitle("Quick toggles")
        .task {
            focusPermission = store.backend.focusPermission()
            shortcutNames = await store.backend.shortcutNames()
            loadingShortcuts = false
        }
    }

    /// Keeps a saved name selectable even if the shortcut was renamed or
    /// deleted since, so the picker never shows a blank selection.
    private var pickerNames: [String] {
        if focusShortcut.isEmpty || shortcutNames.contains(focusShortcut) { return shortcutNames }
        return [focusShortcut] + shortcutNames
    }

    @ViewBuilder
    private func permissionControl(
        _ permission: QuickPermission,
        deniedPane: QuickSettingsPane,
        request: @escaping () -> Void
    ) -> some View {
        switch permission {
        case .granted:
            Text("Allowed").foregroundStyle(permissionMutedText)
        case .notDetermined:
            Button("Allow…", action: request)
        case .denied, .restricted:
            Button("Open System Settings") {
                store.backend.open(deniedPane)
            }
        }
    }
}
