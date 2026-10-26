import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QARunnerCore
import ScreenCaptureKit

/// Runs commands that already passed `Command.parse` and `CommandGate`.
///
/// Every command resolves its own targets by name (§3.5: the caller never
/// supplies coordinates or PIDs), and every event goes through
/// `Input.verify` immediately before it is posted. `preflight` re-applies
/// the arm and session rules between steps, so a long command (a hover
/// dwell, a measurement series) stops the moment the session is locked,
/// secure input turns on or someone disarms.
@MainActor
final class Executor {
    struct Outcome {
        var response: Response
        var detail = LogDetail()
        var refusal: Refusal?

        init(response: Response, detail: LogDetail = LogDetail()) {
            self.response = response
            self.detail = detail
        }

        init(refusal: Refusal) {
            self.response = .refusal(refusal)
            self.refusal = refusal
        }
    }

    private let paths: RunnerPaths
    private let dropArea: DropArea
    private let writePolicy: WritePolicy
    private let selfInfo: SigningInfo
    private let stamp: BuildStampValues
    private let armStatus: () -> [String: JSONValue]
    private let armedSince: () -> Date?
    private let preflight: () -> Refusal?
    private let recorder = Recorder()

    /// Folder opened by `finder.open-drop` in this armed session. The Finder
    /// target of `drag`, `ax.tree finder-drop` and `capture.region
    /// finder-drop` is only ever this folder's window.
    private var openedFolder: String?
    /// Output volume before the first volume key of the session; restored on
    /// disarm (§3.7 rule 3).
    private var savedVolume: Float?
    private var evidenceSequence = 0
    private var promptedForPermissions = false

    init(paths: RunnerPaths, uid: UInt32, selfInfo: SigningInfo, stamp: BuildStampValues,
         armStatus: @escaping () -> [String: JSONValue], armedSince: @escaping () -> Date?,
         preflight: @escaping () -> Refusal?) {
        self.paths = paths
        self.dropArea = DropArea(realHome: paths.realHome, uid: uid)
        self.writePolicy = WritePolicy(realHome: paths.realHome)
        self.selfInfo = selfInfo
        self.stamp = stamp
        self.armStatus = armStatus
        self.armedSince = armedSince
        self.preflight = preflight
    }

    /// Ends everything a session started: recording, volume, Finder target.
    func endSession() async {
        _ = await recorder.stop()
        if let savedVolume { Audio.setVolume(savedVolume) }
        savedVolume = nil
        openedFolder = nil
    }

    func run(_ command: Command) async -> Outcome {
        do {
            return try await dispatch(command)
        } catch let refusal as Refusal {
            return Outcome(refusal: refusal)
        } catch Capture.Failure.refused(let refusal) {
            return Outcome(refusal: refusal)
        } catch {
            return Outcome(refusal: Refusal(.ioError))
        }
    }

    // MARK: - Dispatch

    private func dispatch(_ command: Command) async throws -> Outcome {
        switch command {
        case .status(let windows): return status(windows: windows)
        case .version: return Outcome(response: .success(versionFacts()))
        case .disarm: return Outcome(response: .success())
        case .captureApp: return try await captureApp()
        case .captureRegion(let name): return try await captureRegion(name)
        case .captureAlert(let name):
            // Refused until T6 fills the owner list; see AlertAllowlist.
            _ = try AlertAllowlist.owners(for: name).get()
            throw Refusal(.alertAllowlistEmpty, name.rawValue)
        case .recordStart(let target, let seconds): return try await recordStart(target, seconds: seconds)
        case .recordStop:
            guard let result = await recorder.stop() else { throw Refusal(.noRecording) }
            return Outcome(response: .success(["file": .string(result.file), "seconds": .double(result.seconds)]),
                           detail: LogDetail(files: [result.file]))
        case .axTree(let target, let depth): return try axTree(target, depth: depth)
        case .pointerHover(let target, let dwell): return try await hover(target, dwellMs: dwell)
        case .pointerClick(let id): return try await click(id)
        case .dragShelfToFinder(let index, let folder): return try await dragShelfToFinder(index: index, folder: folder)
        case .dragFinderToShelf(let file): return try await dragFinderToShelf(file: file)
        case .finderOpenDrop(let folder): return try await openDrop(folder)
        case .key(let name): return try pressKey(name)
        case .mediaKey(let name): return try pressMediaKey(name)
        case .measureHoverExpand(let runs): return try await measure(runs: runs)
        }
    }

