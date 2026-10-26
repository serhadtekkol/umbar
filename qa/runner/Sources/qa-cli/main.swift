//
//  qa-cli — socket client for UmbarQARunner (docs/qa-gui-runner.md §3.3).
//
//  Runs over SSH as the test account and needs no TCC grant: it only writes
//  one JSON line to the runner's socket and prints the answer. It cannot
//  arm the runner; there is no arm command in the protocol.
//
//  usage: qa-cli <command> [key=value ...]
//         qa-cli capture <notch|shelf|hud|finder-drop|app>
//
//  Values are sent as JSON integers when they are all digits, as booleans
//  for true/false, and as strings otherwise. The runner validates
//  everything; qa-cli validates locally too only to fail fast.
//
//  Exit status: 0 ok, 2 refused, 64 usage error, 69 runner not reachable.
//

import Darwin
import Foundation
import QARunnerCore

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let usage = """
usage: qa-cli <command> [key=value ...]
       qa-cli capture <notch|shelf|hud|finder-drop|app>
commands: status [windows=true], version, disarm, capture.app, capture.region name=,
  capture.alert name=, record.start target= [max_s=], record.stop, ax.tree target= [depth=],
  pointer.hover target= [dwell_ms=], pointer.click target=umbar:<id>, drag from= to=,
  finder.open-drop folder=, key name=, media-key name=, measure.hover-expand target=notch [runs=]
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let first = args.first, first != "-h", first != "--help" else { fail(usage, 64) }

// Shorthand from the design's example (`qa-cli capture notch`).
if first == "capture", args.count == 2 {
    args = args[1] == "app" ? ["capture.app"] : ["capture.region", "name=\(args[1])"]
}

var object: [String: WireValue] = ["cmd": .string(args[0])]
for pair in args.dropFirst() {
    guard let eq = pair.firstIndex(of: "=") else { fail("not key=value: \(pair)\n" + usage, 64) }
    let key = String(pair[..<eq]), raw = String(pair[pair.index(after: eq)...])
    let value: WireValue
    if raw == "true" { value = .bool(true) }
    else if raw == "false" { value = .bool(false) }
    else if !raw.isEmpty, raw.allSatisfy(\.isASCII), raw.allSatisfy(\.isNumber), let n = Int(raw) { value = .int(n) }
    else { value = .string(raw) }
    guard object[key] == nil else { fail("duplicate key: \(key)", 64) }
    object[key] = value
}

if case .failure(let refusal) = Command.parse(object: object) {
    print(#"{"ok":false,"refused":"\#(refusal.description)","local":true}"#)
    exit(2)
}
let line: String
switch StrictJSON.encodeObject(object) {
case .success(let s): line = s + "\n"
case .failure(let refusal): fail("cannot encode request: \(refusal)", 64)
}

let realHome = DropArea.realpath(NSHomeDirectory()) ?? NSHomeDirectory()
let paths = RunnerPaths(realHome: realHome)
guard paths.socketPathFits else { fail("socket path too long", 69) }

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { fail("socket: \(String(cString: strerror(errno)))", 69) }
var one: Int32 = 1
setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(paths.socketPath.utf8)
withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    buf.copyBytes(from: pathBytes)
    buf[pathBytes.count] = 0
}
addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
let connected = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard connected == 0 else { fail("runner not reachable at \(paths.socketPath): \(String(cString: strerror(errno)))", 69) }

let bytes = Array(line.utf8)
var offset = 0
while offset < bytes.count {
    let n = bytes[offset...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    guard n > 0 else { fail("write failed", 69) }
    offset += n
}

// Long commands (measure.hover-expand with 20 runs) take up to ~90 s, so
// the read timeout is generous; the runner bounds every command itself.
var tv = timeval(tv_sec: 180, tv_usec: 0)
setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
var response = Data()
var buf = [UInt8](repeating: 0, count: 65536)
while true {
    let n = read(fd, &buf, buf.count)
    if n <= 0 { break }
    response.append(contentsOf: buf[0..<n])
}
close(fd)

// An empty answer means the runner closed without replying, which is what
// it does to a peer of the wrong UID.
guard !response.isEmpty else { fail("no response from runner", 69) }
FileHandle.standardOutput.write(response)
let ok = response.starts(with: Data(#"{"ok":true"#.utf8))
exit(ok ? 0 : 2)
