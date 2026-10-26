#!/usr/bin/env bash
# Decides whether this Mac can build and test umbar, and picks the Xcode for it.
#
# usage: scripts/ci-xcode-gate.sh
#
# The requirement is read from the project, not hard-coded: the highest
# MACOSX_DEPLOYMENT_TARGET in boringNotch.xcodeproj sets the major version N.
# Building needs an Xcode whose major version is at least N (since Xcode 26 the
# Xcode major and the macOS SDK major are the same number), and running the
# umbarTests bundle needs a host on macOS N or later, because a test bundle
# whose minimum OS is above the host's does not load.
#
# The Xcode is chosen in this order: the one xcode-select points at, if it is
# new enough (that is the runner image's default), otherwise the newest
# /Applications/Xcode*.app that is. The choice is exported as DEVELOPER_DIR,
# which xcodebuild honours, so no sudo xcode-select is needed.
#
# Output: key=value lines on stdout (ready, reason, developer_dir). Under
# GitHub Actions the same lines go to $GITHUB_OUTPUT, DEVELOPER_DIR goes to
# $GITHUB_ENV, and a "not ready" result is raised as a ::warning:: and written
# to the job summary, so a skipped build is visible rather than a quiet green.
#
# Environment:
#   UMBAR_CI_STRICT    "1" or "true": exit 1 when not ready instead of 0. Set it
#                      (repository variable UMBAR_CI_STRICT) once the runner is
#                      known to carry the toolchain, so a missing Xcode fails CI.
#   UMBAR_PBXPROJ      project file to read (default: the repo's).
#   XCODE_SEARCH_DIR   where to look for Xcode*.app (default /Applications).
#   UMBAR_GATE_HOST_VERSION, UMBAR_GATE_CURRENT_DEVELOPER_DIR
#                      stand in for sw_vers and xcode-select; for
#                      scripts/ci-xcode-gate-test.sh only.
#
# Exit status: 0 a decision was made (ready or, when not strict, not ready);
# 1 not ready and UMBAR_CI_STRICT is set; 2 the project could not be read.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pbxproj="${UMBAR_PBXPROJ:-$repo/boringNotch.xcodeproj/project.pbxproj}"
search_dir="${XCODE_SEARCH_DIR:-/Applications}"
plistbuddy=/usr/libexec/PlistBuddy

major() { printf '%s\n' "${1%%.*}"; }

# Prints the CFBundleShortVersionString of an Xcode.app, or nothing if the path
# is not an Xcode. version.plist is read instead of running xcodebuild so a
# candidate is never launched (first launch can trigger component installs).
xcode_version() {
    local plist="$1/Contents/version.plist"
    [ -f "$plist" ] || return 0
    "$plistbuddy" -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true
}

emit() {
    printf '%s=%s\n' "$1" "$2"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
    fi
}

not_ready() {
    emit ready false
    emit reason "$1"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::warning title=umbar CI skipped::$1"
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
            printf '### Build and tests skipped\n\n%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
        fi
    fi
    case "${UMBAR_CI_STRICT:-}" in
        1 | true) exit 1 ;;
        *) exit 0 ;;
    esac
}

if [ ! -f "$pbxproj" ]; then
    echo "ci-xcode-gate: project file not found: $pbxproj" >&2
    exit 2
fi

required="$(sed -n 's/.*MACOSX_DEPLOYMENT_TARGET = \([0-9][0-9]*\)[.0-9]*;.*/\1/p' "$pbxproj" |
    sort -n | tail -n 1)"
if [ -z "$required" ]; then
    echo "ci-xcode-gate: no MACOSX_DEPLOYMENT_TARGET in $pbxproj" >&2
    exit 2
fi

host_version="${UMBAR_GATE_HOST_VERSION:-$(sw_vers -productVersion)}"
if [ "$(major "$host_version")" -lt "$required" ]; then
    not_ready "host is macOS $host_version; the project targets macOS $required, so its tests cannot run here"
fi

current_dev="${UMBAR_GATE_CURRENT_DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
chosen=""
chosen_version=""

# xcode-select -p gives <app>/Contents/Developer; the app is two levels up.
if [ -n "$current_dev" ]; then
    current_app="$(cd "$current_dev/../.." 2>/dev/null && pwd || true)"
    v="$(xcode_version "$current_app")"
    if [ -n "$v" ] && [ "$(major "$v")" -ge "$required" ]; then
        chosen="$current_app"
        chosen_version="$v"
    fi
fi

if [ -z "$chosen" ]; then
    best_major=-1
    best_minor=-1
    for app in "$search_dir"/Xcode*.app; do
        [ -d "$app" ] || continue
        v="$(xcode_version "$app")"
        [ -n "$v" ] || continue
        m="$(major "$v")"
        rest="${v#*.}"
        [ "$rest" = "$v" ] && rest=0
        n="${rest%%.*}"
        [ "$m" -ge "$required" ] || continue
        if [ "$m" -gt "$best_major" ] || { [ "$m" -eq "$best_major" ] && [ "$n" -gt "$best_minor" ]; }; then
            best_major="$m"
            best_minor="$n"
            chosen="$app"
            chosen_version="$v"
        fi
    done
fi

if [ -z "$chosen" ]; then
    not_ready "no Xcode $required or later on this runner (looked at xcode-select and $search_dir/Xcode*.app); the project targets macOS $required"
fi

developer_dir="$chosen/Contents/Developer"
emit ready true
emit reason "Xcode $chosen_version on macOS $host_version (project targets macOS $required)"
emit developer_dir "$developer_dir"
if [ -n "${GITHUB_ENV:-}" ]; then
    printf 'DEVELOPER_DIR=%s\n' "$developer_dir" >>"$GITHUB_ENV"
fi
