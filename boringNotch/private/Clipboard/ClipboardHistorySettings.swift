//
//  ClipboardHistorySettings.swift
//  umbar
//
//  F21: the Settings > Shelf rows for the clipboard history.
//

import Defaults
import SwiftUI

struct ClipboardHistorySettingsSection: View {
    @ObservedObject private var model = ClipboardHistoryModel.shared
    @Default(.clipboardHistoryEnabled) private var enabled
    @Default(.clipboardHistoryLimit) private var limit

    var body: some View {
        Section {
            Defaults.Toggle(key: .clipboardHistoryEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "settings.clipboard.toggle", defaultValue: "Keep a clipboard history"))
                    Text(String(localized: "settings.clipboard.toggle.detail",
                                defaultValue: "Text, links and images you copy appear on the Shelf page under Clipboard. Click one to copy it again. Passwords and items apps mark as private are never saved. Turning this off deletes the history."))
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
}
