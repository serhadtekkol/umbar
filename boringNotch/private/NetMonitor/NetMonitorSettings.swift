//
//  NetMonitorSettings.swift
//  boringNotch
//
//  Settings > Network (F17): on/off, the closed-notch ear, the opt-in
//  Wi-Fi name (the only place the Location prompt is raised), and
//  deleting the stored totals.
//

import Defaults
import SwiftUI

struct NetMonitorSettings: View {
    @Default(.netMonitorEnabled) private var enabled
    @Default(.netMonitorShowWiFiName) private var showWiFiName
    @ObservedObject private var location = NetLocationAccess.shared
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .netMonitorEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "netmonitor.settings.enabled", defaultValue: "Show network traffic"))
                        Text(String(localized: "netmonitor.settings.enabled.detail",
                                    defaultValue: "Download and upload speed, and how much this network carried this session, today and this month. Measured on this Mac; nothing is sent anywhere."))
                            .font(.subheadline)
                            .foregroundStyle(permissionMutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Defaults.Toggle(key: .netMonitorShowInClosedNotch) {
                    Text(String(localized: "netmonitor.settings.closed", defaultValue: "Show the speed next to the closed notch"))
                }
                .disabled(!enabled)
            }

            Section {
                Defaults.Toggle(key: .sysMonitorEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "sysmonitor.settings.enabled", defaultValue: "Show system status"))
                        Text(String(localized: "sysmonitor.settings.enabled.detail",
                                    defaultValue: "CPU, memory, thermal state and the busiest apps, under the network graph. Read once a second only while that page is open."))
                            .font(.subheadline)
                            .foregroundStyle(permissionMutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text(String(localized: "sysmonitor.settings.header", defaultValue: "System"))
            }

            Section {
                Toggle(isOn: Binding(
                    get: { showWiFiName },
                    set: { newValue in
                        showWiFiName = newValue
                        if newValue { location.request() }
                    })
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(localized: "netmonitor.settings.wifiName", defaultValue: "Show the Wi-Fi name"))
                        Text(String(localized: "netmonitor.settings.wifiName.detail",
                                    defaultValue: "macOS only reveals the Wi-Fi name to apps with Location access. umbar uses that access for the name alone and never reads your location. Without it the network is shown as \u{201C}This network (Wi-Fi)\u{201D}."))
                            .font(.subheadline)
                            .foregroundStyle(permissionMutedText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!enabled || location.state == .unavailable)

                if showWiFiName {
                    switch location.state {
                    case .denied:
                        HStack {
                            Label(String(localized: "netmonitor.settings.location.denied", defaultValue: "Location access is off for umbar."),
                                  systemImage: "lock")
                            Spacer()
                            Button(String(localized: "netmonitor.settings.location.open", defaultValue: "Open System Settings")) {
                                location.openSystemSettings()
                            }
                        }
                    case .notDetermined:
                        HStack {
                            Text(String(localized: "netmonitor.settings.location.ask", defaultValue: "umbar needs Location access to read the Wi-Fi name."))
                            Spacer()
                            Button(String(localized: "netmonitor.settings.location.allow", defaultValue: "Allow access")) {
                                location.request()
                            }
                        }
                    case .unavailable:
                        Text(String(localized: "netmonitor.settings.location.unavailable", defaultValue: "This build of umbar cannot ask for Location access."))
                            .foregroundStyle(permissionMutedText)
                    case .granted:
                        EmptyView()
                    }
                }
            } header: {
                Text(String(localized: "netmonitor.settings.name.header", defaultValue: "Network name"))
            }

            Section {
                HStack {
                    Text(String(localized: "netmonitor.settings.delete.title", defaultValue: "Stored traffic totals"))
                    Spacer()
                    if confirmDelete {
                        Button(String(localized: "netmonitor.reset.cancel", defaultValue: "Cancel")) { confirmDelete = false }
                        Button(String(localized: "netmonitor.settings.delete.confirm", defaultValue: "Delete"), role: .destructive) {
                            confirmDelete = false
                            NetMonitor.shared.resetAll()
                        }
                    } else {
                        Button(String(localized: "netmonitor.settings.delete", defaultValue: "Delete all\u{2026}")) { confirmDelete = true }
                    }
                }
            } footer: {
                Text(String(localized: "netmonitor.settings.delete.footer",
                            defaultValue: "Daily totals per network are kept for 30 days (and for the whole current month) in umbar's Application Support folder. Networks are stored as an anonymous fingerprint of the router."))
                    .font(.caption)
                    .foregroundStyle(permissionMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accentColor(.effectiveAccent)
        .navigationTitle(String(localized: "netmonitor.settings.title", defaultValue: "Network"))
        .onAppear { if showWiFiName { location.refresh() } }
    }
}
