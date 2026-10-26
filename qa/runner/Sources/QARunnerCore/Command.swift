import Foundation

// MARK: - Closed vocabularies (§3.5)
//
// Every name the runner understands is an enum case. There is no "raw" or
// pass-through variant of any of them: a new key, region or target is a code
// change that goes through Muhittin's review (§3.5, last paragraph).

public enum RegionName: String, Sendable, CaseIterable {
    case notch, shelf, hud
    case finderDrop = "finder-drop"
}

public enum AlertName: String, Sendable, CaseIterable {
    case tcc, gatekeeper, pasteboard
}

public enum RecordTarget: String, Sendable, CaseIterable {
    case app, notch
}

public enum AXTreeTarget: String, Sendable, CaseIterable {
    case umbar
    case finderDrop = "finder-drop"
}

/// Keys the runner may press. Modifiers are not representable: there is no
/// field for them in the schema and no flag in the event the runner posts.
public enum KeyName: String, Sendable, CaseIterable {
    case esc, space, `return`, tab, up, down, left, right

    /// macOS virtual key codes (HIToolbox `kVK_*`).
    public var virtualKeyCode: UInt16 {
        switch self {
        case .esc: return 0x35
        case .space: return 0x31
        case .return: return 0x24
        case .tab: return 0x30
        case .left: return 0x7B
        case .right: return 0x7C
        case .down: return 0x7D
        case .up: return 0x7E
        }
    }
}

public enum MediaKeyName: String, Sendable, CaseIterable {
    case volumeUp = "volume-up"
    case volumeDown = "volume-down"
    case brightnessUp = "brightness-up"
    case brightnessDown = "brightness-down"
    case kbdLightUp = "kbd-light-up"
    case kbdLightDown = "kbd-light-down"

    /// `NX_KEYTYPE_*` from IOKit's ev_keymap.h, the data1 high word of a
    /// subtype-8 system-defined event.
    public var nxKeyType: Int {
        switch self {
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .brightnessUp: return 2
        case .brightnessDown: return 3
        case .kbdLightUp: return 21
        case .kbdLightDown: return 22
        }
    }

    public var isVolume: Bool { self == .volumeUp || self == .volumeDown }
}

public enum HoverTarget: Equatable, Sendable {
    case notch
    case umbar(identifier: String)
}

// MARK: - Command

/// A validated request. Constructing one is only possible through
/// `Command.parse`, which enforces the allowlist and every parameter bound.
///
/// Note what is absent: there is no `arm` command. Arming is only possible
/// through a physical click on the runner's menu (§3.4); the socket can
/// disarm, never arm.
public enum Command: Equatable, Sendable {
    case status(windows: Bool)
    case version
    case captureApp
    case captureRegion(RegionName)
    case captureAlert(AlertName)
    case recordStart(RecordTarget, maxSeconds: Int)
    case recordStop
    case axTree(AXTreeTarget, depth: Int)
    case pointerHover(HoverTarget, dwellMs: Int)
    case pointerClick(umbarIdentifier: String)
    /// umbar shelf item `index` onto the test Finder window of `folder`.
    case dragShelfToFinder(shelfIndex: Int, folder: String)
    /// `file` in the currently open test Finder folder onto the umbar shelf.
    case dragFinderToShelf(file: String)
    case finderOpenDrop(folder: String)
    case key(KeyName)
    case mediaKey(MediaKeyName)
    case measureHoverExpand(runs: Int)
    case disarm

    /// The wire name, used in logs.
    public var wireName: String {
        switch self {
        case .status: return "status"
        case .version: return "version"
        case .captureApp: return "capture.app"
        case .captureRegion: return "capture.region"
        case .captureAlert: return "capture.alert"
        case .recordStart: return "record.start"
        case .recordStop: return "record.stop"
        case .axTree: return "ax.tree"
        case .pointerHover: return "pointer.hover"
        case .pointerClick: return "pointer.click"
        case .dragShelfToFinder, .dragFinderToShelf: return "drag"
        case .finderOpenDrop: return "finder.open-drop"
        case .key: return "key"
        case .mediaKey: return "media-key"
        case .measureHoverExpand: return "measure.hover-expand"
        case .disarm: return "disarm"
        }
    }

    /// Commands that work while disarmed (§3.4 table). `status` with
    /// `windows` lists other processes' window owners, so it needs arming.
    public var allowedWhileDisarmed: Bool {
        switch self {
        case .status(let windows): return !windows
        case .version, .disarm: return true
        default: return false
        }
    }

    /// Commands that synthesize HID events and therefore also need the
    /// secure-input check to pass, not only the session checks.
    public var postsInput: Bool {
        switch self {
        case .pointerHover, .pointerClick, .dragShelfToFinder, .dragFinderToShelf,
             .key, .mediaKey, .measureHoverExpand:
            return true
        default:
            return false
        }
    }

