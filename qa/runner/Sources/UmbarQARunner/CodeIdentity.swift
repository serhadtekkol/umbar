import Foundation
import QARunnerCore
import Security

/// Code-signing facts, read in-process through the Security framework (no
/// `codesign` subprocess).
struct SigningInfo {
    var cdhash: String?
    var teamID: String?
    var identifier: String?
    var hardenedRuntime: Bool
}

enum CodeIdentity {
    /// The running runner's own identity, logged at launch and returned by
    /// `status` so Habibe can compare it with the build record (§3.3, A3).
    static func current() -> SigningInfo {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return SigningInfo(cdhash: nil, teamID: nil, identifier: nil, hardenedRuntime: false)
        }
        return info(of: code)
    }

    /// Identity of another running process (umbar), by PID.
    static func of(pid: Int32) -> (code: SecCode, info: SigningInfo)? {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return nil }
        return (code, info(of: code))
    }

    /// `anchor apple generic and certificate leaf[subject.OU] = <team>`:
    /// true only for a valid Developer ID signature from our team.
    static func satisfiesTeamRequirement(_ code: SecCode) -> Bool {
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(RunnerIdentity.teamID)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func info(of code: SecCode) -> SigningInfo {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return SigningInfo(cdhash: nil, teamID: nil, identifier: nil, hardenedRuntime: false)
        }
        var dict: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &dict) == errSecSuccess,
              let info = dict as? [String: Any] else {
            return SigningInfo(cdhash: nil, teamID: nil, identifier: nil, hardenedRuntime: false)
        }
        let cdhash = (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        let codeFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        // 0x10000 is CS_RUNTIME, shown by codesign as flags=0x10000(runtime).
        return SigningInfo(cdhash: cdhash,
                           teamID: info[kSecCodeInfoTeamIdentifier as String] as? String,
                           identifier: info[kSecCodeInfoIdentifier as String] as? String,
                           hardenedRuntime: (codeFlags & 0x10000) != 0)
    }
}
