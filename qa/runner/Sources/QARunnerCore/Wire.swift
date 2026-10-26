import Foundation

/// Accumulates bytes from the socket and yields complete lines.
///
/// A line longer than `WireLimits.maxLineBytes` is a protocol violation; the
/// framer reports it as soon as the limit is crossed, without buffering the
/// rest, so a peer cannot make the runner hold an unbounded buffer.
public struct LineFramer: Sendable {
    public enum Event: Equatable, Sendable {
        case line([UInt8])
        case overflow
    }

    private var buffer: [UInt8] = []
    private var overflowed = false

    public init() {}

    public mutating func append(_ bytes: some Sequence<UInt8>) -> [Event] {
        guard !overflowed else { return [] }
        var events: [Event] = []
        for b in bytes {
            if b == UInt8(ascii: "\n") {
                events.append(.line(buffer))
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(b)
                if buffer.count > WireLimits.maxLineBytes {
                    overflowed = true
                    buffer.removeAll()
                    events.append(.overflow)
                    return events
                }
            }
        }
        return events
    }
}

/// Output-side JSON. Responses are produced by the runner, not parsed from
/// untrusted input, so they use `JSONEncoder` and may nest (the AX tree).
public enum JSONValue: Encodable, Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let n): try c.encode(n)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }
}

/// `{"ok":true,"result":{...}}` or `{"ok":false,"refused":"<code>"}`.
public struct Response: Encodable, Equatable, Sendable {
    public let ok: Bool
    public let refused: String?
    public let result: JSONValue?

    public static func success(_ result: [String: JSONValue] = [:]) -> Response {
        Response(ok: true, refused: nil, result: .object(result))
    }

    public static func refusal(_ r: Refusal) -> Response {
        Response(ok: false, refused: r.description, result: nil)
    }

    /// One line, newline-terminated. Encoding a value tree we built cannot
    /// fail in practice; if it ever did, the peer still gets a valid line.
    public func line() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data(#"{"ok":false,"refused":"io-error:encode"}"#.utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    enum CodingKeys: String, CodingKey { case ok, refused, result }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ok, forKey: .ok)
        try c.encodeIfPresent(refused, forKey: .refused)
        try c.encodeIfPresent(result, forKey: .result)
    }
}
