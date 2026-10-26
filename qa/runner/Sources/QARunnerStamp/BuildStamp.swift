// The committed stamp is deliberately empty: a binary built from this file
// (for example with a plain `swift build`) refuses to start with
// `unstamped-build`. build.sh compiles a stamped copy of this file in a
// staging directory with the target account's UID and the expiry; the
// stamped values never enter git.
//
// Keep the shape of this file in sync with the heredoc in build.sh.
public enum BuildStamp {
    public static let targetUID: UInt32? = nil
    public static let targetUserName = "umbarqa"
    /// Unix seconds.
    public static let builtAt: Int64? = nil
    /// Unix seconds; at most builtAt + 14 days (enforced by LaunchGate).
    public static let expiresAt: Int64? = nil
}
