//
//  LiveActivitiesSettingsSection.swift
//  boringNotch
//
//  Settings > General > "Live activities" (F19): one toggle per source, and
//  the in-context request for Downloads-folder access.
//

import AppKit
import Defaults
import SwiftUI

struct LiveActivitiesSettingsSection: View {
    @ObservedObject private var center = LiveActivityCenter.shared
    @Default(.liveActivityDownloadsEnabled) private var downloadsEnabled
    @Default(.liveActivityAirDropEnabled) private var airDropEnabled

    /// Privacy & Security > Files & Folders, in the URL form the onboarding
    /// permission rows use (PermissionsRequestView).
    private static let filesAndFoldersURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!

    var body: some View {
        Section {
            Defaults.Toggle(key: .liveActivityChargingEnabled) {
                Text(String(localized: "liveActivity.settings.charging", defaultValue: "Time to full while charging"))
            }
            Defaults.Toggle(key: .liveActivityDownloadsEnabled) {
                Text(String(localized: "liveActivity.settings.downloads", defaultValue: "Download progress"))
            }
            Defaults.Toggle(key: .liveActivityAirDropEnabled) {
                Text(String(localized: "liveActivity.settings.airDrop", defaultValue: "Files received over AirDrop"))
            }
            Defaults.Toggle(key: .liveActivityTimeMachineEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "liveActivity.settings.timeMachine", defaultValue: "Time Machine backup finished"))
                    if !center.timeMachineConfigured {
                        Text(String(localized: "liveActivity.settings.timeMachine.notConfigured",
                                    defaultValue: "Time Machine is not set up on this Mac."))
                            .font(.subheadline)
                            .foregroundStyle(permissionMutedText)
                    }
                }
            }

            if downloadsEnabled || airDropEnabled {
                downloadsAccessRow
            }
        } header: {
            Text(String(localized: "liveActivity.settings.header", defaultValue: "Live activities"))
        } footer: {
            Text(String(localized: "liveActivity.settings.footer",
                        defaultValue: "Shown under the notch while it happens and on the Now page. Time Machine shows when a backup finishes, not its progress."))
                .font(.caption)
                .foregroundStyle(permissionMutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var downloadsAccessRow: some View {
        switch center.downloadsAccess {
        case .notRequested:
            LabeledContent {
                Button(String(localized: "liveActivity.settings.allow", defaultValue: "Allow access")) {
                    center.requestDownloadsAccess()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "liveActivity.settings.downloadsAccess", defaultValue: "Downloads folder"))
                    Text(String(localized: "liveActivity.settings.downloadsAccess.why",
                                defaultValue: "umbar reads file names and sizes in Downloads to show progress. macOS asks once."))
                        .font(.subheadline)
                        .foregroundStyle(permissionMutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .denied:
            LabeledContent {
                HStack {
                    Button(String(localized: "liveActivity.settings.retry", defaultValue: "Try again")) {
                        center.requestDownloadsAccess()
                    }
                    Button(String(localized: "liveActivity.settings.openSettings", defaultValue: "Open System Settings")) {
                        NSWorkspace.shared.open(Self.filesAndFoldersURL)
                    }
                }
            } label: {
                Label(String(localized: "liveActivity.settings.downloadsDenied",
                             defaultValue: "Downloads folder access is off"),
                      systemImage: "exclamationmark.circle")
            }
        case .watching, .off:
            EmptyView()
        }
    }
}
