//
//  AdapterChildEnvironment.swift
//  boringNotch
//
//  Kept apart from NowPlayingAdapterProcess so the unit test bundle can
//  compile it without the process and AppKit plumbing (card #56).
//

import Foundation

/// The complete environment of the `/usr/bin/perl` adapter child (card #67).
///
/// The child is built from an explicit allowlist instead of inheriting the
/// app's environment. `/usr/bin/perl` has neither hardened runtime nor library
/// validation, and it honours `PERL5OPT` / `PERL5LIB` (load arbitrary
/// modules), `VERSIONER_PERL_*` (pick another interpreter) and `DYLD_*`; the
/// adapter itself reads `MEDIAREMOTEADAPTER_OPTION_*` and `ADAPTER_TEST_MODE`.
/// Any of those set by a same-user process (`launchctl setenv` before umbar
/// launches at login) would otherwise run code in a child that macOS
/// attributes to umbar. Nothing outside the allowlist below reaches the child,
/// so new variables perl or the adapter start honouring later are excluded
/// without anyone having to remember to add them to a denylist.
///
/// The child is additionally started with `perl -T`: taint mode makes perl
/// ignore `PERL5LIB` and `PERL5OPT` even if they were somehow present.
enum AdapterChildEnvironment {
    /// Name of the environment variable the adapter's watchdog reads
    /// (mediaremote-adapter/Sources/umbar/UmbarParentWatchdog.m).
    static let parentPIDKey = "UMBAR_ADAPTER_PARENT_PID"

    /// Fixed search path: the adapter execs nothing, but perl modules that
    /// shell out must never find a binary from a user-writable directory.
    static let path = "/usr/bin:/bin"

    /// Used when the inherited `LANG` is missing or not a plain locale name.
    static let fallbackLanguage = "en_US.UTF-8"

    /// Builds the child's environment. Pure: everything comes in as arguments.
    ///
    /// - Parameters:
    ///   - parentPID: The app's pid, for the adapter's exit-with-parent watchdog.
    ///   - homeDirectory: The user's home (`NSHomeDirectory()`).
    ///   - temporaryDirectory: The per-user temp dir (`NSTemporaryDirectory()`);
    ///     a trailing slash is kept as Foundation returns it.
    ///   - inheritedLanguage: The app's `LANG`, if any. Only passed on when it
    ///     looks like a locale name (`[A-Za-z0-9_.@-]`, at most 64 characters);
    ///     otherwise `fallbackLanguage` is used. Perl only uses it for locale
    ///     warnings, but nothing free-form from the parent reaches the child.
    /// - Returns: Exactly `UMBAR_ADAPTER_PARENT_PID`, `PATH`, `HOME`, `TMPDIR`
    ///   and `LANG`.
    static func make(
        parentPID: Int32,
        homeDirectory: String,
        temporaryDirectory: String,
        inheritedLanguage: String?
    ) -> [String: String] {
        [
            parentPIDKey: String(parentPID),
            "PATH": path,
            "HOME": homeDirectory,
            "TMPDIR": temporaryDirectory,
            "LANG": sanitizedLanguage(inheritedLanguage),
        ]
    }

    /// The environment for the current process.
    static func current() -> [String: String] {
        make(
            parentPID: getpid(),
            homeDirectory: NSHomeDirectory(),
            temporaryDirectory: NSTemporaryDirectory(),
            inheritedLanguage: ProcessInfo.processInfo.environment["LANG"]
        )
    }

    static func sanitizedLanguage(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.count <= 64,
              value.unicodeScalars.allSatisfy({ allowedLanguageScalars.contains($0) })
        else { return fallbackLanguage }
        return value
    }

    private static let allowedLanguageScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.@-"
    )
}
