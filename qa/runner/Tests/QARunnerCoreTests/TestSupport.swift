import Foundation
@testable import QARunnerCore
import XCTest

/// Parses a JSON line the way the socket does.
func parse(_ json: String) -> Result<Command, Refusal> {
    Command.parse(line: Array(json.utf8))
}

/// Asserts that a line is refused, optionally with a specific code.
func assertRefused(_ json: String, _ code: Refusal.Code? = nil, file: StaticString = #filePath, line: UInt = #line) {
    switch parse(json) {
    case .success(let command):
        XCTFail("accepted \(json) as \(command)", file: file, line: line)
    case .failure(let refusal):
        if let code { XCTAssertEqual(refusal.code, code, "for \(json): \(refusal)", file: file, line: line) }
    }
}

func assertAccepted(_ json: String, _ expected: Command, file: StaticString = #filePath, line: UInt = #line) {
    switch parse(json) {
    case .success(let command): XCTAssertEqual(command, expected, file: file, line: line)
    case .failure(let refusal): XCTFail("refused \(json): \(refusal)", file: file, line: line)
    }
}

let goodSession = SessionSnapshot(onConsole: true, screenLocked: false, secureInput: false)
let physicalClick = ClickEvidence(kind: .leftMouseUp, sourceUnixPID: 0, age: 0.05)
let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// A throwaway directory tree with symlinks resolved, removed in tearDown.
final class TempHome {
    let path: String

    init() throws {
        let base = NSTemporaryDirectory() + "qarunner-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        path = DropArea.realpath(base)!
    }

    func mkdir(_ rel: String, mode: Int = 0o755) throws {
        let p = (path as NSString).appendingPathComponent(rel)
        try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        chmod(p, mode_t(mode))
    }

    func touch(_ rel: String) {
        FileManager.default.createFile(atPath: (path as NSString).appendingPathComponent(rel), contents: Data("x".utf8))
    }

    func symlink(_ rel: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: (path as NSString).appendingPathComponent(rel),
                                                   withDestinationPath: target)
    }

    func abs(_ rel: String) -> String { (path as NSString).appendingPathComponent(rel) }

    func remove() { try? FileManager.default.removeItem(atPath: path) }
}
