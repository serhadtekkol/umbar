//
//  AdapterChildEnvironmentTests.swift
//  umbarTests
//
//  Card #67: the perl adapter child gets an allowlisted environment, never
//  the app's. Ported from the media-hardening scratch harness (h67); the
//  part that spawns a real child stays an integration check.
//

import Foundation
import Testing

private let allowlist: Set<String> = ["UMBAR_ADAPTER_PARENT_PID", "PATH", "HOME", "TMPDIR", "LANG"]

/// Prefixes perl, the perl version switcher, dyld or the adapter honour.
/// None of them may ever reach the child.
private let deniedPrefixes = ["PERL", "DYLD", "VERSIONER", "MEDIAREMOTEADAPTER", "ADAPTER_"]

private func deniedKeys(in environment: [String: String]) -> [String] {
    environment.keys.filter { key in deniedPrefixes.contains { key.hasPrefix($0) } }.sorted()
}

@Suite("AdapterChildEnvironment")
struct AdapterChildEnvironmentTests {
    @Test func makeReturnsExactlyTheAllowlistWithTheGivenValues() {
        let env = AdapterChildEnvironment.make(
            parentPID: 42,
            homeDirectory: "/Users/x",
            temporaryDirectory: "/var/t/",
            inheritedLanguage: "tr_TR.UTF-8"
        )
        #expect(Set(env.keys) == allowlist)
        #expect(env["UMBAR_ADAPTER_PARENT_PID"] == "42")
        #expect(env["PATH"] == "/usr/bin:/bin")
        #expect(env["HOME"] == "/Users/x")
        #expect(env["TMPDIR"] == "/var/t/", "trailing slash is kept as Foundation returns it")
        #expect(env["LANG"] == "tr_TR.UTF-8")
        #expect(deniedKeys(in: env).isEmpty)
    }

    /// Guards `current()` against ever being changed to merge the inherited
    /// environment: whatever this test process has set (Xcode adds DYLD_* and
    /// friends to test runs), only the allowlist comes out.
    @Test func currentIsBuiltFromTheAllowlistOnly() {
        let env = AdapterChildEnvironment.current()
        #expect(Set(env.keys) == allowlist)
        #expect(deniedKeys(in: env).isEmpty, "denied keys leaked: \(deniedKeys(in: env))")
        #expect(env["UMBAR_ADAPTER_PARENT_PID"] == String(getpid()))
        #expect(env["PATH"] == AdapterChildEnvironment.path)
    }

    @Test(arguments: [
        "tr_TR.UTF-8",
        "C",
        "sr_RS@latin",
        String(repeating: "a", count: 64),
    ])
    func plainLocaleNamesAreKept(_ value: String) {
        #expect(AdapterChildEnvironment.sanitizedLanguage(value) == value)
    }

    @Test(arguments: [
        nil,
        "",
        "en_US.UTF-8 -MFoo",                  // space: would split into a perl switch
        "en_US.UTF-8\n",                       // control character
        "$(id)",                               // shell metacharacters
        "tr_TR.UTF-8;PERL5OPT=-d",             // smuggled assignment
        "türkçe",                              // non-ASCII
        String(repeating: "a", count: 65),     // one over the length cap
    ] as [String?])
    func anythingElseFallsBack(_ value: String?) {
        #expect(AdapterChildEnvironment.sanitizedLanguage(value) == AdapterChildEnvironment.fallbackLanguage)
    }
}
