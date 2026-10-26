//
//  AppIdentityTests.swift
//  umbarTests
//
//  Card #40: every dependent name follows the host bundle ID.
//

import Foundation
import Testing

@Suite("AppIdentity")
struct AppIdentityTests {
    @Test func helperServiceNameIsHostIDPlusXPCHelper() {
        #expect(AppIdentity.helperServiceName(hostBundleID: "com.serhadbahadir.umbar")
            == "com.serhadbahadir.umbar.XPCHelper")
    }

    @Test func helperServiceNameFollowsARenamedRoot() {
        #expect(AppIdentity.helperServiceName(hostBundleID: "org.example.fork")
            == "org.example.fork.XPCHelper")
    }

    @Test func shelfDirectoryIsKeyedByHostIDUnderTheBase() {
        let base = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)
        let dir = AppIdentity.shelfDirectory(in: base, hostBundleID: "com.serhadbahadir.umbar")
        #expect(dir.path == "/Users/someone/Library/Application Support/com.serhadbahadir.umbar/Shelf")
        #expect(dir.hasDirectoryPath)
    }

    /// The reason for card #40: two different bundle IDs must never share a
    /// shelf (upstream Boring Notch used a fixed "boringNotch" folder).
    @Test func differentHostsNeverShareAShelf() {
        let base = URL(fileURLWithPath: "/tmp/support", isDirectory: true)
        let ours = AppIdentity.shelfDirectory(in: base, hostBundleID: "com.serhadbahadir.umbar")
        let upstream = AppIdentity.shelfDirectory(in: base, hostBundleID: "theboringteam.boringnotch")
        #expect(ours != upstream)
        #expect(!ours.path.contains("boringNotch"))
    }
}
