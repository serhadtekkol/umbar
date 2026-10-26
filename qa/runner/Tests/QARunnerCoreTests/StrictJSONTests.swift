@testable import QARunnerCore
import XCTest

final class StrictJSONTests: XCTestCase {
    private func obj(_ s: String) -> Result<[String: WireValue], Refusal> {
        StrictJSON.parseObject(Array(s.utf8))
    }

    private func assertFails(_ s: String, _ code: Refusal.Code, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let r) = obj(s) else { return XCTFail("parsed \(s)", file: file, line: line) }
        XCTAssertEqual(r.code, code, "\(s): \(r)", file: file, line: line)
    }

    func testParsesFlatScalarObject() throws {
        let o = try obj(#"  {"cmd":"x", "n": -12 ,"b":true,"c":false}  "#).get()
        XCTAssertEqual(o, ["cmd": .string("x"), "n": .int(-12), "b": .bool(true), "c": .bool(false)])
    }

    func testEmptyObjectParses() throws {
        XCTAssertEqual(try obj("{}").get(), [:])
    }

    func testRejectsDuplicateKeys() {
        // Foundation would keep the last value; a strict schema must not
        // let two readers disagree on which one counts.
        assertFails(#"{"cmd":"status","cmd":"key"}"#, .duplicateField)
    }

    func testRejectsNestingNullAndArrays() {
        assertFails(#"{"cmd":{"a":1}}"#, .unsupportedValue)
        assertFails(#"{"cmd":["a"]}"#, .unsupportedValue)
        assertFails(#"{"cmd":null}"#, .unsupportedValue)
    }

    func testRejectsFloatsExponentsAndLeadingZeros() {
        assertFails(#"{"n":1.5}"#, .unsupportedValue)
        assertFails(#"{"n":1e3}"#, .unsupportedValue)
        assertFails(#"{"n":01}"#, .unsupportedValue)
        assertFails(#"{"n":1234567890}"#, .unsupportedValue)
        assertFails(#"{"n":-}"#, .unsupportedValue)
    }

    func testRejectsEscapesControlAndNonASCII() {
        assertFails(#"{"cmd":"a\"b"}"#, .unsupportedValue)
        assertFails(#"{"cmd":"\u0041"}"#, .unsupportedValue)
        assertFails("{\"cmd\":\"a\u{01}b\"}", .unsupportedValue)
        assertFails("{\"cmd\":\"ı\"}", .unsupportedValue)
        assertFails("{\"cmd\":\"a\tb\"}", .unsupportedValue)
    }

    func testRejectsBadKeys() {
        assertFails(#"{"Cmd":"x"}"#, .malformedJSON)
        assertFails(#"{"":"x"}"#, .malformedJSON)
        assertFails(#"{"a-b":"x"}"#, .malformedJSON)
        assertFails(#"{"\#(String(repeating: "a", count: 33))":"x"}"#, .malformedJSON)
    }

    func testRejectsTrailingGarbageAndMissingBraces() {
        assertFails(#"{"cmd":"x"} {"#, .malformedJSON)
        assertFails(#"{"cmd":"x""#, .malformedJSON)
        assertFails(#"{"cmd":"x",}"#, .malformedJSON)
        assertFails(#""cmd""#, .malformedJSON)
        assertFails("", .malformedJSON)
        assertFails(#"{"cmd":tru}"#, .malformedJSON)
    }

    func testRejectsMoreThanSixteenFields() {
        let fields = (0..<17).map { "\"f\(String(UnicodeScalar(97 + $0)!))\":1" }.joined(separator: ",")
        assertFails("{\(fields)}", .tooManyFields)
    }

    func testLineLimitIsExactly4096Bytes() {
        let pad = String(repeating: "a", count: 4096 - #"{"cmd":""}"#.utf8.count)
        let exact = #"{"cmd":"\#(pad)"}"#
        XCTAssertEqual(exact.utf8.count, 4096)
        XCTAssertNoThrow(try obj(exact).get())
        assertFails(#"{"cmd":"\#(pad)a"}"#, .lineTooLong)
    }

    func testEncodeRoundTripsAndRefusesUnencodableStrings() throws {
        let o: [String: WireValue] = ["cmd": .string("key"), "name": .string("esc"), "n": .int(3), "b": .bool(false)]
        let line = try StrictJSON.encodeObject(o).get()
        XCTAssertEqual(line, #"{"b":false,"cmd":"key","n":3,"name":"esc"}"#)
        XCTAssertEqual(try obj(line).get(), o)
        XCTAssertThrowsError(try StrictJSON.encodeObject(["cmd": .string("a\"b")]).get())
        XCTAssertThrowsError(try StrictJSON.encodeObject(["cmd": .string("a\\b")]).get())
    }
}

final class LineFramerTests: XCTestCase {
    func testSplitsLinesAcrossChunks() {
        var f = LineFramer()
        XCTAssertEqual(f.append(Array("{\"a\"".utf8)), [])
        XCTAssertEqual(f.append(Array(":1}\n{}\n".utf8)), [.line(Array("{\"a\":1}".utf8)), .line(Array("{}".utf8))])
    }

    func testOverflowStopsBufferingAndReportsOnce() {
        var f = LineFramer()
        let events = f.append([UInt8](repeating: 0x61, count: 5000))
        XCTAssertEqual(events, [.overflow])
        XCTAssertEqual(f.append(Array("\n{}\n".utf8)), [], "nothing after an overflow")
    }

    func testExactlyMaxBytesIsALine() {
        var f = LineFramer()
        let bytes = [UInt8](repeating: 0x61, count: WireLimits.maxLineBytes)
        XCTAssertEqual(f.append(bytes + [0x0A]), [.line(bytes)])
    }
}

final class ResponseTests: XCTestCase {
    func testRefusalWireShape() {
        let line = String(decoding: Response.refusal(Refusal(.unknownField, "mods")).line(), as: UTF8.self)
        XCTAssertEqual(line, "{\"ok\":false,\"refused\":\"unknown-field:mods\"}\n")
    }

    func testSuccessWireShape() {
        let line = String(decoding: Response.success(["file": .string("/a/b.png")]).line(), as: UTF8.self)
        XCTAssertEqual(line, "{\"ok\":true,\"result\":{\"file\":\"/a/b.png\"}}\n")
    }

    func testRefusalDetailIsSanitized() {
        let r = Refusal(.unknownCommand, "evil\n{\"forged\":true}" + String(repeating: "x", count: 100))
        XCTAssertFalse(r.description.contains("\n"))
        XCTAssertFalse(r.description.contains("\""))
        XCTAssertLessThanOrEqual(r.detail!.count, 64)
    }

    func testRefusalCodesAreUnique() {
        let raw = Refusal.Code.allCases.map(\.rawValue)
        XCTAssertEqual(Set(raw).count, raw.count)
    }
}
