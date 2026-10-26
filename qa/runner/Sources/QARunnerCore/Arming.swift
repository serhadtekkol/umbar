import Foundation

// MARK: - Session state (§3.2 rule 6)

/// The facts checked before every command. Gathered by the app from
/// `CGSessionCopyCurrentDictionary` and `IsSecureEventInputEnabled`.
public struct SessionSnapshot: Equatable, Sendable {
    /// `nil` when the session dictionary could not be read; treated as
    /// "not on console" (fail closed).
    public var onConsole: Bool?
    public var screenLocked: Bool
    public var secureInput: Bool

    public init(onConsole: Bool?, screenLocked: Bool, secureInput: Bool) {
        self.onConsole = onConsole
        self.screenLocked = screenLocked
        self.secureInput = secureInput
    }

    /// The first failed check, in the order the design lists them.
    public var refusal: Refusal? {
        if onConsole != true { return Refusal(.notOnConsole) }
        if screenLocked { return Refusal(.screenLocked) }
        if secureInput { return Refusal(.secureInput) }
        return nil
    }

    /// Whether this state must end an armed session. All three do: the
    /// design names secure input explicitly, and a locked screen or a
    /// background session (fast user switch back to the owner) is exactly
    /// when nobody is watching the armed runner (§3.4 "Expired" row).
    public var disarmReason: DisarmReason? {
        if onConsole != true { return .sessionInactive }
        if screenLocked { return .screenLocked }
        if secureInput { return .secureInput }
        return nil
    }
}

// MARK: - Physical click (§3.4)

/// What the menu action could learn about the event that triggered it.
public struct ClickEvidence: Equatable, Sendable {
    public enum Kind: Sendable { case leftMouseDown, leftMouseUp, other }
    public var kind: Kind
    /// `kCGEventSourceUnixProcessID`: 0 for events from the HID system, the
    /// poster's PID for anything sent with `CGEventPost`.
    public var sourceUnixPID: Int64
    /// Seconds between the event's timestamp and the moment the action ran.
    public var age: TimeInterval

    public init(kind: Kind, sourceUnixPID: Int64, age: TimeInterval) {
        self.kind = kind
        self.sourceUnixPID = sourceUnixPID
        self.age = age
    }
}

public enum ArmTriggerPolicy {
    /// An action that runs long after its event was not caused by it. This
    /// matters for `AXPress` on the menu item: the action runs without a new
    /// event, and `NSApp.currentEvent` is then whatever came last, possibly a
    /// real click from minutes ago.
    public static let maxEventAge: TimeInterval = 1.0

    /// `nil` evidence (no current event at all) is refused.
    public static func validate(_ evidence: ClickEvidence?) -> Refusal? {
        guard let e = evidence else { return Refusal(.notPhysicalClick, "no-event") }
        guard e.kind != .other else { return Refusal(.notPhysicalClick, "not-mouse") }
        guard e.sourceUnixPID == 0 else { return Refusal(.notPhysicalClick, "synthetic") }
        guard e.age >= 0, e.age <= maxEventAge else { return Refusal(.notPhysicalClick, "stale") }
        return nil
    }
}

// MARK: - Arm state machine (§3.4)

public enum ArmDuration: Int, Sendable, CaseIterable {
    case minutes30 = 30
    case minutes60 = 60
    case minutes120 = 120

    public static let `default` = ArmDuration.minutes60
    public var seconds: TimeInterval { TimeInterval(rawValue * 60) }
}

public enum DisarmReason: String, Sendable {
    case launch
    case expired
    case idle
    case secureInput = "secure-input"
    case screenLocked = "screen-locked"
    case sessionInactive = "session-inactive"
    case remote = "remote-disarm"
    case killFile = "kill-file"
    case menuStop = "menu-stop"
}

public enum ArmState: Equatable, Sendable {
    case disarmed(since: Date, reason: DisarmReason)
    case armed(since: Date, until: Date, lastActivity: Date)

    public var isArmed: Bool {
        if case .armed = self { return true }
        return false
    }
}

