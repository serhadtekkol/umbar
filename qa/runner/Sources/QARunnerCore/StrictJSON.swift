import Foundation

/// A scalar value accepted on the wire.
public enum WireValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
}

/// Parser for the request line: one flat JSON object of scalars.
///
/// This is intentionally a small hand-written parser rather than
/// `JSONSerialization`, because the schema has to be strict (§3.3) and
/// Foundation is lenient in ways that matter here: it silently keeps the last
/// of two duplicate keys (a classic parser-differential trick), it conflates
/// booleans with numbers, and it accepts floats, nulls, nesting and arbitrary
/// escapes. None of those have a legitimate use in this protocol, so the
/// grammar accepted is exactly:
///
///     line   := ws '{' ws [ pair ( ws ',' ws pair )* ] ws '}' ws
///     pair   := key ws ':' ws value
///     key    := '"' [a-z_]{1,32} '"'
///     value  := string | int | 'true' | 'false'
///     string := '"' (printable ASCII except '"' and '\')* '"'
///     int    := '-'? ( '0' | [1-9][0-9]{0,8} )
///
/// Anything else (escapes, non-ASCII, control characters, floats, null,
/// arrays, nested objects, duplicate keys, more than 16 fields, more than
/// 4096 bytes) is refused.
public enum StrictJSON {
    public static func parseObject(_ line: some Collection<UInt8>) -> Result<[String: WireValue], Refusal> {
        let bytes = Array(line)
        guard bytes.count <= WireLimits.maxLineBytes else { return .failure(Refusal(.lineTooLong)) }
        var parser = Parser(bytes: bytes)
        do {
            return .success(try parser.parse())
        } catch let refusal as Refusal {
            return .failure(refusal)
        } catch {
            return .failure(Refusal(.malformedJSON))
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func parse() throws -> [String: WireValue] {
            skipWhitespace()
            try expect(UInt8(ascii: "{"))
            var result: [String: WireValue] = [:]
            skipWhitespace()
            if peek() == UInt8(ascii: "}") {
                i += 1
            } else {
                while true {
                    skipWhitespace()
                    let key = try parseKey()
                    skipWhitespace()
                    try expect(UInt8(ascii: ":"))
                    skipWhitespace()
                    let value = try parseValue()
                    guard result[key] == nil else { throw Refusal(.duplicateField, key) }
                    result[key] = value
                    guard result.count <= WireLimits.maxFields else { throw Refusal(.tooManyFields) }
                    skipWhitespace()
                    guard let c = next() else { throw Refusal(.malformedJSON) }
                    if c == UInt8(ascii: "}") { break }
                    guard c == UInt8(ascii: ",") else { throw Refusal(.malformedJSON) }
                }
            }
            skipWhitespace()
            guard i == bytes.count else { throw Refusal(.malformedJSON) }
            return result
        }

        mutating func parseKey() throws -> String {
            let s = try parseString()
            let ok = (1...32).contains(s.utf8.count)
                && s.utf8.allSatisfy { ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || $0 == UInt8(ascii: "_") }
            guard ok else { throw Refusal(.malformedJSON, "key") }
            return s
        }

        mutating func parseValue() throws -> WireValue {
            guard let c = peek() else { throw Refusal(.malformedJSON) }
            switch c {
            case UInt8(ascii: "\""):
                return .string(try parseString())
            case UInt8(ascii: "t"):
                try expectLiteral("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expectLiteral("false")
                return .bool(false)
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return .int(try parseInt())
            default:
                // null, arrays, objects: valid JSON, but not in this protocol.
                throw Refusal(.unsupportedValue)
            }
        }

        mutating func parseString() throws -> String {
            try expect(UInt8(ascii: "\""))
            let start = i
            while let c = peek(), c != UInt8(ascii: "\"") {
                // Printable ASCII only. A backslash would start an escape,
                // and escapes are how "\u0000" or "..\/" sneak past a naive
                // check; there is no name in this protocol that needs one.
                guard c >= 0x20, c <= 0x7E, c != UInt8(ascii: "\\") else {
                    throw Refusal(.unsupportedValue, "string-char")
                }
                i += 1
            }
            let end = i
            try expect(UInt8(ascii: "\""))
            return String(decoding: bytes[start..<end], as: UTF8.self)
        }

        mutating func parseInt() throws -> Int {
            let start = i
            if peek() == UInt8(ascii: "-") { i += 1 }
            let digitsStart = i
            while let c = peek(), c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") { i += 1 }
            let digits = i - digitsStart
            guard digits >= 1, digits <= 9 else { throw Refusal(.unsupportedValue, "int") }
            if digits > 1, bytes[digitsStart] == UInt8(ascii: "0") { throw Refusal(.unsupportedValue, "int") }
            // A following '.', 'e' or 'E' means a float: refuse rather than truncate.
            if let c = peek(), c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") {
                throw Refusal(.unsupportedValue, "float")
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            guard let value = Int(text) else { throw Refusal(.unsupportedValue, "int") }
            return value
        }

        mutating func expectLiteral(_ literal: String) throws {
            for b in literal.utf8 {
                guard next() == b else { throw Refusal(.malformedJSON) }
            }
        }

        mutating func expect(_ b: UInt8) throws {
            guard next() == b else { throw Refusal(.malformedJSON) }
        }

        func peek() -> UInt8? { i < bytes.count ? bytes[i] : nil }

        mutating func next() -> UInt8? {
            guard i < bytes.count else { return nil }
            defer { i += 1 }
            return bytes[i]
        }

        mutating func skipWhitespace() {
            while let c = peek(), c == 0x20 || c == 0x09 || c == 0x0D { i += 1 }
        }
    }

    /// Encodes a flat request the way `qa-cli` sends it. Keys are sorted so
    /// the line is deterministic. Strings are emitted verbatim between quotes,
    /// which is only valid because `parseObject` accepts no escapes: a string
    /// containing `"` or `\` cannot be encoded and is refused here too.
    public static func encodeObject(_ object: [String: WireValue]) -> Result<String, Refusal> {
        var parts: [String] = []
        for key in object.keys.sorted() {
            guard let value = object[key] else { continue }
            let rendered: String
            switch value {
            case .string(let s):
                guard s.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E && $0 != UInt8(ascii: "\"") && $0 != UInt8(ascii: "\\") }) else {
                    return .failure(Refusal(.unsupportedValue, key))
                }
                rendered = "\"\(s)\""
            case .int(let n): rendered = String(n)
            case .bool(let b): rendered = b ? "true" : "false"
            }
            parts.append("\"\(key)\":\(rendered)")
        }
        return .success("{" + parts.joined(separator: ",") + "}")
    }
}
