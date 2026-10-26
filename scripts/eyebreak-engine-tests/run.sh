#!/bin/sh
# Compiles the pure engine with the harness and runs it. Needs only swiftc.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
out="${TMPDIR:-/tmp}/eyebreak-engine-tests"
swiftc -o "$out" "$here/../../boringNotch/private/EyeBreak/EyeBreakEngine.swift" "$here/main.swift"
"$out"
