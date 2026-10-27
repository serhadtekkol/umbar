//
//  ScreenshotShelfSettings.swift
//  umbar
//
//  F16: the Settings > Shelf rows for "screenshots go to the shelf".
//

import Defaults
import SwiftUI

struct ScreenshotShelfSettingsSection: View {
    @ObservedObject private var controller = ScreenshotShelfController.shared
    @Default(.screenshotShelfEnabled) private var enabled

    var body: some View {
        Section {
            Defaults.Toggle(key: .screenshotShelfEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Put new screenshots on the shelf")
                    Text("Screenshots (⌘⇧3, ⌘⇧4, ⌘⇧5) appear on the shelf right away. The file stays where macOS saved it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if enabled {
                Defaults.Toggle(key: .screenshotShelfIncludeRecordings) {
                    Text("Include screen recordings")
                }
                status
            }
        } header: {
            Text("Screenshots")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch controller.state {
        case .off, .watching:
            EmptyView()
        case .accessDenied(let url):
            VStack(alignment: .leading, spacing: 6) {
                Text("umbar cannot read \(url.lastPathComponent). Allow access under System Settings > Privacy & Security > Files & Folders, then try again.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try again") { controller.retry() }
            }
        case .missing(let url):
            Text("The screenshot folder \(url.path) does not exist.")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
