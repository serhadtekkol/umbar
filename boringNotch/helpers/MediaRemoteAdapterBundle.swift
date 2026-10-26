//
//  MediaRemoteAdapterBundle.swift
//  boringNotch
//

import Foundation
import Security

/// Locates the MediaRemote adapter resources inside the app bundle.
///
/// The adapter is a framework that `/usr/bin/perl` loads with DynaLoader; it is
/// embedded in `Contents/Frameworks` but deliberately **not linked** into the
/// app, so it never loads into the app process. It backs the default
/// `.nowPlaying` source; see `NowPlayingAdapterProcess` for its lifetime.
enum MediaRemoteAdapterBundle {
    /// Perl driver script, shipped as an app resource.
    static var scriptURL: URL? {
        Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl")
    }

    /// Path of the embedded adapter framework, whether or not it exists.
    static var frameworkPath: String? {
        Bundle.main.privateFrameworksPath?.appending("/MediaRemoteAdapter.framework")
    }

    /// `true` when both the script and the framework are present in this build.
    /// Existence only; `verifyIntegrity()` is the check that may run them.
    static var isAvailable: Bool {
        guard let scriptURL, let frameworkPath else { return false }
        return FileManager.default.fileExists(atPath: scriptURL.path)
            && FileManager.default.fileExists(atPath: frameworkPath)
    }

    /// Verifies that the app bundle on disk, including the adapter script and
    /// framework, is still exactly what was signed (card #68). Call right
    /// before every spawn.
    ///
    /// Why the app has to do this itself: the child is `/usr/bin/perl`
    /// (CodeDirectory flags 0x0: no hardened runtime, no library
    /// validation), so it runs whatever `.pl` and framework sit at those
    /// paths, signed or not, and the kernel never looks at our signature on
    /// those files. The script is a sealed resource and the framework is
    /// nested code, so a strict static validation of the whole bundle covers
    /// both.
    ///
    /// Residual risk, accepted: a file swapped between this check and perl's
    /// `open` (TOCTOU) is not caught. Cost is one hash pass over the bundle,
    /// measured at ~46 ms for the 26 MB Debug bundle on macOS 27.0.1; it runs
    /// on the main thread, but only at launch and on backoff restarts.
    ///
    /// Consequence for development: an unsigned build (e.g.
    /// `CODE_SIGNING_ALLOWED=NO`) always uses the AppleScript fallback.
    ///
    /// - Throws: `NowPlayingAdapterError.integrityCheckFailed` with the
    ///   Security framework's reason when the signature is missing, broken,
    ///   or does not satisfy the running app's own designated requirement.
    static func verifyIntegrity() throws {
        let requirement = try AdapterBundleSignature.ownDesignatedRequirement()
        try AdapterBundleSignature.verify(bundleURL: Bundle.main.bundleURL, requirement: requirement)
    }
}

/// Code-signature checks behind `MediaRemoteAdapterBundle.verifyIntegrity()`,
/// split out so a harness can point them at a copied (tampered) bundle.
enum AdapterBundleSignature {
    /// Strict validation of the bundle and everything nested in it.
    /// `kSecCSStrictValidate` also rejects unsealed files added next to
    /// sealed ones and other structural tricks `codesign --strict` rejects.
    static let validityFlags = SecCSFlags(
        rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode
    )

    /// The designated requirement of the *running* app. Checking the bundle
    /// against it, rather than against "any valid signature", means a bundle
    /// re-signed by someone else (ad-hoc or another team) fails too. For a
    /// Developer ID build this is identifier + team; for an ad-hoc Debug
    /// build it is the main executable's cdhash.
    static func ownDesignatedRequirement() throws -> SecRequirement {
        var selfCode: SecCode?
        var status = SecCodeCopySelf(SecCSFlags(), &selfCode)
        guard status == errSecSuccess, let selfCode else {
            throw NowPlayingAdapterError.integrityCheckFailed("SecCodeCopySelf: \(describe(status))")
        }
        var selfStaticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(selfCode, SecCSFlags(), &selfStaticCode)
        guard status == errSecSuccess, let selfStaticCode else {
            throw NowPlayingAdapterError.integrityCheckFailed("SecCodeCopyStaticCode: \(describe(status))")
        }
        var requirement: SecRequirement?
        status = SecCodeCopyDesignatedRequirement(selfStaticCode, SecCSFlags(), &requirement)
        guard status == errSecSuccess, let requirement else {
            throw NowPlayingAdapterError.integrityCheckFailed("designated requirement: \(describe(status))")
        }
        return requirement
    }

    /// Validates the bundle at `bundleURL` statically against `requirement`.
    ///
    /// - Throws: `NowPlayingAdapterError.integrityCheckFailed` naming the
    ///   first failure Security reports (e.g. "a sealed resource is missing
    ///   or invalid" for an edited `.pl`).
    static func verify(bundleURL: URL, requirement: SecRequirement?) throws {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw NowPlayingAdapterError.integrityCheckFailed("SecStaticCodeCreateWithPath: \(describe(status))")
        }
        // The OSStatus message ("a sealed resource is missing or invalid")
        // is more useful in the log than CFError's generic description.
        let validity = SecStaticCodeCheckValidity(staticCode, validityFlags, requirement)
        guard validity == errSecSuccess else {
            throw NowPlayingAdapterError.integrityCheckFailed(describe(validity))
        }
    }

    private static func describe(_ status: OSStatus) -> String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown"
        return "\(message) (\(status))"
    }
}
