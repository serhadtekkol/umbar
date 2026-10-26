#!/usr/bin/env bash
# Integration check for card #57: the Now Playing perl child never outlives
# umbar, however the app ends.
#
# usage: scripts/orphan-check.sh APP [MODE...]
#   APP   path to a built umbar.app (e.g. build/DerivedData/Build/Products/Debug/umbar.app)
#   MODE  quit | TERM | KILL | ABRT | SEGV   (default: quit TERM KILL)
#         quit  = a normal Quit sent to that one pid (NSRunningApplication.terminate)
#         other = kill -MODE; ABRT and SEGV leave a crash report behind, so they
#                 are opt-in.
#
# Environment:
#   HOLD_SECONDS  how long the app runs before it is ended (default 3). The app
#                 must stay up and keep exactly one perl child for that long.
#
# Exit status: 0 every mode passed; 1 an orphan or a duplicate child; 2 no
# child appeared; 3 the app did not start or died during the hold;
# 4 refused to run (see below).
#
# This launches a real app instance, so it is not a unit test and is not run
# by scripts/test.sh. It refuses to run when umbar's first-launch flag is not
# cleared in the app's defaults domain, because a first launch shows
# onboarding. It also refuses, before every mode, when an umbar is already
# running, so it never ends an instance it did not start. Afterwards every pid
# it started is gone, on success, on failure and on Ctrl-C: whatever runs from
# inside APP (the app, its XPC helper, the perl child) is killed on the way
# out. Nothing else is touched.
#
# Ported from Habibe's R2 quitpath.sh regression run.
set -euo pipefail