    /// Commands that count as activity for the 15-minute idle disarm.
    /// Polling `status` must not keep an unattended runner armed.
    public var countsAsActivity: Bool {
        switch self {
        case .status, .version, .disarm: return false
        default: return true
        }
    }

    /// Parameters as they may be logged. All of them are closed-vocabulary
    /// names, bounded integers or charset-restricted identifiers.
    public var logParameters: [String: String] {
        switch self {
        case .status(let w): return w ? ["windows": "true"] : [:]
        case .version, .captureApp, .recordStop, .disarm: return [:]
        case .captureRegion(let r): return ["name": r.rawValue]
        case .captureAlert(let a): return ["name": a.rawValue]
        case .recordStart(let t, let s): return ["target": t.rawValue, "max_s": String(s)]
        case .axTree(let t, let d): return ["target": t.rawValue, "depth": String(d)]
        case .pointerHover(let t, let d):
            return ["target": HoverTarget.render(t), "dwell_ms": String(d)]
        case .pointerClick(let id): return ["target": "umbar:\(id)"]
        case .dragShelfToFinder(let i, let f): return ["from": "umbar-shelf:\(i)", "to": "finder-drop:\(f)"]
        case .dragFinderToShelf(let f): return ["from": "finder-drop:\(f)", "to": "umbar-shelf"]
        case .finderOpenDrop(let f): return ["folder": f]
        case .key(let k): return ["name": k.rawValue]
        case .mediaKey(let k): return ["name": k.rawValue]
        case .measureHoverExpand(let r): return ["target": "notch", "runs": String(r)]
        }
    }
}

extension HoverTarget {
    static func render(_ t: HoverTarget) -> String {
        switch t {
        case .notch: return "notch"
        case .umbar(let id): return "umbar:\(id)"
        }
    }
}

// MARK: - Name grammars

public enum Names {
    /// `finder.open-drop folder=`: `[a-z0-9-]{1,32}` (§3.5). No dots, so a
    /// folder can never be named like a bundle (`x.app`) or be `.`/`..`.
    public static func isValidDropFolder(_ s: String) -> Bool {
        matches(s, maxLength: 32, first: lowerDigit + "-", rest: lowerDigit + "-")
    }

    /// AXIdentifier of an umbar element: `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`.
    public static func isValidAXIdentifier(_ s: String) -> Bool {
        matches(s, maxLength: 64, first: alnum, rest: alnum + "._-")
    }

    /// File in a drop folder: same charset as an identifier. The leading
    /// character cannot be a dot, which rules out `..` and hidden files.
    public static func isValidDropFile(_ s: String) -> Bool {
        matches(s, maxLength: 64, first: alnum, rest: alnum + "._-")
    }

    private static let lowerDigit = "abcdefghijklmnopqrstuvwxyz0123456789"
    private static let alnum = lowerDigit + "ABCDEFGHIJKLMNOPQRSTUVWXYZ"

    private static func matches(_ s: String, maxLength: Int, first: String, rest: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        guard (1...maxLength).contains(scalars.count) else { return false }
        let firstSet = Set(first.unicodeScalars), restSet = Set(rest.unicodeScalars)
        guard firstSet.contains(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy { restSet.contains($0) }
    }
}

// MARK: - Parsing

extension Command {
    /// Parses one request line. This is the only way a request enters the
    /// runner.
    public static func parse(line: some Collection<UInt8>) -> Result<Command, Refusal> {
        StrictJSON.parseObject(line).flatMap(parse(object:))
    }

