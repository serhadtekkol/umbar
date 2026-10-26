//
//  CallerRequirement.swift
//  BoringNotchXPCHelper
//

import Foundation
import Security

/// Builds the code-signing requirement every incoming XPC connection must
/// satisfy (card #46).
///
/// The helper runs unsandboxed and drives private brightness APIs and the
/// Accessibility prompt, so it must only talk to its own host app. launchd
/// already scopes an embedded XPC service to its host bundle; this check is
/// the second lock, enforced by the kernel-backed audit token on each message
/// via `NSXPCConnection.setCodeSigningRequirement(_:)`.
///
/// The requirement is derived at runtime rather than hard-coded, so a bundle
/// ID or team change (card #40) needs no edit here:
/// - host identifier: the bundle that contains this helper
///   (`Host.app/Contents/XPCServices/Helper.xpc`);
/// - Team ID signed build: `anchor apple generic` + same Team ID as the
///   helper's own signature + host identifier;
/// - ad-hoc build (local Debug, no Team ID): host identifier + the host
///   executable's exact cdhash, so only that very binary is accepted.
///
/// Returns `nil` when the requirement cannot be determined; callers must then
/// reject the connection (fail closed).
enum CallerRequirement {
    static func make(helperBundleURL: URL = Bundle.main.bundleURL) -> String? {
        let hostURL = helperBundleURL
            .deletingLastPathComponent() // XPCServices
            .deletingLastPathComponent() // Contents
            .deletingLastPathComponent() // Host.app
        guard let hostID = Bundle(url: hostURL)?.bundleIdentifier else { return nil }
        let team = signingInfo(ofCodeAt: helperBundleURL)?[kSecCodeInfoTeamIdentifier as String] as? String
        // The host's cdhash is only needed when there is no usable Team ID;
        // skip the second signature read otherwise.
        let hostCDHash = team.map(isSafeIdentifier) == true
            ? nil
            : signingInfo(ofCodeAt: hostURL)?[kSecCodeInfoUnique as String] as? Data
        return requirement(hostID: hostID, teamID: team, hostCDHash: hostCDHash)
    }

    /// The requirement string for already-extracted signing facts.
    ///
    /// - Parameters:
    ///   - hostID: The host app's bundle identifier.
    ///   - teamID: The helper's own Team ID, or `nil` for an ad-hoc signature.
    ///     An unsafe value is treated like a missing one.
    ///   - hostCDHash: The host executable's cdhash, used only without a Team ID.
    /// - Returns: The Team ID requirement when `teamID` is usable, otherwise
    ///   the identifier + cdhash requirement, or `nil` (reject) when neither
    ///   can be built or `hostID` is unsafe.
    static func requirement(hostID: String, teamID: String?, hostCDHash: Data?) -> String? {
        guard isSafeIdentifier(hostID) else { return nil }

        if let teamID, isSafeIdentifier(teamID) {
            return "anchor apple generic and identifier \"\(hostID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        }

        guard let hostCDHash, !hostCDHash.isEmpty else { return nil }
        let hex = hostCDHash.map { String(format: "%02x", $0) }.joined()
        return "identifier \"\(hostID)\" and cdhash H\"\(hex)\""
    }

    private static func signingInfo(ofCodeAt url: URL) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess else { return nil }
        return info as? [String: Any]
    }

    /// Bundle IDs and Team IDs are interpolated into the requirement language;
    /// refuse anything that could break out of the quoted string.
    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }
}
