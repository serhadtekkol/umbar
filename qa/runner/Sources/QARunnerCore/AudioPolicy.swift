import Foundation

/// Preconditions for `media-key volume-*` (§3.7). The user approved only a
/// fully silent test track, so a volume key is refused unless the runner can
/// show the setup cannot make an audible sound.
public enum AudioPolicy {
    /// Output level the runner never raises the volume above (§3.7 rule 3).
    public static let volumeCeiling: Float = 0.30
    /// One volume key press moves the level by 1/16 on macOS.
    public static let volumeStep: Float = 1.0 / 16.0

    /// The contents Habibe writes, over SSH, to
    /// `~/umbar-qa/silent-precondition` after checking the Music library
    /// (§3.7 rule 2, which the runner cannot verify itself without
    /// Automation).
    public static let silentAssertionText = "asserted-by habibe"

    /// - Parameters:
    ///   - beepFeedback: `com.apple.sound.beep.feedback` from the global
    ///     domain; `nil` when unset (the system default, off).
    ///   - silentAsserted: result of `isSilentAssertionValid`.
    ///   - currentVolume: default output device level, `nil` if unreadable.
    public static func check(_ key: MediaKeyName, beepFeedback: Int?, silentAsserted: Bool, currentVolume: Float?) -> Refusal? {
        guard key.isVolume else { return nil }
        if beepFeedback == 1 { return Refusal(.beepFeedbackOn) }
        guard silentAsserted else { return Refusal(.silentNotAsserted) }
        guard let currentVolume, currentVolume.isFinite else { return Refusal(.volumeUnreadable) }
        if key == .volumeUp, currentVolume + volumeStep > volumeCeiling + 0.0001 {
            return Refusal(.volumeCeiling)
        }
        return nil
    }

    /// The assertion counts only for the current armed session: written
    /// after the session was armed, with exactly the expected text. A marker
    /// left over from yesterday's run does not carry over.
    public static func isSilentAssertionValid(contents: String?, modifiedAt: Date?, armedSince: Date?) -> Bool {
        guard let contents, let modifiedAt, let armedSince else { return false }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines) == silentAssertionText
            && modifiedAt >= armedSince
    }
}

/// Where the runner may write (§3.2 rule 7, §3.8). Every file the runner
/// creates goes through `isAllowed`, and evidence files are created with
/// `O_EXCL | O_NOFOLLOW` by the caller so nothing is overwritten.
///
/// Note: §3.2 rule 7 lists two roots, §3.8 adds `~/Library/Logs/UmbarQARunner`
/// for the JSONL log. The log root is included here as specified in §3.8;
/// flagged for Muhittin's review as a wording mismatch, not a widening.
public struct WritePolicy: Sendable {
    public let roots: [String]

    public init(realHome: String) {
        let home = realHome as NSString
        roots = [
            home.appendingPathComponent("Library/Application Support/\(RunnerIdentity.bundleID)"),
            home.appendingPathComponent("umbar-qa/evidence"),
            home.appendingPathComponent("Library/Logs/UmbarQARunner"),
        ]
    }

    /// `path` is allowed when its parent directory resolves to one of the
    /// roots or to a directory below one. The leaf itself is not resolved:
    /// it may not exist yet, and the caller opens it with `O_NOFOLLOW`.
    public func isAllowed(_ path: String) -> Bool {
        let leaf = (path as NSString).lastPathComponent
        guard !leaf.isEmpty, leaf != ".", leaf != "..", !leaf.contains("/") else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        guard let realParent = DropArea.realpath(parent) else { return false }
        return roots.contains { root in
            // The root must itself be real: a `~/umbar-qa/evidence` symlink
            // to `~/Documents` would otherwise move every write there.
            guard DropArea.realpath(root) == root else { return false }
            return realParent == root || realParent.hasPrefix(root + "/")
        }
    }
}
