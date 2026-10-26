#!/usr/bin/env bash
# Tests for scripts/ci-xcode-gate.sh against fake projects and fake Xcode
# installs in a temporary directory. Nothing outside that directory is read
# except /usr/libexec/PlistBuddy, so it runs the same on a laptop and in CI.
#
# usage: scripts/ci-xcode-gate-test.sh
# Exit status: 0 all cases passed; 1 at least one failed.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gate="$repo/scripts/ci-xcode-gate.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# fake_xcode DIR VERSION: an Xcode.app shell with just Contents/version.plist.
fake_xcode() {
    mkdir -p "$1/Contents/Developer"
    cat >"$1/Contents/version.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleShortVersionString</key>
	<string>$2</string>
</dict>
</plist>
PLIST
}

# fake_project FILE TARGET...: a pbxproj fragment with one line per target.
fake_project() {
    local file="$1"
    shift
    : >"$file"
    for t in "$@"; do
        printf '\t\t\t\tMACOSX_DEPLOYMENT_TARGET = %s;\n' "$t" >>"$file"
    done
}

# check NAME EXPECTED_STATUS EXPECTED_SUBSTRING... -- runs the gate with the
# environment already exported by the caller.
check() {
    local name="$1" want_status="$2"
    shift 2
    local out status=0
    out="$(env -u GITHUB_ACTIONS -u GITHUB_OUTPUT -u GITHUB_ENV -u GITHUB_STEP_SUMMARY \
        "$gate" 2>&1)" || status=$?
    if [ "$status" -ne "$want_status" ]; then
        echo "FAIL $name: exit $status, want $want_status"
        printf '%s\n' "$out" | sed 's/^/    /'
        failures=$((failures + 1))
        return
    fi
    for want in "$@"; do
        if ! printf '%s\n' "$out" | grep -qF -- "$want"; then
            echo "FAIL $name: output lacks '$want'"
            printf '%s\n' "$out" | sed 's/^/    /'
            failures=$((failures + 1))
            return
        fi
    done
    echo "ok   $name"
}

# Each case gets its own directory so no state leaks between cases.
setup() {
    case_name="$1"
    case_dir="$work/$1"
    mkdir -p "$case_dir/Applications"
    export UMBAR_PBXPROJ="$case_dir/project.pbxproj"
    export XCODE_SEARCH_DIR="$case_dir/Applications"
    export UMBAR_GATE_HOST_VERSION="27.0.1"
    export UMBAR_GATE_CURRENT_DEVELOPER_DIR="$case_dir/none"
    unset UMBAR_CI_STRICT
    fake_project "$UMBAR_PBXPROJ" 27.0
}

setup default-xcode-is-new-enough
fake_xcode "$XCODE_SEARCH_DIR/Xcode.app" 27.0
fake_xcode "$XCODE_SEARCH_DIR/Xcode_28.0.app" 28.0
UMBAR_GATE_CURRENT_DEVELOPER_DIR="$XCODE_SEARCH_DIR/Xcode.app/Contents/Developer"
check "$case_name" 0 "ready=true" "developer_dir=$XCODE_SEARCH_DIR/Xcode.app/Contents/Developer"

setup default-too-old-picks-newest-installed
fake_xcode "$XCODE_SEARCH_DIR/Xcode.app" 26.6
fake_xcode "$XCODE_SEARCH_DIR/Xcode_27.0.app" 27.0
fake_xcode "$XCODE_SEARCH_DIR/Xcode_27.1.app" 27.1
UMBAR_GATE_CURRENT_DEVELOPER_DIR="$XCODE_SEARCH_DIR/Xcode.app/Contents/Developer"
check "$case_name" 0 "ready=true" "developer_dir=$XCODE_SEARCH_DIR/Xcode_27.1.app/Contents/Developer"

setup newer-major-is-accepted
fake_xcode "$XCODE_SEARCH_DIR/Xcode_28.0.app" 28.0
check "$case_name" 0 "ready=true" "Xcode_28.0.app"

setup no-xcode-new-enough-skips
fake_xcode "$XCODE_SEARCH_DIR/Xcode_26.6.app" 26.6
check "$case_name" 0 "ready=false" "no Xcode 27 or later"

setup no-xcode-at-all-skips
check "$case_name" 0 "ready=false" "no Xcode 27 or later"

setup host-too-old-skips
fake_xcode "$XCODE_SEARCH_DIR/Xcode_27.0.app" 27.0
UMBAR_GATE_HOST_VERSION="26.6"
check "$case_name" 0 "ready=false" "host is macOS 26.6"

setup strict-fails-when-not-ready
UMBAR_CI_STRICT=1
export UMBAR_CI_STRICT
check "$case_name" 1 "ready=false"

setup highest-deployment-target-wins
fake_project "$UMBAR_PBXPROJ" 26.0 27.0 15.4
fake_xcode "$XCODE_SEARCH_DIR/Xcode_26.6.app" 26.6
check "$case_name" 0 "ready=false" "targets macOS 27"

setup missing-deployment-target-is-an-error
: >"$UMBAR_PBXPROJ"
check "$case_name" 2 "no MACOSX_DEPLOYMENT_TARGET"

setup missing-project-is-an-error
rm -f "$UMBAR_PBXPROJ"
check "$case_name" 2 "project file not found"

setup github-actions-outputs
fake_xcode "$XCODE_SEARCH_DIR/Xcode_27.0.app" 27.0
gh_out="$case_dir/output" gh_env="$case_dir/env"
GITHUB_ACTIONS=true GITHUB_OUTPUT="$gh_out" GITHUB_ENV="$gh_env" "$gate" >/dev/null
if grep -qx "ready=true" "$gh_out" &&
    grep -qx "DEVELOPER_DIR=$XCODE_SEARCH_DIR/Xcode_27.0.app/Contents/Developer" "$gh_env"; then
    echo "ok   github-actions-outputs"
else
    echo "FAIL github-actions-outputs"
    sed 's/^/    /' "$gh_out" "$gh_env" 2>/dev/null || true
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures case(s) failed"
    exit 1
fi
echo "all cases passed"
