//
//  ClipboardHistorySettings.swift
//  umbar
//
//  F21: the Settings > Shelf rows for the clipboard history.
//

import AppKit
import Defaults
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardHistorySettingsSection: View {
    @ObservedObject private var model = ClipboardHistoryModel.shared
    @Default(.clipboardHistoryEnabled) private var enabled
    @Default(.clipboardHistoryLimit) private var limit
    @Default(.clipboardHistoryRetentionDays) private var retentionDays

    var body: some View {
        Section {
            Defaults.Toggle(key: .clipboardHistoryEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "settings.clipboard.toggle", defaultValue: "Keep a clipboard history"))
                    Text(String(localized: "settings.clipboard.toggle.detail",
                                defaultValue: "Text, links and images you copy appear on the Shelf page under Clipboard. Click one to copy it again. Items that apps mark as private or concealed, and copies from known password managers and the apps you exclude below, are not saved. Turning this off deletes the history."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if enabled {
                Picker(String(localized: "settings.clipboard.limit", defaultValue: "Keep the last"), selection: $limit) {
                    ForEach(ClipboardHistoryPolicy.limitChoices, id: \.self) { n in
                        Text(String(localized: "settings.clipboard.limit.items", defaultValue: "\(n) items")).tag(n)
                    }
                }
                Picker(String(localized: "settings.clipboard.retention", defaultValue: "Delete items after"), selection: $retentionDays) {
                    ForEach(ClipboardHistoryPolicy.retentionChoices, id: \.self) { days in
                        Text(Self.retentionLabel(days)).tag(days)
                    }
                }
                ClipboardExcludedAppsRows()
                if model.permissionRequired {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "settings.clipboard.permission",
                                    defaultValue: "macOS asks before umbar reads what you copy, so nothing is being saved. Set umbar to Allow under System Settings > Privacy & Security > Paste from Other Apps."))
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(String(localized: "clipboard.permission.open", defaultValue: "Open Settings")) {
                            model.openPasteboardPrivacySettings()
                        }
                    }
                }
                Button(String(localized: "settings.clipboard.clear", defaultValue: "Clear history"), role: .destructive) {
                    model.clearAll()
                }
                .disabled(model.items.isEmpty)
            }
        } header: {
            Text(String(localized: "settings.clipboard.header", defaultValue: "Clipboard"))
        } footer: {
            Text(String(localized: "settings.clipboard.footer",
                        defaultValue: "The history is stored only on this Mac, readable only by your user account, and is not included in Time Machine backups. Images larger than \(ClipboardHistoryPolicy.maxImageBytes / 1_048_576) MB are not saved."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func retentionLabel(_ days: Int) -> String {
        switch days {
        case 0: String(localized: "settings.clipboard.retention.never", defaultValue: "Never")
        case 1: String(localized: "settings.clipboard.retention.day", defaultValue: "1 day")
        default: String(localized: "settings.clipboard.retention.days", defaultValue: "\(days) days")
        }
    }
}

/// AC-4.5: the user's own "never record copies from these apps" list.
/// Apps are added with an app picker, so the user never has to know a
/// bundle ID; the list shows each app's name and icon when it is installed
/// and the raw bundle ID when it is not.
private struct ClipboardExcludedAppsRows: View {
    @Default(.clipboardExcludedBundleIDs) private var excluded

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "settings.clipboard.excluded", defaultValue: "Never save copies from"))
            ForEach(excluded, id: \.self) { bundleID in
                HStack(spacing: 8) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(FileManager.default.displayName(atPath: url.path))
                    } else {
                        Text(bundleID).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        excluded.removeAll { $0 == bundleID }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "settings.clipboard.excluded.remove", defaultValue: "Remove"))
                }
            }
            Button(String(localized: "settings.clipboard.excluded.add", defaultValue: "Add App…")) {
                addApps()
            }
        }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier, !excluded.contains(id) else { continue }
            excluded.append(id)
        }
    }
}