    /// Validates a parsed object against the allowlist. Unknown commands,
    /// unknown fields and out-of-range values are all refused; nothing is
    /// coerced, clamped or defaulted silently except the documented defaults
    /// of optional bounded parameters.
    public static func parse(object: [String: WireValue]) -> Result<Command, Refusal> {
        var fields = FieldReader(object)
        do {
            guard object["cmd"] != nil else { throw Refusal(.missingCommand) }
            let cmd = try fields.string("cmd")
            let command: Command
            switch cmd {
            case "status":
                command = .status(windows: try fields.optionalBool("windows") ?? false)
            case "version":
                command = .version
            case "capture.app":
                if let format = try fields.optionalString("format"), format != "png" {
                    throw Refusal(.invalidName, "format")
                }
                command = .captureApp
            case "capture.region":
                command = .captureRegion(try fields.enumValue("name", RegionName.self))
            case "capture.alert":
                command = .captureAlert(try fields.enumValue("name", AlertName.self))
            case "record.start":
                let target = try fields.enumValue("target", RecordTarget.self)
                let seconds = try fields.optionalInt("max_s", in: CommandLimits.recordMaxSeconds) ?? CommandLimits.recordMaxSeconds.upperBound
                command = .recordStart(target, maxSeconds: seconds)
            case "record.stop":
                command = .recordStop
            case "ax.tree":
                let target = try fields.enumValue("target", AXTreeTarget.self)
                let depth = try fields.optionalInt("depth", in: CommandLimits.axDepth) ?? CommandLimits.axDepth.upperBound
                command = .axTree(target, depth: depth)
            case "pointer.hover":
                let raw = try fields.string("target")
                let target: HoverTarget
                if raw == "notch" {
                    target = .notch
                } else {
                    target = .umbar(identifier: try umbarIdentifier(raw, field: "target"))
                }
                let dwell = try fields.optionalInt("dwell_ms", in: CommandLimits.hoverDwellMs) ?? 500
                command = .pointerHover(target, dwellMs: dwell)
            case "pointer.click":
                command = .pointerClick(umbarIdentifier: try umbarIdentifier(try fields.string("target"), field: "target"))
            case "drag":
                command = try parseDrag(from: try fields.string("from"), to: try fields.string("to"))
            case "finder.open-drop":
                let folder = try fields.string("folder")
                guard Names.isValidDropFolder(folder) else { throw Refusal(.invalidName, "folder") }
                command = .finderOpenDrop(folder: folder)
            case "key":
                command = .key(try fields.enumValue("name", KeyName.self))
            case "media-key":
                command = .mediaKey(try fields.enumValue("name", MediaKeyName.self))
            case "measure.hover-expand":
                guard try fields.string("target") == "notch" else { throw Refusal(.invalidName, "target") }
                let runs = try fields.optionalInt("runs", in: CommandLimits.measureRuns) ?? 5
                command = .measureHoverExpand(runs: runs)
            case "disarm":
                command = .disarm
            default:
                throw Refusal(.unknownCommand, cmd)
            }
            if let extra = fields.unread.sorted().first {
                throw Refusal(.unknownField, extra)
            }
            return .success(command)
        } catch let refusal as Refusal {
            return .failure(refusal)
        } catch {
            return .failure(Refusal(.malformedJSON))
        }
    }

    private static func umbarIdentifier(_ raw: String, field: String) throws -> String {
        let prefix = "umbar:"
        guard raw.hasPrefix(prefix) else { throw Refusal(.invalidName, field) }
        let id = String(raw.dropFirst(prefix.count))
        guard Names.isValidAXIdentifier(id) else { throw Refusal(.invalidName, field) }
        return id
    }

    private static func parseDrag(from: String, to: String) throws -> Command {
        let shelfItem = "umbar-shelf:", finderDrop = "finder-drop:"
        if from.hasPrefix(shelfItem) {
            let indexText = String(from.dropFirst(shelfItem.count))
            guard let index = Int(indexText), String(index) == indexText,
                  CommandLimits.shelfIndex.contains(index) else {
                throw Refusal(.outOfRange, "from")
            }
            guard to.hasPrefix(finderDrop) else { throw Refusal(.invalidName, "to") }
            let folder = String(to.dropFirst(finderDrop.count))
            guard Names.isValidDropFolder(folder) else { throw Refusal(.invalidName, "to") }
            return .dragShelfToFinder(shelfIndex: index, folder: folder)
        }
        if from.hasPrefix(finderDrop) {
            let file = String(from.dropFirst(finderDrop.count))
            guard Names.isValidDropFile(file) else { throw Refusal(.invalidName, "from") }
            guard to == "umbar-shelf" else { throw Refusal(.invalidName, "to") }
            return .dragFinderToShelf(file: file)
        }
        throw Refusal(.invalidName, "from")
    }
}

/// Reads fields and remembers which were consumed, so anything left over is
/// an unknown field.
private struct FieldReader {
    private let object: [String: WireValue]
    private var read: Set<String> = []

    init(_ object: [String: WireValue]) { self.object = object }

    var unread: Set<String> { Set(object.keys).subtracting(read) }

    mutating func string(_ key: String) throws -> String {
        guard let s = try optionalString(key) else { throw Refusal(.missingField, key) }
        return s
    }

    mutating func optionalString(_ key: String) throws -> String? {
        read.insert(key)
        guard let v = object[key] else { return nil }
        guard case .string(let s) = v else { throw Refusal(.wrongType, key) }
        return s
    }

    mutating func optionalBool(_ key: String) throws -> Bool? {
        read.insert(key)
        guard let v = object[key] else { return nil }
        guard case .bool(let b) = v else { throw Refusal(.wrongType, key) }
        return b
    }

    mutating func optionalInt(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        read.insert(key)
        guard let v = object[key] else { return nil }
        guard case .int(let n) = v else { throw Refusal(.wrongType, key) }
        guard range.contains(n) else { throw Refusal(.outOfRange, key) }
        return n
    }

    mutating func enumValue<E: RawRepresentable>(_ key: String, _: E.Type) throws -> E where E.RawValue == String {
        let raw = try string(key)
        guard let value = E(rawValue: raw) else { throw Refusal(.invalidName, key) }
        return value
    }
}
