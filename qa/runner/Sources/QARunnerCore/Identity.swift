import Foundation

/// Fixed identities and limits of the runner (docs/qa-gui-runner.md §3).
///
/// Everything here is a compile-time constant on purpose: the design forbids
/// any "temporarily allow everything" switch (§3.3), so there is no
/// configuration file, environment variable or defaults key that can widen
/// these values at run time.
public enum RunnerIdentity {
    /// Outside `UMBAR_BUNDLE_ID_ROOT` so `qa/tcc-reset.sh <root>` for umbar
    /// never resets the runner's grants and vice versa (§3.1).
    public static let bundleID = "com.serhadbahadir.qarunner"
    public static let logSubsystem = bundleID
    /// Team that signs both the runner and Developer ID builds of umbar.
    public static let teamID = "264H2ARX4K"
    /// The only account the runner may run in (§4).
    public static let accountName = "umbarqa"
    /// Build-to-expiry window (§3.2 rule 5).
    public static let maxLifetime: TimeInterval = 14 * 24 * 3600
}

public enum UmbarIdentity {
    public static let releaseBundleID = "com.serhadbahadir.umbar"
    /// QA builds use `com.serhadbahadir.umbar.qa.<suffix>` (test-plan §4.3).
    public static let qaBundleIDPrefix = "com.serhadbahadir.umbar.qa."
    public static let installedPath = "/Applications/umbar.app"
    public static let finderBundleID = "com.apple.finder"
}

/// Wire limits (§3.3).
public enum WireLimits {
    /// One request is one line of at most this many bytes, newline excluded.
    public static let maxLineBytes = 4096
    public static let maxFields = 16
}

/// Per-command parameter bounds (§3.5). These are the "Sınır" column.
public enum CommandLimits {
    public static let recordMaxSeconds = 1...30
    public static let axDepth = 1...12
    public static let hoverDwellMs = 0...5000
    public static let measureRuns = 1...20
    public static let shelfIndex = 0...99
    /// AX tree node cap; keeps a runaway tree from producing megabytes.
    public static let axMaxNodes = 2000
    /// AX string values are truncated to this many characters on the wire.
    public static let axMaxValueLength = 512
}
