import Foundation

/// Every path the runner and `qa-cli` use, derived from the account's real
/// home directory. Shared so the client and the server cannot disagree on
/// where the socket is.
public struct RunnerPaths: Sendable {
    public let realHome: String
    public let supportDir: String
    /// 0700 directory holding the socket (§3.3).
    public let socketDir: String
    public let socketPath: String
    /// Kill switch: while this exists the runner disarms and cannot be armed.
    public let killFile: String
    public let evidenceRoot: String
    public let silentAssertion: String

    public init(realHome: String) {
        let home = realHome as NSString
        self.realHome = realHome
        supportDir = home.appendingPathComponent("Library/Application Support/\(RunnerIdentity.bundleID)")
        socketDir = (supportDir as NSString).appendingPathComponent("run")
        socketPath = (socketDir as NSString).appendingPathComponent("ctl.sock")
        killFile = (supportDir as NSString).appendingPathComponent("KILL")
        evidenceRoot = home.appendingPathComponent("umbar-qa/evidence")
        silentAssertion = home.appendingPathComponent("umbar-qa/silent-precondition")
    }

    /// `sockaddr_un.sun_path` holds 104 bytes including the terminator.
    public var socketPathFits: Bool { socketPath.utf8.count < 104 }
}
