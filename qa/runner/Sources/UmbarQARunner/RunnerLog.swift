import Foundation
import os
import QARunnerCore

/// Writes every record twice (§3.8): to the unified log, which a process of
/// the same UID cannot delete, and to an append-only JSONL file that Habibe
/// can read over SSH without `log show`.
///
/// Thread-safe: the socket thread logs peer refusals directly.
final class RunnerLog {
    enum Category: String { case cmd, arm, refuse }

    private let loggers: [Category: Logger]
    private let lock = NSLock()
    private var fd: Int32 = -1

    /// - Parameter fileLogging: false for a refused launch. A runner started
    ///   in the wrong account must not create files in that account; the
    ///   unified log alone records the refusal.
    init(realHome: String, fileLogging: Bool) {
        var l: [Category: Logger] = [:]
        for c in [Category.cmd, .arm, .refuse] {
            l[c] = Logger(subsystem: RunnerIdentity.logSubsystem, category: c.rawValue)
        }
        loggers = l
        guard fileLogging else { return }
        let dir = (realHome as NSString).appendingPathComponent("Library/Logs/UmbarQARunner")
        guard SafeFiles.makePrivateDirectory(dir) else { return }
        let path = (dir as NSString).appendingPathComponent("runner.jsonl")
        guard WritePolicy(realHome: realHome).isAllowed(path) else { return }
        // O_APPEND so concurrent writers (there are none, but a second
        // runner instance would be one) never interleave within a line;
        // O_NOFOLLOW so a planted symlink cannot redirect the log.
        fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    }

    deinit {
        if fd >= 0 { close(fd) }
    }

    func write(_ record: LogRecord, category: Category) {
        // The summary holds closed-vocabulary names, bounded numbers, the
        // caller's path and cdhashes; never AX values or capture content.
        let summary = record.summary
        switch category {
        case .refuse: loggers[category]?.error("\(summary, privacy: .public)")
        default: loggers[category]?.notice("\(summary, privacy: .public)")
        }
        let line = record.jsonLine()
        lock.lock()
        defer { lock.unlock() }
        guard fd >= 0 else { return }
        line.withUnsafeBytes { buf in
            _ = Darwin.write(fd, buf.baseAddress, buf.count)
        }
    }
}

/// File-system helpers that every runner write goes through.
enum SafeFiles {
    /// Creates `path` (and missing parents up to an existing ancestor) with
    /// mode 0700, then verifies it is a real directory owned by us and not
    /// accessible to group/other.
    static func makePrivateDirectory(_ path: String) -> Bool {
        var st = stat()
        if lstat(path, &st) != 0 {
            let parent = (path as NSString).deletingLastPathComponent
            if parent != path, lstat(parent, &st) != 0 {
                guard makePrivateDirectory(parent) else { return false }
            }
            guard mkdir(path, 0o700) == 0 || errno == EEXIST else { return false }
        }
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR && st.st_uid == getuid()
    }

    /// Like `makePrivateDirectory` but additionally requires mode 0700
    /// exactly (the socket directory, §3.3).
    static func makeStrictPrivateDirectory(_ path: String) -> Bool {
        guard makePrivateDirectory(path) else { return false }
        _ = chmod(path, 0o700)
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_mode & 0o777) == 0o700
    }

    /// Creates a new file and writes `data`. Never overwrites, never follows
    /// a symlink, and refuses paths outside the write roots.
    static func createNew(_ path: String, data: Data, policy: WritePolicy) -> Refusal? {
        guard policy.isAllowed(path) else { return Refusal(.writeOutsideAllowedRoots) }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return Refusal(.ioError, "create") }
        defer { close(fd) }
        let ok = data.withUnsafeBytes { buf -> Bool in
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        return ok ? nil : Refusal(.ioError, "write")
    }
}
