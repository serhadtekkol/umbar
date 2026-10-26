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
//   UmbarQARunner  The menu bar app (AppKit, ScreenCaptureKit, AX, CoreAudio).
//   qa-cli         The socket client used over SSH. Needs no TCC grant.
import PackageDescription

let package = Package(
    name: "UmbarQARunner",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "UmbarQARunner", targets: ["UmbarQARunner"]),
        .executable(name: "qa-cli", targets: ["qa-cli"]),
    ],
    targets: [
        .target(name: "QARunnerCore"),
        .target(name: "QARunnerStamp"),
        .executableTarget(
            name: "UmbarQARunner",
            dependencies: ["QARunnerCore", "QARunnerStamp"],
            // AppKit/ScreenCaptureKit/AX callbacks are main-thread bound and
            // largely un-annotated for Sendable; Swift 5 mode keeps the glue
            // readable. All policy decisions live in QARunnerCore (Swift 6).
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "qa-cli",
            dependencies: ["QARunnerCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "QARunnerCoreTests",
            dependencies: ["QARunnerCore"]
        ),
    ]
)
