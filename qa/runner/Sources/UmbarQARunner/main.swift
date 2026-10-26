//
//  UmbarQARunner — the QA GUI runner of docs/qa-gui-runner.md (card #96).
//
//  Process model (§3.2), enforced by review and by build.sh's `nm` check:
//  no child processes, no interpreters or plug-ins, no network, writes only
//  under the runner's Application Support folder, ~/umbar-qa/evidence and
//  ~/Library/Logs/UmbarQARunner.
//
//  Launch (§3.3): `open -g -a ~/Applications/UmbarQARunner.app` from SSH, so
//  that launchd, not the SSH session, is the parent and TCC attributes the
//  grants to this bundle. Running the binary directly from a shell is not a
//  supported launch path.
//

import AppKit
import QARunnerCore
import QARunnerStamp

let launchedAt = Date()
let stamp = BuildStampValues(targetUID: BuildStamp.targetUID, targetUserName: BuildStamp.targetUserName,
                             builtAt: BuildStamp.builtAt, expiresAt: BuildStamp.expiresAt)
let uid = UInt32(getuid())
let realHome = DropArea.realpath(NSHomeDirectory()) ?? NSHomeDirectory()
let selfInfo = CodeIdentity.current()

var launchFacts: [String: String] = [
    "uid": String(uid),
    "cdhash": selfInfo.cdhash ?? "unknown",
    "hardened_runtime": String(selfInfo.hardenedRuntime),
]
if let e = stamp.expiresAt { launchFacts["expires_at"] = String(e) }
if let t = selfInfo.teamID { launchFacts["team_id"] = t }

// The gate runs before NSApplication exists: a refused launch shows no
// menu, opens no socket, calls no TCC API and writes no file in the
// account it was started in (unified log only).
if let refusal = LaunchGate.check(stamp: stamp, uid: uid, userName: NSUserName(), now: launchedAt) {
    RunnerLog(realHome: realHome, fileLogging: false)
        .write(LogRecord(time: launchedAt, event: .launchRefused, refusal: refusal, armed: false, facts: launchFacts),
               category: .refuse)
    exit(78) // EX_CONFIG
}

let log = RunnerLog(realHome: realHome, fileLogging: true)
log.write(LogRecord(time: launchedAt, event: .launch, armed: false, facts: launchFacts), category: .arm)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MainActor.assumeIsolated {
    AppController(paths: RunnerPaths(realHome: realHome), uid: uid, log: log, selfInfo: selfInfo,
                  stamp: stamp, launchedAt: launchedAt)
}
app.delegate = controller
app.run()
