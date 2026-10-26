import Foundation

/// Values embedded in the binary at build time (§3.2 rules 4 and 5, §7).
///
/// They live in a Swift constant rather than Info.plist so that changing
/// them means rebuilding and re-signing, which changes the cdhash Habibe
/// compares against the build record.
public struct BuildStampValues: Equatable, Sendable {
    public var targetUID: UInt32?
    public var targetUserName: String
    /// Unix seconds.
    public var builtAt: Int64?
    /// Unix seconds.
    public var expiresAt: Int64?

    public init(targetUID: UInt32?, targetUserName: String, builtAt: Int64?, expiresAt: Int64?) {
        self.targetUID = targetUID
        self.targetUserName = targetUserName
        self.builtAt = builtAt
        self.expiresAt = expiresAt
    }
}

/// Decides whether the runner may start at all. Evaluated in `main` before
/// NSApplication exists, so a refused launch never shows a menu, opens a
/// socket or touches a TCC API.
public enum LaunchGate {
    /// Allowed clock skew backwards from the build time. A clock more than a
    /// day behind the build means the expiry check cannot be trusted.
    public static let allowedBackwardSkew: TimeInterval = 24 * 3600

    public static func check(stamp: BuildStampValues, uid: UInt32, userName: String, now: Date) -> Refusal? {
        guard let targetUID = stamp.targetUID, let builtAt = stamp.builtAt, let expiresAt = stamp.expiresAt else {
            return Refusal(.unstampedBuild)
        }
        // The stamp itself must be sane: expiry after the build and no
        // further out than the 14-day lifetime, so a hand-edited stamp
        // cannot produce a long-lived runner.
        let lifetime = TimeInterval(expiresAt - builtAt)
        guard lifetime > 0, lifetime <= RunnerIdentity.maxLifetime else {
            return Refusal(.badStamp, "lifetime")
        }
        guard stamp.targetUserName == RunnerIdentity.accountName else {
            return Refusal(.badStamp, "account")
        }
        // Both must match: the UID because names can be reused across a
        // delete/recreate, the name because the UID alone says nothing about
        // which account the user intended when building.
        guard uid == targetUID else { return Refusal(.wrongAccount, "uid") }
        guard userName == stamp.targetUserName else { return Refusal(.wrongAccount, "name") }
        // UID 0 and the first admin account (501) are never test accounts.
        guard targetUID != 0, targetUID != 501 else { return Refusal(.wrongAccount, "reserved-uid") }

        let t = now.timeIntervalSince1970
        guard t < TimeInterval(expiresAt) else { return Refusal(.expired) }
        guard t >= TimeInterval(builtAt) - allowedBackwardSkew else { return Refusal(.expired, "clock-before-build") }
        return nil
    }
}