    // MARK: - status / version

    private func versionFacts() -> [String: JSONValue] {
        var o: [String: JSONValue] = [
            "bundle_id": .string(RunnerIdentity.bundleID),
            "hardened_runtime": .bool(selfInfo.hardenedRuntime),
        ]
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String { o["version"] = .string(v) }
        if let c = selfInfo.cdhash { o["cdhash"] = .string(c) }
        if let t = selfInfo.teamID { o["team_id"] = .string(t) }
        if let e = stamp.expiresAt { o["expires_at"] = .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(e)))) }
        return o
    }

    private func status(windows: Bool) -> Outcome {
        var screen = CGPreflightScreenCaptureAccess()
        var ax = AXIsProcessTrusted()
        // §5: the first status call triggers the two TCC prompts, once per
        // process. The prompts must name UmbarQARunner; T1 verifies that the
        // responsible process is the runner and not the SSH chain.
        if !promptedForPermissions, !screen || !ax {
            promptedForPermissions = true
            if !screen { screen = CGRequestScreenCaptureAccess() }
            if !ax {
                let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                ax = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            }
        }
        var o = versionFacts().merging(armStatus()) { a, _ in a }
        o["screen"] = .bool(screen)
        o["ax"] = .bool(ax)
        o["uid"] = .int(Int(getuid()))
        o["user"] = .string(NSUserName())
        o["kill_file"] = .bool(SystemState.killFilePresent(paths: paths))
        o["silent_precondition"] = .string(SystemState.silentAssertion(paths: paths, armedSince: armedSince())
            ? AudioPolicy.silentAssertionText : "not-asserted")
        if case .success(let umbar) = locateUmbar() { o["umbar_pid"] = .int(Int(umbar.pid)) }
        if windows { o["windows"] = .array(windowOwners()) }
        return Outcome(response: .success(o))
    }

    /// For T6 (§8): owner name, PID, layer and bounds of on-screen windows.
    /// Window titles (`kCGWindowName`) are content and are not read.
    private func windowOwners() -> [JSONValue] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.map { w in
            var o: [String: JSONValue] = [:]
            if let owner = w[kCGWindowOwnerName as String] as? String { o["owner"] = .string(owner) }
            if let pid = w[kCGWindowOwnerPID as String] as? Int { o["pid"] = .int(pid) }
            if let layer = w[kCGWindowLayer as String] as? Int { o["layer"] = .int(layer) }
            if let b = w[kCGWindowBounds as String] as? [String: Any], let r = CGRect(dictionaryRepresentation: b as CFDictionary) {
                o["bounds"] = .object(["x": .double(r.minX), "y": .double(r.minY), "w": .double(r.width), "h": .double(r.height)])
            }
            return .object(o)
        }
    }

    // MARK: - Targets

    struct UmbarTarget {
        var pid: Int32
        var record: [String: JSONValue]
    }

    private func locateUmbar() -> Result<UmbarTarget, Refusal> {
        let candidates = NSWorkspace.shared.runningApplications.map {
            AppCandidate(pid: $0.processIdentifier, bundleID: $0.bundleIdentifier,
                         bundleRealPath: $0.bundleURL.flatMap { DropArea.realpath($0.path) })
        }
        return UmbarLocatorPolicy.select(candidates, realHome: paths.realHome).flatMap { candidate in
            guard let (code, info) = CodeIdentity.of(pid: candidate.pid) else {
                return .failure(Refusal(.umbarSignature, "unreadable"))
            }
            let satisfies = info.teamID == nil ? false : CodeIdentity.satisfiesTeamRequirement(code)
            if let refusal = UmbarLocatorPolicy.checkSignature(teamID: info.teamID, satisfiesTeamRequirement: satisfies) {
                return .failure(refusal)
            }
            var record: [String: JSONValue] = ["pid": .int(Int(candidate.pid))]
            if let id = candidate.bundleID { record["bundle_id"] = .string(id) }
            if let path = candidate.bundleRealPath {
                record["path"] = .string(path)
                if let plist = NSDictionary(contentsOfFile: (path as NSString).appendingPathComponent("Contents/Info.plist")) {
                    if let v = plist["CFBundleShortVersionString"] as? String { record["version"] = .string(v) }
                    if let b = plist["CFBundleVersion"] as? String { record["build"] = .string(b) }
                }
            }
            if let c = info.cdhash { record["cdhash"] = .string(c) }
            record["team_id"] = info.teamID.map(JSONValue.string) ?? .null
            return .success(UmbarTarget(pid: candidate.pid, record: record))
        }
    }

    private func finderPID() -> Result<Int32, Refusal> {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: UmbarIdentity.finderBundleID)
            .filter { $0.bundleURL?.path == "/System/Library/CoreServices/Finder.app" }
        guard apps.count == 1 else { return .failure(Refusal(.noFinderDropWindow, "finder")) }
        return .success(apps[0].processIdentifier)
    }

    struct FinderDropWindow {
        var finderPID: Int32
        var folderRealPath: String
        var element: AXUIElement
        var frame: CGRect
    }

    /// The runner-opened Finder window, re-resolved on every use: the folder
    /// path is re-checked with realpath, and the window must still show
    /// exactly that folder.
    private func finderDropWindow(folder requested: String? = nil) throws -> FinderDropWindow {
        guard let folder = openedFolder else { throw Refusal(.noFinderDropWindow) }
        if let requested, requested != folder { throw Refusal(.noFinderDropWindow, "different-folder") }
        let real = try dropArea.resolveFolder(folder).get()
        let pid = try finderPID().get()
        for window in AX.windows(AX.application(pid: pid)) {
            if dropArea.documentMatches(AX.string(window, kAXDocumentAttribute), folderRealPath: real),
               let frame = AX.frame(window) {
                return FinderDropWindow(finderPID: pid, folderRealPath: real, element: window, frame: frame)
            }
        }
        throw Refusal(.noFinderDropWindow)
    }

    private func umbarElementCenter(_ identifier: String, umbarPID: Int32) throws -> CGPoint {
        let matches = AX.find(identifier: identifier, in: AX.application(pid: umbarPID))
        guard matches.count == 1 else { throw Refusal(.targetNotFound, matches.isEmpty ? identifier : "ambiguous") }
        guard let frame = AX.frame(matches[0]) else { throw Refusal(.targetNotFound, "frame") }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func notchDisplay() throws -> (geometry: DisplayGeometry, displayID: CGDirectDisplayID, scale: CGFloat) {
        guard let d = SystemState.notchDisplay() else { throw Refusal(.noNotchDisplay) }
        return d
    }

    private func requireAX() throws {
        guard AXIsProcessTrusted() else { throw Refusal(.permissionMissing, "accessibility") }
    }

    private func requireScreen() throws {
        guard CGPreflightScreenCaptureAccess() else { throw Refusal(.permissionMissing, "screen") }
    }

    /// Re-applies the arm/session rules, then verifies the point.
    private func checkedPoint(_ point: CGPoint, _ expect: HitExpectation) throws -> VerifiedPoint {
        if let refusal = preflight() { throw refusal }
        return try Input.verify(point, expect: expect, dropArea: dropArea).get()
    }

    private func sleep(ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, ms)) * 1_000_000)
    }

    // MARK: - Evidence

    private func newEvidencePath(for command: String, ext: String) throws -> String {
        var st = stat()
        guard lstat(paths.evidenceRoot, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else {
            throw Refusal(.ioError, "evidence-root-missing")
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let run = (paths.evidenceRoot as NSString).appendingPathComponent(f.string(from: armedSince() ?? Date()))
        guard SafeFiles.makePrivateDirectory(run) else { throw Refusal(.ioError, "evidence-run-dir") }
        evidenceSequence += 1
        let name = String(format: "%03d-%@-%@.%@", evidenceSequence, command.replacingOccurrences(of: ".", with: "-"),
                          f.string(from: Date()), ext)
        let path = (run as NSString).appendingPathComponent(name)
        guard writePolicy.isAllowed(path) else { throw Refusal(.writeOutsideAllowedRoots) }
        return path
    }

    /// The sidecar carries the build-record facts of test-plan §3.4: the
    /// runner's cdhash, umbar's build record and the time (§3.6).
    private func writeSidecar(for file: String, command: String, umbar: UmbarTarget?, extra: [String: JSONValue] = [:]) throws {
        var o: [String: JSONValue] = [
            "file": .string((file as NSString).lastPathComponent),
            "cmd": .string(command),
            "ts": .string(ISO8601DateFormatter().string(from: Date())),
            "runner_cdhash": selfInfo.cdhash.map(JSONValue.string) ?? .null,
        ]
        if let umbar { o["umbar"] = .object(umbar.record) }
        for (k, v) in extra { o[k] = v }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let data = try encoder.encode(JSONValue.object(o))
        if let refusal = SafeFiles.createNew(file + ".json", data: data, policy: writePolicy) { throw refusal }
    }

    // MARK: - Capture

    private func captureApp() async throws -> Outcome {
        try requireScreen()
        let umbar = try locateUmbar().get()
        let display = try notchDisplay()
        let png = try await Capture.screenshotPNG(plan: .appWindows(pid: umbar.pid), displayID: display.displayID, scale: display.scale)
        let path = try newEvidencePath(for: "capture.app", ext: "png")
        if let refusal = SafeFiles.createNew(path, data: png, policy: writePolicy) { throw refusal }
        try writeSidecar(for: path, command: "capture.app", umbar: umbar)
        return Outcome(response: .success(["file": .string(path)]), detail: LogDetail(files: [path], umbarPID: umbar.pid))
    }

    private func captureRegion(_ name: RegionName) async throws -> Outcome {
        try requireScreen()
        let display = try notchDisplay()
        var windowID: UInt32?
        if name == .finderDrop {
            try requireAX()
            windowID = try await finderDropWindowID()
        }
        let plan = try CapturePlanner.plan(region: name, display: display.geometry, finderDropWindowID: windowID).get()
        let png = try await Capture.screenshotPNG(plan: plan, displayID: display.displayID, scale: display.scale)
        let path = try newEvidencePath(for: "capture.region-\(name.rawValue)", ext: "png")
        if let refusal = SafeFiles.createNew(path, data: png, policy: writePolicy) { throw refusal }
        let umbar = try? locateUmbar().get()
        try writeSidecar(for: path, command: "capture.region", umbar: umbar, extra: ["region": .string(name.rawValue)])
        return Outcome(response: .success(["file": .string(path)]), detail: LogDetail(files: [path], umbarPID: umbar?.pid))
    }

    /// Maps the AX Finder window to its `CGWindowID` through ScreenCaptureKit
    /// (owner PID + identical frame). There is no public AX→window-ID call,
    /// and the private `_AXUIElementGetWindow` is not used.
    private func finderDropWindowID() async throws -> UInt32 {
        let window = try finderDropWindow()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let matches = content.windows.filter {
            $0.owningApplication?.processID == window.finderPID
                && abs($0.frame.minX - window.frame.minX) < 1 && abs($0.frame.minY - window.frame.minY) < 1
                && abs($0.frame.width - window.frame.width) < 1 && abs($0.frame.height - window.frame.height) < 1
        }
        guard matches.count == 1 else { throw Refusal(.noFinderDropWindow, matches.isEmpty ? "sck" : "ambiguous") }
        return matches[0].windowID
    }

    private func recordStart(_ target: RecordTarget, seconds: Int) async throws -> Outcome {
        try requireScreen()
        let display = try notchDisplay()
        let umbar = try locateUmbar().get()
        let plan: CapturePlan
        switch target {
        case .app: plan = .appWindows(pid: umbar.pid)
        case .notch: plan = try CapturePlanner.plan(region: .notch, display: display.geometry, finderDropWindowID: nil).get()
        }
        let path = try newEvidencePath(for: "record-\(target.rawValue)", ext: "mov")
        try await recorder.start(plan: plan, displayID: display.displayID, scale: display.scale, path: path, maxSeconds: seconds)
        try writeSidecar(for: path, command: "record.start", umbar: umbar,
                         extra: ["target": .string(target.rawValue), "max_s": .int(seconds), "audio": .bool(false)])
        return Outcome(response: .success(["file": .string(path), "max_s": .int(seconds)]),
                       detail: LogDetail(files: [path], umbarPID: umbar.pid))
    }

    // MARK: - AX

    private func axTree(_ target: AXTreeTarget, depth: Int) throws -> Outcome {
        try requireAX()
        switch target {
        case .umbar:
            let umbar = try locateUmbar().get()
            let tree = AX.tree(of: AX.application(pid: umbar.pid), depth: depth)
            return Outcome(response: .success(["pid": .int(Int(umbar.pid)), "tree": tree.json]),
                           detail: LogDetail(nodeCount: tree.nodeCount, umbarPID: umbar.pid))
        case .finderDrop:
            // Only the window's AXDocument and the item names (§3.5). Item
            // names come from the verified folder itself rather than from
            // Finder's AX tree, so the sidebar and toolbar of the Finder
            // window (which list other locations) are never read.
            let window = try finderDropWindow()
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: window.folderRealPath)) ?? []).sorted()
            return Outcome(response: .success([
                "document": .string(URL(fileURLWithPath: window.folderRealPath).absoluteString),
                "items": .array(names.map(JSONValue.string)),
                "frame": .object(["x": .double(window.frame.minX), "y": .double(window.frame.minY),
                                  "w": .double(window.frame.width), "h": .double(window.frame.height)]),
            ]), detail: LogDetail(nodeCount: names.count))
        }
    }

    // MARK: - Pointer

    private func hover(_ target: HoverTarget, dwellMs: Int) async throws -> Outcome {
        try requireAX()
        let umbar = try locateUmbar().get()
        let point: CGPoint
        switch target {
        case .notch: point = try Regions.notchHoverPoint(on: try notchDisplay().geometry).get()
        case .umbar(let id): point = try umbarElementCenter(id, umbarPID: umbar.pid)
        }
        Input.move(to: try checkedPoint(point, .umbar(pid: umbar.pid)))
        await sleep(ms: dwellMs)
        if let refusal = preflight() { throw refusal }
        return Outcome(response: .success(["x": .double(point.x), "y": .double(point.y)]), detail: LogDetail(umbarPID: umbar.pid))
    }

    private func click(_ identifier: String) async throws -> Outcome {
        try requireAX()
        let umbar = try locateUmbar().get()
        let point = try umbarElementCenter(identifier, umbarPID: umbar.pid)
        Input.move(to: try checkedPoint(point, .umbar(pid: umbar.pid)))
        await sleep(ms: 50)
        // Re-verify after the move: hover can change what is under the point.
        Input.click(at: try checkedPoint(point, .umbar(pid: umbar.pid)))
        return Outcome(response: .success(["x": .double(point.x), "y": .double(point.y)]), detail: LogDetail(umbarPID: umbar.pid))
    }

    /// Shelf items are found by the AXIdentifier convention
    /// `umbar.shelf.item.<index>`, and the shelf drop zone by `umbar.shelf`.
    /// umbar does not set these identifiers yet (open item for the umbar
    /// side); until it does, `drag` is refused with target-not-found.
    static func shelfItemIdentifier(_ index: Int) -> String { "umbar.shelf.item.\(index)" }
    static let shelfIdentifier = "umbar.shelf"

    private func dragShelfToFinder(index: Int, folder: String) async throws -> Outcome {
        try requireAX()
        let umbar = try locateUmbar().get()
        let window = try finderDropWindow(folder: folder)
        let fromPoint = try umbarElementCenter(Self.shelfItemIdentifier(index), umbarPID: umbar.pid)
        let toPoint = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let finderExpect = HitExpectation.finderDrop(finderPID: window.finderPID, folderRealPath: window.folderRealPath)
        // Both endpoints are verified before the button goes down.
        let from = try checkedPoint(fromPoint, .umbar(pid: umbar.pid))
        let to = try checkedPoint(toPoint, finderExpect)
        try await performDrag(from: from, to: to, finalCheck: { try self.checkedPoint(toPoint, finderExpect) })
        return Outcome(response: .success(["from": .string("umbar-shelf:\(index)"), "to": .string("finder-drop:\(folder)")]),
                       detail: LogDetail(umbarPID: umbar.pid))
    }

    private func dragFinderToShelf(file: String) async throws -> Outcome {
        try requireAX()
        let umbar = try locateUmbar().get()
        let window = try finderDropWindow()
        _ = try dropArea.resolveFile(file, inFolder: window.folderRealPath).get()
        let fromPoint = try finderItemCenter(file, in: window)
        let toPoint: CGPoint
        if let shelf = try? umbarElementCenter(Self.shelfIdentifier, umbarPID: umbar.pid) {
            toPoint = shelf
        } else {
            // Dragging onto the notch is how umbar's shelf opens for a drop.
            toPoint = try Regions.notchHoverPoint(on: try notchDisplay().geometry).get()
        }
        let finderExpect = HitExpectation.finderDrop(finderPID: window.finderPID, folderRealPath: window.folderRealPath)
        let from = try checkedPoint(fromPoint, finderExpect)
        let to = try checkedPoint(toPoint, .umbar(pid: umbar.pid))
        try await performDrag(from: from, to: to, finalCheck: { try self.checkedPoint(toPoint, .umbar(pid: umbar.pid)) })
        return Outcome(response: .success(["from": .string("finder-drop:\(file)"), "to": .string("umbar-shelf")]),
                       detail: LogDetail(umbarPID: umbar.pid))
    }

    /// The Finder item for `file`, searched only inside the test window.
    /// Matched by `AXFilename` or by title, and only used for its frame.
    private func finderItemCenter(_ file: String, in window: FinderDropWindow) throws -> CGPoint {
        var queue: [(AXUIElement, Int)] = [(window.element, 0)]
        var visited = 0
        while !queue.isEmpty, visited < CommandLimits.axMaxNodes {
            let (e, d) = queue.removeFirst()
            visited += 1
            if AX.string(e, "AXFilename") == file || AX.string(e, kAXTitleAttribute) == file,
               let frame = AX.frame(e) {
                return CGPoint(x: frame.midX, y: frame.midY)
            }
            if d < CommandLimits.axDepth.upperBound { queue.append(contentsOf: AX.children(e).map { ($0, d + 1) }) }
        }
        throw Refusal(.targetNotFound, file)
    }

    /// Button down at `from`, interpolated drags, then a final ownership
    /// check of `to` before release. If that check fails the button is
    /// released back at `from` (the drag source, already verified) so the
    /// mouse button is never left pressed and nothing lands on a foreign
    /// target.
    private func performDrag(from: VerifiedPoint, to: VerifiedPoint, finalCheck: () throws -> VerifiedPoint) async throws {
        Input.move(to: from)
        await sleep(ms: 100)
        Input.mouseDown(at: from)
        let steps = 20
        for i in 1...steps {
            await sleep(ms: 20)
            Input.dragStep(from: from, to: to, fraction: CGFloat(i) / CGFloat(steps))
        }
        await sleep(ms: 400)
        do {
            Input.mouseUp(at: try finalCheck())
        } catch {
            for i in stride(from: steps, through: 0, by: -1) {
                Input.dragStep(from: from, to: to, fraction: CGFloat(i) / CGFloat(steps))
            }
            Input.mouseUp(at: from)
            throw error
        }
    }

    // MARK: - Finder

    private func openDrop(_ folder: String) async throws -> Outcome {
        try requireAX()
        let real = try dropArea.resolveFolder(folder).get()
        // A directory that is a package would be "opened" by launching it.
        // The name grammar already forbids dots; this is the second check.
        guard !NSWorkspace.shared.isFilePackage(atPath: real) else { throw Refusal(.dropPathRejected, "package") }
        // Opened explicitly *with Finder*, never with the default handler,
        // so no other application can be launched by this command.
        let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.open([URL(fileURLWithPath: real, isDirectory: true)],
                                                  withApplicationAt: finderURL, configuration: config)
        } catch {
            throw Refusal(.ioError, "open")
        }
        openedFolder = folder
        for _ in 0..<30 {
            if let window = try? finderDropWindow() {
                return Outcome(response: .success([
                    "folder": .string(folder),
                    "frame": .object(["x": .double(window.frame.minX), "y": .double(window.frame.minY),
                                      "w": .double(window.frame.width), "h": .double(window.frame.height)]),
                ]))
            }
            await sleep(ms: 100)
        }
        throw Refusal(.noFinderDropWindow, "timeout")
    }

    // MARK: - Keys

    private func pressKey(_ key: KeyName) throws -> Outcome {
        try requireAX()
        let umbar = try locateUmbar().get()
        if let refusal = preflight() { throw refusal }
        if let refusal = HitTestPolicy.verifyFocus(focusedPID: AX.focusedPID(), umbarPID: umbar.pid, runnerPID: getpid()) {
            throw refusal
        }
        Input.press(key)
        return Outcome(response: .success(["name": .string(key.rawValue)]), detail: LogDetail(umbarPID: umbar.pid))
    }

    private func pressMediaKey(_ key: MediaKeyName) throws -> Outcome {
        if let refusal = preflight() { throw refusal }
        let before = Audio.volume()
        if let refusal = AudioPolicy.check(key, beepFeedback: SystemState.beepFeedback(),
                                           silentAsserted: SystemState.silentAssertion(paths: paths, armedSince: armedSince()),
                                           currentVolume: before) {
            throw refusal
        }
        if key.isVolume, savedVolume == nil { savedVolume = before }
        Input.press(key)
        var o: [String: JSONValue] = ["name": .string(key.rawValue)]
        if key.isVolume, let before { o["volume_before"] = .double(Double(before)) }
        return Outcome(response: .success(o))
    }

    // MARK: - Measurement

    /// AC-1.1 / NFR-PERF-1. Each run starts with the pointer resting in the
    /// test Finder window (a sanctioned target, so the pointer never rests on
    /// a foreign app), waits for umbar's window frames to settle, then moves
    /// to the notch and times the first change of umbar's window frames with
    /// `mach_absolute_time`. A run that sees no change within the timeout
    /// reports null rather than a made-up number.
    private func measure(runs: Int) async throws -> Outcome {
        try requireAX()
        let umbar = try locateUmbar().get()
        let window = try finderDropWindow()
        let restPoint = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let restExpect = HitExpectation.finderDrop(finderPID: window.finderPID, folderRealPath: window.folderRealPath)
        let notch = try Regions.notchHoverPoint(on: try notchDisplay().geometry).get()
        let app = AX.application(pid: umbar.pid)
        func frames() -> [CGRect] { AX.windows(app).compactMap(AX.frame) }

        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let timeoutMs = 3000.0
        var results: [JSONValue] = []
        for _ in 0..<runs {
            Input.move(to: try checkedPoint(restPoint, restExpect))
            await sleep(ms: 1200)
            let baseline = frames()
            let target = try checkedPoint(notch, .umbar(pid: umbar.pid))
            let t0 = mach_absolute_time()
            Input.move(to: target)
            var elapsed: Double?
            while true {
                let ms = Double(mach_absolute_time() - t0) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
                if frames() != baseline { elapsed = ms; break }
                if ms > timeoutMs { break }
                await sleep(ms: 2)
            }
            results.append(elapsed.map { .double(($0 * 10).rounded() / 10) } ?? .null)
            if let refusal = preflight() { throw refusal }
        }
        Input.move(to: try checkedPoint(restPoint, restExpect))
        return Outcome(response: .success(["ms": .array(results), "timeout_ms": .double(timeoutMs)]),
                       detail: LogDetail(umbarPID: umbar.pid, measurements: results.count))
    }
}
