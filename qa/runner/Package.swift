// swift-tools-version: 6.0
//
// UmbarQARunner: the QA GUI runner of docs/qa-gui-runner.md (card #96).
//
// This package is deliberately separate from boringNotch.xcodeproj (design
// §7): the runner must never share umbar's signing identity, entitlements or
// app target. Nothing here is referenced from umbar's pbxproj.
//
// Targets:
//   QARunnerCore   Pure policy: wire schema, allowlist, arm state machine,
//                  launch gate, path/hit-test/audio rules, log records. No
//                  AppKit, no TCC, fully unit tested.
//   QARunnerStamp  The build stamp (target UID, expiry). The committed file
//                  is "unstamped" and makes the runner refuse to start;
//                  build.sh compiles a stamped copy in a staging directory.
import PackageDescription

let package = Package(
    name: "UmbarQARunner",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "QARunnerCore"),
        .target(name: "QARunnerStamp"),
        .testTarget(
            name: "QARunnerCoreTests",
            dependencies: ["QARunnerCore"]
        ),
    ]
)