if [ $# -lt 1 ]; then
    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit 4
fi

# Physical path: LaunchServices starts the executable by its resolved path
# (/private/tmp/..., not /tmp/...), and that is what ps shows (card #120).
app="$(cd "$1" && pwd -P)"
shift
modes=("$@")
[ ${#modes[@]} -eq 0 ] && modes=(quit TERM KILL)
hold="${HOLD_SECONDS:-3}"

exe="$app/Contents/MacOS/umbar"
[ -x "$exe" ] || { echo "not an umbar.app: $app" >&2; exit 4; }
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"

first_launch="$(defaults read "$bundle_id" firstLaunch 2>/dev/null || echo unset)"
if [ "$first_launch" != "0" ]; then
    echo "refusing: '$bundle_id' firstLaunch is '$first_launch', a launch would show onboarding." >&2
    echo "set it with: defaults write $bundle_id firstLaunch -bool false" >&2
    exit 4
fi
umbar_running() {
    pgrep -f '/umbar\.app/Contents/MacOS/umbar$' >/dev/null
}
if umbar_running; then
    echo "refusing: an umbar is already running; quit it first." >&2
    exit 4
fi

# Passed through the environment, not as awk arguments, so the awk process's
# own command line never contains the path it is looking for.
export ORPHAN_CHECK_EXE="$exe" ORPHAN_CHECK_CONTENTS="$app/Contents/"

# Every process running from inside this copy of the app: the app, its XPC
# helper and the perl child, whose command line names the bundled script. The
# perl child is found by path, not by parent, so it is found after the app
# died and it was reparented to launchd. Nothing outside APP can match, and the
# guard above makes sure no app from it was running before this script started.
procs_from_app() {
    ps -axo pid=,command= | awk 'index($0, ENVIRON["ORPHAN_CHECK_CONTENTS"]) { print $1 }'
}

# Kills everything procs_from_app finds and waits for it to go. Runs after
# every mode and on exit, so no path out of this script leaves a pid behind.
reap() {
    local pids
    pids="$(procs_from_app | xargs)"
    [ -z "$pids" ] && return 0
    kill -9 $pids 2>/dev/null || true
    for _ in $(seq 1 25); do [ -z "$(procs_from_app)" ] && return 0; sleep 0.2; done
    echo "could not end: $(procs_from_app | xargs)" >&2
    return 1
}

# A pid-targeted Quit. `osascript ... quit` would address the bundle id, i.e.
# possibly another copy of umbar.
work="$(mktemp -d "${TMPDIR:-/tmp}/umbar-orphan-check.XXXXXX")"
trap 'reap || true; rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cat > "$work/quitpid.swift" <<'SWIFT'
import AppKit
guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: pid) else { exit(2) }
exit(app.terminate() ? 0 : 1)
SWIFT
swiftc -O -o "$work/quitpid" "$work/quitpid.swift"

perl_children() {   # perl adapter children of pid $1, one pid per line
    ps -axo pid=,ppid=,command= |
        awk -v p="$1" '$2 == p && /\/usr\/bin\/perl/ && /mediaremote-adapter\.pl/ { print $1 }'
}

app_pid() {   # the app itself: command line is exactly the executable path
    ps -axo pid=,command= |
        awk '{ pid = $1; sub(/^ *[0-9]+ /, ""); if ($0 == ENVIRON["ORPHAN_CHECK_EXE"]) { print pid; exit } }'
}

run_mode() {
    local mode="$1" pid="" kids="" n left=""
    open -n "$app"
    for _ in $(seq 1 50); do pid="$(app_pid)"; [ -n "$pid" ] && break; sleep 0.2; done
    [ -z "$pid" ] && { echo "[$mode] app did not start (left behind: [$(procs_from_app | xargs)])"; return 3; }

    for _ in $(seq 1 75); do kids="$(perl_children "$pid")"; [ -n "$kids" ] && break; sleep 0.2; done
    sleep "$hold"
    if ! ps -p "$pid" >/dev/null; then echo "[$mode] app $pid died during the ${hold}s hold"; return 3; fi
    kids="$(perl_children "$pid")"
    n="$(printf '%s\n' "$kids" | grep -c . || true)"
    helper="$(pgrep -f "$app/Contents/XPCServices/.*\.xpc/Contents/MacOS/" | xargs || true)"
    echo "[$mode] app pid=$pid helper=[${helper}] perl children=$n [$(echo $kids)] after ${hold}s"
    if [ "$n" = 0 ]; then kill -9 "$pid"; echo "[$mode] no perl child"; return 2; fi
    if [ "$n" != 1 ]; then
        kill -9 "$pid"; for k in $kids; do kill -9 "$k" 2>/dev/null || true; done
        echo "[$mode] expected exactly one perl child"; return 1
    fi

    case "$mode" in
        quit) "$work/quitpid" "$pid" ;;
        *)    kill "-$mode" "$pid" ;;
    esac
    for _ in $(seq 1 25); do ps -p "$pid" >/dev/null || break; sleep 0.2; done
    if ps -p "$pid" >/dev/null; then echo "[$mode] app $pid still alive after 5 s, killing it"; kill -9 "$pid"; fi
    # The child polls for its parent (UmbarParentWatchdog.m); give it a moment.
    sleep 2
    for k in $kids; do ps -p "$k" >/dev/null && left="$left $k(ppid=$(ps -o ppid= -p "$k" | tr -d ' '))"; done
    if [ -n "$left" ]; then
        echo "[$mode] ORPHAN:$left"
        for k in $kids; do kill -9 "$k" 2>/dev/null || true; done
        return 1
    fi
    echo "[$mode] ok: app and child gone"
}

# The helper is launchd's to end once its client is gone; it is not what this
# check is about, so a slow one is reported, not failed, and then ended.
after_mode() {
    local mode="$1" rest
    rest="$(procs_from_app | xargs)"
    [ -n "$rest" ] && echo "[$mode] ending what is still running from the app: [$rest]"
    reap
}

for mode in "${modes[@]}"; do
    case "$mode" in quit|TERM|KILL|ABRT|SEGV) ;; *) echo "unknown mode: $mode" >&2; exit 4 ;; esac
done

status=0
for mode in "${modes[@]}"; do
    # Someone may have started an umbar since the last mode; ending it with
    # the next mode's cleanup would end an instance this script did not start.
    if umbar_running; then
        echo "[$mode] refusing: an umbar is running that this script did not start" >&2
        [ "$status" = 0 ] && status=4
        break
    fi
    rc=0; run_mode "$mode" || rc=$?
    if ! after_mode "$mode" && [ "$rc" = 0 ]; then rc=1; fi
    # The first failure decides the exit status; later modes still run.
    [ "$status" = 0 ] && status=$rc
done
exit "$status"