/// Owns the armed/disarmed state. Pure: the clock is passed in, so every
/// timeout is testable without sleeping.
public struct ArmController: Sendable {
    public static let idleTimeout: TimeInterval = 15 * 60
    /// After this long disarmed (including right after launch), the runner
    /// quits on its own, so a forgotten launch does not sit there waiting.
    public static let exitAfterDisarmed: TimeInterval = 10 * 60

    public private(set) var state: ArmState

    public init(launchedAt: Date) {
        state = .disarmed(since: launchedAt, reason: .launch)
    }

    /// Arms for `duration`. Every precondition is checked here rather than
    /// in the UI, so the menu cannot arm around them.
    public mutating func arm(
        _ duration: ArmDuration,
        click: ClickEvidence?,
        session: SessionSnapshot,
        killFilePresent: Bool,
        now: Date
    ) -> Result<Void, Refusal> {
        if let refusal = ArmTriggerPolicy.validate(click) { return .failure(refusal) }
        if killFilePresent { return .failure(Refusal(.killFilePresent)) }
        if let refusal = session.refusal { return .failure(refusal) }
        // Re-arming while armed restarts the window from now; it never
        // extends past `duration`, which is at most 120 minutes.
        state = .armed(since: now, until: now.addingTimeInterval(duration.seconds), lastActivity: now)
        return .success(())
    }

    /// Returns true when the state changed.
    @discardableResult
    public mutating func disarm(_ reason: DisarmReason, now: Date) -> Bool {
        guard state.isArmed else { return false }
        state = .disarmed(since: now, reason: reason)
        return true
    }

    public mutating func recordActivity(now: Date) {
        if case .armed(let since, let until, _) = state {
            state = .armed(since: since, until: until, lastActivity: now)
        }
    }

    /// Applies every automatic disarm rule. Called before each command and
    /// on a timer. Returns the reason when it disarmed.
    @discardableResult
    public mutating func evaluate(now: Date, session: SessionSnapshot, killFilePresent: Bool) -> DisarmReason? {
        guard case .armed(_, let until, let lastActivity) = state else { return nil }
        let reason: DisarmReason?
        if killFilePresent {
            reason = .killFile
        } else if let sessionReason = session.disarmReason {
            reason = sessionReason
        } else if now >= until {
            reason = .expired
        } else if now.timeIntervalSince(lastActivity) >= Self.idleTimeout {
            reason = .idle
        } else {
            reason = nil
        }
        if let reason { disarm(reason, now: now) }
        return reason
    }

    public func shouldExit(now: Date) -> Bool {
        guard case .disarmed(let since, _) = state else { return false }
        return now.timeIntervalSince(since) >= Self.exitAfterDisarmed
    }

    /// Whole minutes left, rounded up, for the menu bar label.
    public func remainingMinutes(now: Date) -> Int? {
        guard case .armed(_, let until, _) = state else { return nil }
        return max(0, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
    }

    public var armedSince: Date? {
        if case .armed(let since, _, _) = state { return since }
        return nil
    }
}

// MARK: - Command gate

/// The single decision "may this command run now?", applied in this order:
/// disarm is always accepted; the kill file refuses everything else that
/// needs arming; then the arm state; then the session checks.
public enum CommandGate {
    public static func evaluate(_ command: Command, isArmed: Bool, session: SessionSnapshot, killFilePresent: Bool) -> Refusal? {
        if command == .disarm { return nil }
        if command.allowedWhileDisarmed { return nil }
        if killFilePresent { return Refusal(.killFilePresent) }
        guard isArmed else { return Refusal(.disarmed) }
        if let refusal = session.refusal { return refusal }
        return nil
    }
}

// MARK: - Peer check (§3.3)

public enum PeerPolicy {
    /// Only the test account itself may talk to the socket. The PID and path
    /// of the peer are logged by the caller for the trail, but they are not
    /// an authorization input: within one UID they can be spoofed.
    public static func check(peerUID: UInt32?, expectedUID: UInt32) -> Refusal? {
        guard let peerUID else { return Refusal(.peerUIDMismatch, "unknown") }
        return peerUID == expectedUID ? nil : Refusal(.peerUIDMismatch)
    }
}
