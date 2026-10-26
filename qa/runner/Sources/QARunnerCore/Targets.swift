import Foundation

// MARK: - Finding umbar (§3.5 "umbar'ı bulma")

/// A running application as seen by the locator.
public struct AppCandidate: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String?
    /// Bundle path with symlinks resolved.
    public var bundleRealPath: String?

    public init(pid: Int32, bundleID: String?, bundleRealPath: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.bundleRealPath = bundleRealPath
    }
}

public enum UmbarLocatorPolicy {
    public static func isUmbarBundleID(_ id: String?) -> Bool {
        guard let id else { return false }
        if id == UmbarIdentity.releaseBundleID { return true }
        guard id.hasPrefix(UmbarIdentity.qaBundleIDPrefix) else { return false }
        let suffix = id.dropFirst(UmbarIdentity.qaBundleIDPrefix.count)
        return !suffix.isEmpty && Names.isValidAXIdentifier(String(suffix))
    }

    /// `/Applications/umbar.app` or `~/umbar-qa/builds/**/umbar.app`.
    public static func isAllowedLocation(_ realPath: String?, realHome: String) -> Bool {
        guard let realPath else { return false }
        if realPath == UmbarIdentity.installedPath { return true }
        let buildsRoot = (realHome as NSString).appendingPathComponent("umbar-qa/builds") + "/"
        guard realPath.hasPrefix(buildsRoot) else { return false }
        let components = realPath.split(separator: "/")
        return components.last == "umbar.app" && !components.contains("..") && !components.contains(".")
    }

    /// Picks the one umbar instance. Several matching instances are refused
    /// rather than guessed between (test-plan §4.3: concurrent instances
    /// share one defaults domain and are themselves a test hazard).
    public static func select(_ candidates: [AppCandidate], realHome: String) -> Result<AppCandidate, Refusal> {
        let matches = candidates.filter {
            isUmbarBundleID($0.bundleID) && isAllowedLocation($0.bundleRealPath, realHome: realHome)
        }
        switch matches.count {
        case 0: return .failure(Refusal(.umbarNotRunning))
        case 1: return .success(matches[0])
        default: return .failure(Refusal(.umbarMultipleInstances, String(matches.count)))
        }
    }

    /// Code-signing rule. A Developer ID build must be ours and must satisfy
    /// the team requirement. An unsigned/ad-hoc build (A-Debug, no Team ID)
    /// is accepted on path + bundle ID alone; that is the weaker case
    /// recorded as RAID R-5.
    public static func checkSignature(teamID: String?, satisfiesTeamRequirement: Bool) -> Refusal? {
        guard let teamID else { return nil }
        guard teamID == RunnerIdentity.teamID, satisfiesTeamRequirement else {
            return Refusal(.umbarSignature)
        }
        return nil
    }
}

// MARK: - Hit testing (§3.5 pointer.*, drag)

/// What `AXUIElementCopyElementAtPosition` found at a point.
public struct HitResult: Equatable, Sendable {
    /// Owner PID of the element, `nil` when nothing was found.
    public var pid: Int32?
    /// `AXDocument` of the element's window, used for Finder windows.
    public var windowDocument: String?
    /// `AXRole`/`AXSubrole` of the element; secure text is never a target.
    public var role: String?
    public var subrole: String?

    public init(pid: Int32?, windowDocument: String? = nil, role: String? = nil, subrole: String? = nil) {
        self.pid = pid
        self.windowDocument = windowDocument
        self.role = role
        self.subrole = subrole
    }
}

public enum HitExpectation: Sendable {
    case umbar(pid: Int32)
    /// The runner-opened Finder window showing exactly this resolved folder.
    case finderDrop(finderPID: Int32, folderRealPath: String)
}

public enum HitTestPolicy {
    /// Verifies that the element under a point belongs to the expected
    /// target *before* any event is posted to that point.
    public static func verify(_ hit: HitResult, expect: HitExpectation, runnerPID: Int32, dropArea: DropArea) -> Refusal? {
        guard let pid = hit.pid else { return Refusal(.hitTestEmpty) }
        // Never post to the runner's own windows: its menu is the arm
        // control (§3.5 "kendi penceresine olay gönderme").
        guard pid != runnerPID else { return Refusal(.targetIsRunner) }
        if hit.role == AXRoles.secureTextField || hit.subrole == AXRoles.secureTextField {
            return Refusal(.hitTestNotOwned, "secure-field")
        }
        switch expect {
        case .umbar(let umbarPID):
            guard umbarPID != runnerPID else { return Refusal(.targetIsRunner) }
            return pid == umbarPID ? nil : Refusal(.hitTestNotOwned)
        case .finderDrop(let finderPID, let folder):
            guard pid == finderPID else { return Refusal(.hitTestNotOwned) }
            guard dropArea.documentMatches(hit.windowDocument, folderRealPath: folder) else {
                return Refusal(.hitTestNotOwned, "finder-window")
            }
            return nil
        }
    }

    /// Key events go to whatever has focus, so they are allowed only when
    /// focus is in umbar (§3.5 `key`).
    public static func verifyFocus(focusedPID: Int32?, umbarPID: Int32, runnerPID: Int32) -> Refusal? {
        guard let focusedPID, focusedPID == umbarPID, umbarPID != runnerPID else {
            return Refusal(.focusNotInUmbar)
        }
        return nil
    }
}

public enum AXRoles {
    public static let secureTextField = "AXSecureTextField"
}

/// AX values are returned on the socket only, never logged (§3.8), and the
/// value of a secure text field is never read at all (§3.5 `ax.tree`).
public enum AXValuePolicy {
    public static func shouldReadValue(role: String?, subrole: String?) -> Bool {
        role != AXRoles.secureTextField && subrole != AXRoles.secureTextField
    }

    public static func truncate(_ s: String) -> String {
        s.count <= CommandLimits.axMaxValueLength ? s : String(s.prefix(CommandLimits.axMaxValueLength))
    }
}
