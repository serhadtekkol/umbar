import Foundation

/// A machine-readable reason for refusing a request, a launch or an arm.
///
/// The raw value is what goes on the wire as `{"ok":false,"refused":"<code>"}`
/// and into both logs. Codes are stable: a test or a detection rule may match
/// on them, so a code is never renamed or reused for a different meaning; add
/// a new case instead. `detail` carries the offending field or value name
/// (never an AX value or user content) and is appended as `code:detail`.
public struct Refusal: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable, CaseIterable {
        // Wire / schema
        case lineTooLong = "line-too-long"
        case malformedJSON = "malformed-json"
        case unsupportedValue = "unsupported-value"
        case duplicateField = "duplicate-field"
        case tooManyFields = "too-many-fields"
        case missingCommand = "missing-command"
        case unknownCommand = "unknown-command"
        case unknownField = "unknown-field"
        case missingField = "missing-field"
        case wrongType = "wrong-type"
        case outOfRange = "out-of-range"
        case invalidName = "invalid-name"

        // Arm / session state
        case disarmed
        case killFilePresent = "kill-file-present"
        case notOnConsole = "session-not-on-console"
        case screenLocked = "screen-locked"
        case secureInput = "secure-input-enabled"
        case notPhysicalClick = "not-a-physical-click"

        // Launch gate
        case unstampedBuild = "unstamped-build"
        case wrongAccount = "wrong-account"
        case expired = "build-expired"
        case badStamp = "bad-stamp"

        // Peer
        case peerUIDMismatch = "peer-uid-mismatch"

        // Targets
        case umbarNotRunning = "umbar-not-running"
        case umbarMultipleInstances = "umbar-multiple-instances"
        case umbarSignature = "umbar-signature-rejected"
        case targetNotFound = "target-not-found"
        case hitTestEmpty = "hit-test-empty"
        case hitTestNotOwned = "hit-test-not-owned"
        case targetIsRunner = "target-is-runner"
        case focusNotInUmbar = "focus-not-in-umbar"
        case dropPathRejected = "drop-path-rejected"
        case noFinderDropWindow = "no-finder-drop-window"
        case noNotchDisplay = "no-notch-display"
        case regionRejected = "region-rejected"
        case alertAllowlistEmpty = "alert-allowlist-empty"
        case recordingActive = "recording-active"
        case noRecording = "no-recording"

        // Audio preconditions (§3.7)
        case beepFeedbackOn = "beep-feedback-on"
        case silentNotAsserted = "silent-precondition-not-asserted"
        case volumeUnreadable = "volume-unreadable"
        case volumeCeiling = "volume-ceiling"

        // Permissions / writes
        case permissionMissing = "permission-missing"
        case writeOutsideAllowedRoots = "write-outside-allowed-roots"
        case ioError = "io-error"
    }

    public let code: Code
    public let detail: String?

    public init(_ code: Code, _ detail: String? = nil) {
        self.code = code
        self.detail = detail.map(Refusal.sanitize)
    }

    /// Details can echo caller input (an unknown command name, say) into the
    /// unified log and the JSONL file. Keep them short and boring so a
    /// request cannot forge log lines or smuggle content into the logs.
    static func sanitize(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        let mapped = raw.prefix(64).map { allowed.contains($0) ? $0 : "?" }
        return String(mapped)
    }

    /// The wire form: `code` or `code:detail`.
    public var description: String {
        guard let detail, !detail.isEmpty else { return code.rawValue }
        return "\(code.rawValue):\(detail)"
    }
}
