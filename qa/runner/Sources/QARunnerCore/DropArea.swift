import Foundation

/// The only part of the file system Finder may be pointed at:
/// `~/umbar-qa/drop/` (§3.5 `finder.open-drop`, `drag`).
///
/// Every check resolves symlinks with `realpath(3)` *and* refuses symlinks
/// outright with `lstat(2)`. Either alone would do for a path that is not
/// raced; both together keep the rule simple to review: "the folder is a real
/// directory, directly under a real drop root, owned by us".
public struct DropArea: Sendable {
    /// Lexical path of the drop root, built from the real home directory.
    public let root: String
    public let uid: UInt32

    /// - Parameter realHome: the account's home with symlinks already
    ///   resolved (`realpath(NSHomeDirectory())`).
    public init(realHome: String, uid: UInt32) {
        self.root = (realHome as NSString).appendingPathComponent("umbar-qa/drop")
        self.uid = uid
    }

    /// Validates the root itself: a real directory (not a symlink, so it
    /// cannot point at `~/Documents`), owned by the account and not group- or
    /// world-writable.
    public func validateRoot() -> Refusal? {
        guard let st = Self.lstat(root) else { return Refusal(.dropPathRejected, "root-missing") }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return Refusal(.dropPathRejected, "root-not-dir") }
        guard st.st_uid == uid else { return Refusal(.dropPathRejected, "root-owner") }
        guard (st.st_mode & 0o022) == 0 else { return Refusal(.dropPathRejected, "root-writable") }
        guard Self.realpath(root) == root else { return Refusal(.dropPathRejected, "root-symlink") }
        return nil
    }

    /// Resolves `~/umbar-qa/drop/<folder>` to its real path.
    public func resolveFolder(_ folder: String) -> Result<String, Refusal> {
        guard Names.isValidDropFolder(folder) else { return .failure(Refusal(.invalidName, "folder")) }
        if let refusal = validateRoot() { return .failure(refusal) }
        let path = (root as NSString).appendingPathComponent(folder)
        guard let st = Self.lstat(path) else { return .failure(Refusal(.dropPathRejected, "missing")) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { return .failure(Refusal(.dropPathRejected, "not-dir")) }
        guard let real = Self.realpath(path), contains(real), real == path else {
            return .failure(Refusal(.dropPathRejected, "escape"))
        }
        return .success(real)
    }

    /// Resolves a file inside a resolved drop folder.
    public func resolveFile(_ file: String, inFolder folderRealPath: String) -> Result<String, Refusal> {
        guard Names.isValidDropFile(file) else { return .failure(Refusal(.invalidName, "file")) }
        guard contains(folderRealPath) else { return .failure(Refusal(.dropPathRejected, "folder")) }
        let path = (folderRealPath as NSString).appendingPathComponent(file)
        guard let st = Self.lstat(path) else { return .failure(Refusal(.dropPathRejected, "missing")) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { return .failure(Refusal(.dropPathRejected, "not-file")) }
        guard let real = Self.realpath(path), real == path, contains(real) else {
            return .failure(Refusal(.dropPathRejected, "escape"))
        }
        return .success(real)
    }

    /// True when `path` (resolved) is strictly below the drop root. The root
    /// itself is not "inside": Finder showing `drop/` is not a test window.
    public func contains(_ path: String) -> Bool {
        guard let real = Self.realpath(path) else { return false }
        return real.hasPrefix(root + "/") && real.count > root.count + 1
    }

    /// Whether a Finder window's `AXDocument` (a `file://` URL string) is
    /// exactly the given resolved drop folder.
    public func documentMatches(_ axDocument: String?, folderRealPath: String) -> Bool {
        guard let axDocument, let url = URL(string: axDocument), url.isFileURL else { return false }
        guard let real = Self.realpath(url.path) else { return false }
        return real == folderRealPath && contains(real)
    }

    static func lstat(_ path: String) -> stat? {
        var st = stat()
        return Darwin.lstat(path, &st) == 0 ? st : nil
    }

    public static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
