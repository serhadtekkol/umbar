//
//  CallerRequirementTests.swift
//  umbarTests
//
//  Card #46: which code-signing requirement the XPC helper demands of every
//  caller. The pure rule is tested with every branch; make(helperBundleURL:)
//  is tested against throwaway bundle layouts on disk.
//

import Foundation
import Security
import Testing

@Suite("CallerRequirement")
struct CallerRequirementTests {
    private static let cdhash = Data((0..<20).map(UInt8.init))
    private static let cdhashHex = "000102030405060708090a0b0c0d0e0f10111213"

    /// A requirement string the Security framework would refuse to parse
    /// would make the helper reject every caller, so every produced string is
    /// also compiled.
    private static func compiles(_ requirement: String) -> Bool {
        var compiled: SecRequirement?
        return SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess
            && compiled != nil
    }

    // MARK: Pure rule

    @Test func teamIDSignedBuildRequiresAppleAnchorTeamAndHostID() throws {
        let requirement = try #require(CallerRequirement.requirement(
            hostID: "com.serhadbahadir.umbar", teamID: "264H2ARX4K", hostCDHash: Self.cdhash))
        #expect(requirement == #"anchor apple generic and identifier "com.serhadbahadir.umbar" and certificate leaf[subject.OU] = "264H2ARX4K""#)
        #expect(!requirement.contains("cdhash"), "a Team ID build must not pin one binary")
        #expect(Self.compiles(requirement))
    }

    @Test func adHocBuildPinsHostIDAndExactCDHash() throws {
        let requirement = try #require(CallerRequirement.requirement(
            hostID: "com.serhadbahadir.umbar", teamID: nil, hostCDHash: Self.cdhash))
        #expect(requirement == #"identifier "com.serhadbahadir.umbar" and cdhash H"\#(Self.cdhashHex)""#)
        #expect(Self.compiles(requirement))
    }

    @Test func adHocBuildWithoutCDHashFailsClosed() {
        #expect(CallerRequirement.requirement(hostID: "com.serhadbahadir.umbar", teamID: nil, hostCDHash: nil) == nil)
        #expect(CallerRequirement.requirement(hostID: "com.serhadbahadir.umbar", teamID: nil, hostCDHash: Data()) == nil)
    }

    /// Values are interpolated into the requirement language; anything that
    /// could close the quoted string or add a clause is refused.
    @Test(arguments: [
        "",
        #"com.evil" or identifier "x"#,
        "com.evil or anchor apple",
        "com.evil\nx",
        "com/evil",
    ])
    func unsafeHostIDIsRejected(_ hostID: String) {
        #expect(CallerRequirement.requirement(hostID: hostID, teamID: "264H2ARX4K", hostCDHash: Self.cdhash) == nil)
        #expect(CallerRequirement.requirement(hostID: hostID, teamID: nil, hostCDHash: Self.cdhash) == nil)
    }

    @Test(arguments: ["", #"264H2ARX4K" or anchor apple"#, "TEAM ID"])
    func unsafeTeamIDIsIgnoredInFavorOfTheCDHashPin(_ teamID: String) throws {
        let requirement = try #require(CallerRequirement.requirement(
            hostID: "com.serhadbahadir.umbar", teamID: teamID, hostCDHash: Self.cdhash))
        #expect(requirement.hasPrefix(#"identifier "com.serhadbahadir.umbar" and cdhash H""#))
        #expect(!requirement.contains("OU"))
    }

    @Test func unsafeTeamIDWithoutCDHashFailsClosed() {
        #expect(CallerRequirement.requirement(hostID: "com.serhadbahadir.umbar", teamID: #"x" or true"#, hostCDHash: nil) == nil)
    }

    // MARK: Bundle layout

    /// Builds `Host.app/Contents/XPCServices/Helper.xpc` in a fresh temp
    /// directory and returns the helper URL. With `signedExecutable`, the host
    /// gets a copy of `/usr/bin/true` (an Apple-signed, team-less binary) as
    /// its executable, so the host has a real cdhash and no Team ID.
    private static func makeLayout(
        hostID: String?, signedExecutable: Bool, in root: URL
    ) throws -> URL {
        let contents = root.appendingPathComponent("Host.app/Contents", isDirectory: true)
        let helper = contents.appendingPathComponent("XPCServices/Helper.xpc", isDirectory: true)
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleExecutable": "Host"]
        if let hostID { info["CFBundleIdentifier"] = hostID }
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        if signedExecutable {
            let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"), to: macOS.appendingPathComponent("Host"))
        }
        return helper
    }

    private static func withTempRoot<T>(_ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("umbarTests-caller-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }

    @Test func hostIDComesFromTheBundleThreeLevelsUp() throws {
        try Self.withTempRoot { root in
            let helper = try Self.makeLayout(hostID: "com.example.host", signedExecutable: true, in: root)
            let requirement = try #require(CallerRequirement.make(helperBundleURL: helper))
            #expect(requirement.hasPrefix(#"identifier "com.example.host" and cdhash H""#))
            #expect(requirement.range(of: #"cdhash H"[0-9a-f]{40,}"$"#, options: .regularExpression) != nil)
            #expect(Self.compiles(requirement))
        }
    }

    @Test func unsignedHostFailsClosed() throws {
        try Self.withTempRoot { root in
            let helper = try Self.makeLayout(hostID: "com.example.host", signedExecutable: false, in: root)
            #expect(CallerRequirement.make(helperBundleURL: helper) == nil)
        }
    }

    @Test func hostWithoutBundleIDFailsClosed() throws {
        try Self.withTempRoot { root in
            let helper = try Self.makeLayout(hostID: nil, signedExecutable: true, in: root)
            #expect(CallerRequirement.make(helperBundleURL: helper) == nil)
        }
    }

    @Test func helperOutsideAHostBundleFailsClosed() throws {
        try Self.withTempRoot { root in
            let loose = root.appendingPathComponent("a/b/Helper.xpc", isDirectory: true)
            try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
            #expect(CallerRequirement.make(helperBundleURL: loose) == nil)
        }
    }
}
