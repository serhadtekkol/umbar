import AppKit
import QARunnerCore

/// Owns the arm state, the menu bar item, the kill-switch watchers and the
/// socket. The only arm path is `armClicked`, reachable only from the menu.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let paths: RunnerPaths
    private let uid: UInt32
    private let log: RunnerLog
    private let selfInfo: SigningInfo
    private let stamp: BuildStampValues
    private var arm: ArmController
    private var executor: Executor!
    private var server: SocketServer?
    private var statusItem: NSStatusItem?
    private var timer: Timer?
    /// Read from the socket thread for log records; written on main only.
    private nonisolated(unsafe) var armedFlag = false

    /// How often the automatic disarm rules and the kill file are checked
    /// between commands. Commands themselves re-check on arrival.
    private static let tickSeconds: TimeInterval = 2

    init(paths: RunnerPaths, uid: UInt32, log: RunnerLog, selfInfo: SigningInfo, stamp: BuildStampValues, launchedAt: Date) {
        self.paths = paths
        self.uid = uid
        self.log = log
        self.selfInfo = selfInfo
        self.stamp = stamp
        self.arm = ArmController(launchedAt: launchedAt)
        super.init()
        executor = Executor(
            paths: paths, uid: uid, selfInfo: selfInfo, stamp: stamp,
            armStatus: { [unowned self] in self.armStatusFacts() },
            armedSince: { [unowned self] in self.arm.armedSince },
            preflight: { [unowned self] in self.preflight() })
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        observeSession()

        let server = SocketServer(paths: paths, expectedUID: uid, log: log,
                                  isArmed: { [unowned self] in self.armedFlag },
                                  handler: { [unowned self] line, peer in await self.handle(line: line, peer: peer) })
        if let refusal = server.start() {
            // Without the socket there is no remote disarm, so do not run.
            log.write(LogRecord(time: Date(), event: .exit, refusal: refusal, armed: false), category: .refuse)
            NSApp.terminate(nil)
            return
        }
        self.server = server

        timer = Timer.scheduledTimer(withTimeInterval: Self.tickSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        refreshTitle()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        log.write(LogRecord(time: Date(), event: .exit, armed: arm.state.isArmed), category: .arm)
    }

    // MARK: - Arm state

    private func armStatusFacts() -> [String: JSONValue] {
        var o: [String: JSONValue] = ["armed": .bool(arm.state.isArmed)]
        if let minutes = arm.remainingMinutes(now: Date()) { o["remaining_min"] = .int(minutes) }
        if case .disarmed(_, let reason) = arm.state { o["disarm_reason"] = .string(reason.rawValue) }
        return o
    }

    /// Applies the automatic disarm rules now. Returns a refusal when the
    /// runner is not (or no longer) allowed to act.
    private func preflight() -> Refusal? {
        let session = SystemState.session()
        let kill = SystemState.killFilePresent(paths: paths)
        applyAutomaticDisarm(session: session, killFile: kill)
        if kill { return Refusal(.killFilePresent) }
        guard arm.state.isArmed else { return Refusal(.disarmed) }
        return session.refusal
    }

    private func applyAutomaticDisarm(session: SessionSnapshot, killFile: Bool) {
        if let reason = arm.evaluate(now: Date(), session: session, killFilePresent: killFile) {
            didDisarm(reason)
        }
    }

    private func disarm(_ reason: DisarmReason) {
        if arm.disarm(reason, now: Date()) { didDisarm(reason) }
    }

    private func didDisarm(_ reason: DisarmReason) {
        armedFlag = false
        log.write(LogRecord(time: Date(), event: .disarm, armed: false, facts: ["reason": reason.rawValue]), category: .arm)
        Task { await executor.endSession() }
        refreshTitle()
    }

    private func tick() {
        // The launch gate is re-applied while running: a runner started on
        // day 13 must not stay usable past the embedded expiry.
        if let refusal = LaunchGate.check(stamp: stamp, uid: uid, userName: NSUserName(), now: Date()) {
            timer?.invalidate()
            disarm(.expired)
            log.write(LogRecord(time: Date(), event: .exit, refusal: refusal, armed: false), category: .arm)
            Task { @MainActor in
                await executor.endSession()
                NSApp.terminate(nil)
            }
            return
        }
        applyAutomaticDisarm(session: SystemState.session(), killFile: SystemState.killFilePresent(paths: paths))
        if arm.shouldExit(now: Date()) {
            log.write(LogRecord(time: Date(), event: .exit, armed: false, facts: ["reason": "disarmed-timeout"]), category: .arm)
            NSApp.terminate(nil)
            return
        }
        refreshTitle()
    }

    // MARK: - Session observers (immediate disarm, the timer is the backstop)

    private func observeSession() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.disarm(.sessionInactive) }
        }
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.disarm(.screenLocked) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.disarm(.screenLocked) }
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "UmbarQARunner · yalnızca umbar QA", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        for duration in ArmDuration.allCases {
            let mi = NSMenuItem(title: "Arm \(duration.rawValue) dk", action: #selector(armClicked(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = duration.rawValue
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let stop = NSMenuItem(title: "Durdur", action: #selector(stopClicked(_:)), keyEquivalent: "")
        stop.target = self
        menu.addItem(stop)
        item.menu = menu
        statusItem = item
    }

    /// The only way to arm (§3.4). The triggering event must be a real
    /// left-mouse event from the HID system, delivered within a second;
    /// `ArmController.arm` re-checks the kill file and the session.
    @objc private func armClicked(_ sender: NSMenuItem) {
        let duration = ArmDuration(rawValue: sender.tag) ?? .default
        let evidence = Self.clickEvidence(NSApp.currentEvent)
        let session = SystemState.session()
        let kill = SystemState.killFilePresent(paths: paths)
        switch arm.arm(duration, click: evidence, session: session, killFilePresent: kill, now: Date()) {
        case .success:
            armedFlag = true
            log.write(LogRecord(time: Date(), event: .arm, armed: true, facts: ["minutes": String(duration.rawValue)]), category: .arm)
        case .failure(let refusal):
            log.write(LogRecord(time: Date(), event: .armRefused, refusal: refusal, armed: arm.state.isArmed,
                                facts: ["source_pid": evidence.map { String($0.sourceUnixPID) } ?? "none"]),
                      category: .refuse)
        }
        refreshTitle()
    }

    /// Stop = disarm and quit immediately (§3.4). Not gated on the click
    /// check: stopping must always be possible, by any means.
    @objc private func stopClicked(_ sender: NSMenuItem) {
        disarm(.menuStop)
        Task { @MainActor in
            await executor.endSession()
            NSApp.terminate(nil)
        }
    }

    static func clickEvidence(_ event: NSEvent?) -> ClickEvidence? {
        guard let event else { return nil }
        let kind: ClickEvidence.Kind
        switch event.type {
        case .leftMouseUp: kind = .leftMouseUp
        case .leftMouseDown: kind = .leftMouseDown
        default: kind = .other
        }
        // No CGEvent behind the NSEvent means it was synthesized inside
        // AppKit; treat it as not physical.
        let pid = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
        return ClickEvidence(kind: kind, sourceUnixPID: pid, age: ProcessInfo.processInfo.systemUptime - event.timestamp)
    }

    private func refreshTitle() {
        guard let button = statusItem?.button else { return }
        if let minutes = arm.remainingMinutes(now: Date()) {
            button.attributedTitle = NSAttributedString(
                string: "QA ARMED · \(minutes) dk",
                attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.boldSystemFont(ofSize: 0)])
        } else {
            button.attributedTitle = NSAttributedString(string: "QA", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        }
    }

    // MARK: - Requests

    private func handle(line: [UInt8], peer: Peer) async -> Response {
        let session = SystemState.session()
        let kill = SystemState.killFilePresent(paths: paths)
        applyAutomaticDisarm(session: session, killFile: kill)

        let command: Command
        switch Command.parse(line: line) {
        case .failure(let refusal):
            log.write(LogRecord(time: Date(), event: .refused, callerPID: peer.pid, callerPath: peer.path,
                                refusal: refusal, armed: arm.state.isArmed), category: .refuse)
            return .refusal(refusal)
        case .success(let c):
            command = c
        }

        if let refusal = CommandGate.evaluate(command, isArmed: arm.state.isArmed, session: session, killFilePresent: kill) {
            log.write(LogRecord(time: Date(), event: .refused, command: command.wireName, parameters: command.logParameters,
                                callerPID: peer.pid, callerPath: peer.path, refusal: refusal, armed: arm.state.isArmed),
                      category: .refuse)
            return .refusal(refusal)
        }

        if command == .disarm {
            disarm(.remote)
        }
        let outcome = await executor.run(command)
        let refused = !outcome.response.ok
        if !refused, command.countsAsActivity { arm.recordActivity(now: Date()) }
        log.write(LogRecord(time: Date(), event: refused ? .refused : .accepted, command: command.wireName,
                            parameters: command.logParameters, callerPID: peer.pid, callerPath: peer.path,
                            refusal: outcome.refusal, armed: arm.state.isArmed, detail: outcome.detail),
                  category: refused ? .refuse : .cmd)
        return outcome.response
    }
}
