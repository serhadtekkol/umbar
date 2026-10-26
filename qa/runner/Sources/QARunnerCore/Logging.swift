import CoreGraphics
import Foundation

/// One AX element as returned by `ax.tree`. It travels over the socket only.
/// `value` exists here and nowhere in `LogRecord`: there is no conversion
/// from a node (or a tree) to log text other than `AXTreeSummary`, which
/// keeps counts only (§3.8, NFR-PRV-4).
public struct AXNode: Equatable, Sendable {
    public var role: String?
    public var subrole: String?
    public var identifier: String?
    public var title: String?
    public var value: String?
    public var frame: CGRect?
    public var enabled: Bool?
    public var children: [AXNode]

    public init(role: String?, subrole: String?, identifier: String?, title: String?, value: String?,
                frame: CGRect?, enabled: Bool?, children: [AXNode] = []) {
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
        self.title = title
        // Defense in depth: even if a caller read a secure field's value,
        // it does not survive into the node.
        self.value = AXValuePolicy.shouldReadValue(role: role, subrole: subrole) ? value.map(AXValuePolicy.truncate) : nil
        self.frame = frame
        self.enabled = enabled
        self.children = children
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = [:]
        if let role { o["role"] = .string(role) }
        if let subrole { o["subrole"] = .string(subrole) }
        if let identifier { o["identifier"] = .string(identifier) }
        if let title { o["title"] = .string(title) }
        if let value { o["value"] = .string(value) }
        if let frame {
            o["frame"] = .object(["x": .double(frame.origin.x), "y": .double(frame.origin.y),
                                  "w": .double(frame.width), "h": .double(frame.height)])
        }
        if let enabled { o["enabled"] = .bool(enabled) }
        if !children.isEmpty { o["children"] = .array(children.map(\.json)) }
        return .object(o)
    }

    public var nodeCount: Int { 1 + children.reduce(0) { $0 + $1.nodeCount } }
}

/// The only facts about a command's outcome that may be logged. A closed
/// struct rather than a dictionary, so adding "just log the value" means
/// changing this type, which is visible in review.
public struct LogDetail: Equatable, Sendable {
    public var files: [String]?
    public var nodeCount: Int?
    public var umbarPID: Int32?
    public var measurements: Int?

    public init(files: [String]? = nil, nodeCount: Int? = nil, umbarPID: Int32? = nil, measurements: Int? = nil) {
        self.files = files
        self.nodeCount = nodeCount
        self.umbarPID = umbarPID
        self.measurements = measurements
    }
}

/// One line of `~/Library/Logs/UmbarQARunner/runner.jsonl` (§3.8).
public struct LogRecord: Equatable, Sendable {
    public enum Event: String, Sendable {
        case launch, launchRefused = "launch-refused", arm, armRefused = "arm-refused", disarm
        case accepted = "command", refused, peerRefused = "peer-refused", exit
    }

    public var time: Date
    public var event: Event
    public var command: String?
    public var parameters: [String: String]
    public var callerPID: Int32?
    public var callerPath: String?
    public var refusal: String?
    public var armed: Bool
    public var detail: LogDetail
    /// Launch/arm facts: cdhash, uid, expiry, arm minutes, disarm reason.
    public var facts: [String: String]

    public init(time: Date, event: Event, command: String? = nil, parameters: [String: String] = [:],
                callerPID: Int32? = nil, callerPath: String? = nil, refusal: Refusal? = nil,
                armed: Bool, detail: LogDetail = LogDetail(), facts: [String: String] = [:]) {
        self.time = time
        self.event = event
        self.command = command
        self.parameters = parameters
        self.callerPID = callerPID
        self.callerPath = callerPath
        self.refusal = refusal?.description
        self.armed = armed
        self.detail = detail
        self.facts = facts
    }

    /// A single JSON line, keys sorted, newline-terminated.
    public func jsonLine() -> Data {
        var o: [String: JSONValue] = [
            "ts": .string(Self.timestamp(time)),
            "event": .string(event.rawValue),
            "armed": .bool(armed),
        ]
        if let command { o["cmd"] = .string(command) }
        if !parameters.isEmpty { o["params"] = .object(parameters.mapValues { .string($0) }) }
        if let callerPID { o["caller_pid"] = .int(Int(callerPID)) }
        if let callerPath { o["caller_path"] = .string(callerPath) }
        if let refusal { o["refused"] = .string(refusal) }
        if let files = detail.files { o["files"] = .array(files.map { .string($0) }) }
        if let n = detail.nodeCount { o["ax_nodes"] = .int(n) }
        if let pid = detail.umbarPID { o["umbar_pid"] = .int(Int(pid)) }
        if let m = detail.measurements { o["measurements"] = .int(m) }
        if !facts.isEmpty { o["facts"] = .object(facts.mapValues { .string($0) }) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(JSONValue.object(o))) ?? Data(#"{"event":"log-encode-failed"}"#.utf8)
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// A short, single-line form for os_log.
    public var summary: String {
        var parts = [event.rawValue]
        if let command { parts.append(command) }
        for k in parameters.keys.sorted() { parts.append("\(k)=\(parameters[k]!)") }
        if let refusal { parts.append("refused=\(refusal)") }
        if let callerPID { parts.append("caller_pid=\(callerPID)") }
        if let callerPath { parts.append("caller_path=\(callerPath)") }
        for k in facts.keys.sorted() { parts.append("\(k)=\(facts[k]!)") }
        parts.append("armed=\(armed)")
        return parts.joined(separator: " ")
    }

    static func timestamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}
