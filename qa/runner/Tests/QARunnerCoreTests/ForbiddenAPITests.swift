import Foundation
import XCTest

/// Rejection tests for the "the code does not have this capability" rules
/// (§3.2 rules 1-3, §3.5 "Hiçbir zaman", §1 break point 2). They scan the
/// package's own sources, with comments stripped, for the APIs that would
/// create the capability. build.sh adds the binary-level `nm -u` check.
///
/// A hit here is not something to allowlist in this file: it means the
/// change needs Muhittin's review (§3.5, last paragraph).
final class ForbiddenAPITests: XCTestCase {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct SourceFile {
        let path: String
        let code: String
    }

    private static func sources(in targets: [String]) throws -> [SourceFile] {
        var out: [SourceFile] = []
        for target in targets {
            let dir = packageRoot.appendingPathComponent("Sources/\(target)")
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
            XCTAssertFalse(files.isEmpty, "no sources found in \(dir.path)")
            for f in files {
                let text = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)
                out.append(SourceFile(path: "\(target)/\(f)", code: stripComments(text)))
            }
        }
        return out
    }

    /// Removes `//` and `/* */` comments so documentation that *names* a
    /// forbidden API (to say it is not used) does not trip the scan.
    /// String literals are kept: a forbidden name in a string is suspicious.
    static func stripComments(_ s: String) -> String {
        var out = ""
        var i = s.startIndex
        var inString = false
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i) < s.endIndex ? s[s.index(after: i)] : nil
            if inString {
                out.append(c)
                if c == "\\", let n = next { out.append(n); i = s.index(i, offsetBy: 2); continue }
                if c == "\"" { inString = false }
                i = s.index(after: i)
                continue
            }
            if c == "\"" { inString = true; out.append(c); i = s.index(after: i); continue }
            if c == "/", next == "/" {
                while i < s.endIndex, s[i] != "\n" { i = s.index(after: i) }
                continue
            }
            if c == "/", next == "*" {
                i = s.index(i, offsetBy: 2)
                while i < s.endIndex {
                    if s[i] == "*", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "/" { i = s.index(i, offsetBy: 2); break }
                    i = s.index(after: i)
                }
                continue
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    private func assertAbsent(_ patterns: [String: String], in targets: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        let files = try Self.sources(in: targets)
        for (rule, pattern) in patterns.sorted(by: { $0.key < $1.key }) {
            let re = try NSRegularExpression(pattern: pattern)
            for f in files {
                let range = NSRange(f.code.startIndex..., in: f.code)
                if let m = re.firstMatch(in: f.code, range: range), let r = Range(m.range, in: f.code) {
                    XCTFail("\(rule): `\(f.code[r])` in \(f.path)", file: file, line: line)
                }
            }
        }
    }

    private let allTargets = ["UmbarQARunner", "QARunnerCore", "QARunnerStamp", "qa-cli"]

    func testStripCommentsKeepsCodeAndStrings() {
        let s = "let a = 1 // Process()\n/* NSTask */ let b = \"// not a comment\""
        let stripped = Self.stripComments(s)
        XCTAssertFalse(stripped.contains("Process()"))
        XCTAssertFalse(stripped.contains("NSTask"))
        XCTAssertTrue(stripped.contains("\"// not a comment\""))
    }

    /// §3.2 rule 1 and §1 break point 2: no child processes of any kind.
    func testNever_subprocesses() throws {
        try assertAbsent([
            "Process": #"\bProcess\s*\("#,
            "NSTask": #"\bNSTask\b"#,
            "posix_spawn": #"posix_spawn"#,
            "fork": #"\b(v?fork)\s*\("#,
            "system": #"\bsystem\s*\("#,
            "popen": #"\bpopen\b"#,
            "exec": #"\bexec(v|l|ve|vp|le|lp)\w*\s*\("#,
            "launchApplication": #"launchApplication"#,
            "openApplication": #"openApplication\s*\("#,
            "AppleScript": #"NSAppleScript|OSAScript|NSUserAppleScriptTask|NSUserUnixTask"#,
            "SMAppService/launchctl": #"SMAppService|SMJobSubmit|launchctl"#,
            "screencapture CLI": #"\"/usr/sbin/screencapture|\bscreencapture\b\s*\""#,
        ], in: allTargets)
    }

    /// §3.2 rule 2: no plug-ins, interpreters or dynamically loaded code.
    func testNever_dynamicCodeOrInterpreters() throws {
        try assertAbsent([
            "dlopen": #"\bdlopen\b|\bdlsym\b"#,
            "Bundle loading": #"\bBundle\s*\(\s*(path|url)\s*:|\.load\(\)|CFBundleLoadExecutable|NSBundle"#,
            "JavaScriptCore": #"JavaScriptCore|JSContext"#,
            "NSExpression/selectors from strings": #"NSSelectorFromString|NSClassFromString"#,
        ], in: allTargets)
    }

    /// §3.2 rule 3: no TCP/UDP, no outgoing connections. The Unix socket is
    /// the only channel, and `connect` appears only in qa-cli.
    func testNever_network() throws {
        try assertAbsent([
            "URLSession": #"URLSession|NSURLConnection|URLRequest"#,
            "Network.framework": #"import\s+Network\b|NWListener|NWConnection|NWEndpoint"#,
            "inet sockets": #"AF_INET6?\b|PF_INET6?\b|SOCK_DGRAM|sockaddr_in\b"#,
            "CFSocket/streams": #"CFSocket|CFStreamCreatePairWithSocketToHost|NSNetService|Bonjour"#,
        ], in: allTargets)
        try assertAbsent(["connect in runner": #"\bconnect\s*\("#], in: ["UmbarQARunner", "QARunnerCore"])
    }

    /// §3.5: no free text and no modifier combinations.
    func testNever_textOrModifierEvents() throws {
        try assertAbsent([
            "unicode string events": #"keyboardSetUnicodeString|CGEventKeyboardSetUnicodeString"#,
            "CGEventFlags modifiers": #"mask(Command|Control|Alternate|Shift|AlphaShift|SecondaryFn|NumericPad)"#,
            "NSEvent modifier flags": #"(?<![A-Za-z0-9_)\]])\.(command|control|option|shift|capsLock|function)\b"#,
            "raw key code input": #"virtualKey:(?!\s*key\.virtualKeyCode)"#,
            "IOHID posting": #"IOHIDPostEvent|IOHIDEventSystemClient"#,
        ], in: allTargets)
    }

    /// §3.5: never read or write the pasteboard.
    func testNever_pasteboard() throws {
        try assertAbsent(["pasteboard": #"NSPasteboard|UIPasteboard|PasteboardRef|PasteboardCreate"#], in: allTargets)
    }

    /// §3.5: never full-screen capture with the legacy APIs, which ignore
    /// every SCContentFilter rule.
    func testNever_legacyFullScreenCapture() throws {
        try assertAbsent([
            "CGWindowListCreateImage": #"CGWindowListCreateImage|CGDisplayCreateImage|CGDisplayStream"#,
            "window titles": #"kCGWindowName"#,
        ], in: allTargets)
    }

    /// §3.5: never change system settings or touch TCC; never drive other
    /// apps through AX actions (which would bypass the hit test).
    func testNever_settingsTCCOrAXActions() throws {
        try assertAbsent([
            "preferences writes": #"CFPreferencesSet|CFPreferencesSynchronize|UserDefaults|NSUserDefaults"#,
            "TCC": #"tccutil|TCC\.db|kTCCService"#,
            "AX writes/actions": #"AXUIElementSetAttributeValue|AXUIElementPerformAction"#,
            "event taps": #"CGEvent\.tapCreate|CGEventTapCreate|addGlobalMonitorForEvents"#,
            "Automation": #"NSAppleEventDescriptor|AESend"#,
        ], in: allTargets)
    }

    /// §3.3: no run-time switch can widen the allowlist. The runner reads no
    /// environment, arguments or defaults.
    func testNever_runtimeConfiguration() throws {
        try assertAbsent([
            "environment": #"ProcessInfo\.processInfo\.environment|getenv\s*\("#,
            "arguments": #"CommandLine\.arguments|ProcessInfo\.processInfo\.arguments"#,
        ], in: ["UmbarQARunner", "QARunnerCore", "QARunnerStamp"])
    }

    /// Structural rule: synthetic events are created and posted only in
    /// Input.swift, where every pointer event requires a `VerifiedPoint`.
    func testEventPostingIsConfinedToInputSwift() throws {
        let re = try NSRegularExpression(pattern: #"\.post\(tap:|CGEvent\(|CGEventPost|postToPid|NSEvent\.otherEvent"#)
        for f in try Self.sources(in: allTargets) where f.path != "UmbarQARunner/Input.swift" {
            let range = NSRange(f.code.startIndex..., in: f.code)
            XCTAssertNil(re.firstMatch(in: f.code, range: range), "event creation/posting outside Input.swift: \(f.path)")
        }
    }

    /// Structural rule: `VerifiedPoint` cannot be constructed outside
    /// Input.swift (its initializer is fileprivate).
    func testVerifiedPointInitIsFilePrivate() throws {
        let input = try Self.sources(in: ["UmbarQARunner"]).first { $0.path == "UmbarQARunner/Input.swift" }!
        XCTAssertTrue(input.code.contains("fileprivate init(_ point: CGPoint)"))
        for f in try Self.sources(in: allTargets) where f.path != "UmbarQARunner/Input.swift" {
            XCTAssertFalse(f.code.contains("VerifiedPoint("), f.path)
        }
    }

    /// The protocol has no arm command, and the menu is the only caller of
    /// `ArmController.arm` in the app.
    func testArmIsCalledOnlyFromTheMenuAction() throws {
        let callers = try Self.sources(in: ["UmbarQARunner"]).filter { $0.code.contains("arm.arm(") }
        XCTAssertEqual(callers.map(\.path), ["UmbarQARunner/AppController.swift"])
        let app = callers[0].code
        let armCall = app.range(of: "arm.arm(")!
        let action = app.range(of: "@objc private func armClicked")!
        XCTAssertLessThan(action.lowerBound, armCall.lowerBound)
        XCTAssertEqual(app.components(separatedBy: "arm.arm(").count - 1, 1, "exactly one call site")
    }

    /// Hardened Runtime with empty entitlements (§3.1): the repo ships no
    /// entitlements file for the runner, and build.sh passes none.
    func testNoEntitlementsFileAndBuildScriptPassesNone() throws {
        let files = try FileManager.default.subpathsOfDirectory(atPath: Self.packageRoot.path)
            .filter { !$0.hasPrefix(".build") && $0.hasSuffix(".entitlements") }
        XCTAssertEqual(files, [])
        let script = try String(contentsOf: Self.packageRoot.appendingPathComponent("build.sh"), encoding: .utf8)
        // Join `\`-continued lines, drop comments, keep the signing commands.
        let commands = script.replacingOccurrences(of: "\\\n", with: " ").split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let signing = commands.filter { $0.contains("codesign") && $0.contains("--sign") }
        XCTAssertEqual(signing.count, 2, "qa-cli and the app")
        for line in signing {
            XCTAssertFalse(line.contains("--entitlements"), String(line))
            XCTAssertTrue(line.contains("--options runtime"), String(line))
        }
    }
}
