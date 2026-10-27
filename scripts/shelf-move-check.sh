#!/usr/bin/env bash
# Runs ShelfDragOutVolumeTests (BR-3.5, AC-3.12, AC-3.20) and
# ShelfMoveUndoVolumeTests (undo of a cross-volume move, card #100) against
# real volumes: a writable APFS disk image as the "other disk", and a
# read-only disk image as an undeletable source.
#
# usage: scripts/shelf-move-check.sh [work-dir]
#   work-dir  where the images and mount points go (default: a new mktemp
#             directory). Everything the script creates is under it and is
#             detached and removed on exit, also on failure or Ctrl-C.
#
# The images are attached with -nobrowse, so they do not show up in Finder's
# sidebar or on the desktop. Nothing outside work-dir and the repo's
# build/DerivedData is touched.
#
# What this does not cover: the drag itself. A script cannot drag with the
# mouse, so Finder's own cross-volume move (copy, then delete the source) is
# stood in for by FileManager.moveItem. The hand-test list on card #93 covers
# real drags.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${1:-$(mktemp -d -t umbar-shelf-move)}"
mkdir -p "$work"
rw_img="$work/rw.dmg"
ro_img="$work/ro.dmg"
rw_mnt="$work/mnt-rw"
ro_mnt="$work/mnt-ro"
ro_src="$work/ro-src"

cleanup() {
    for mnt in "$rw_mnt" "$ro_mnt"; do
        if mount | grep -q " on $mnt "; then
            hdiutil detach "$mnt" -quiet || hdiutil detach "$mnt" -force -quiet || true
        fi
    done
    rm -rf "$work"
}
trap cleanup EXIT

hdiutil create -quiet -size 64m -fs APFS -volname umbarShelfRW "$rw_img"
mkdir -p "$ro_src" "$rw_mnt" "$ro_mnt"
head -c 65536 /dev/urandom > "$ro_src/readonly.bin"
# UDZO images are read-only by format, like a downloaded app's DMG.
hdiutil create -quiet -srcfolder "$ro_src" -format UDZO -volname umbarShelfRO "$ro_img"

hdiutil attach -quiet -nobrowse -mountpoint "$rw_mnt" "$rw_img"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$ro_mnt" "$ro_img"
echo "attached: $rw_mnt (rw), $ro_mnt (ro)"

log="$work/test.log"
set +e
TEST_RUNNER_UMBAR_SHELF_RW_VOLUME="$rw_mnt" \
TEST_RUNNER_UMBAR_SHELF_RO_VOLUME="$ro_mnt" \
    "$repo/scripts/test.sh" \
        -only-testing:umbarTests/ShelfDragOutVolumeTests \
        -only-testing:umbarTests/ShelfMoveUndoVolumeTests > "$log" 2>&1
status=$?
set -e

grep -E "ShelfDragOutVolumeTests|ShelfMoveUndoVolumeTests|Test run with|TEST (SUCCEEDED|FAILED)" "$log" || true
if [[ $status -ne 0 ]]; then
    echo "FAIL: xcodebuild exited $status (log tail below)"
    tail -40 "$log"
    exit "$status"
fi
# A suite that was skipped (environment not passed through) would also exit
# 0; every test of both suites must have run. Only test-case lines count: a
# build that recompiles prints unrelated "skipped" notes.
expected=9
passed=$(grep -cE "Test case '(ShelfDragOutVolumeTests|ShelfMoveUndoVolumeTests)/.*' passed" "$log")
if grep -qE "Test case '.*' skipped" "$log" || [[ $passed -ne $expected ]]; then
    echo "FAIL: $passed of $expected volume tests ran and passed"
    exit 1
fi
echo "PASS: $expected volume tests ran and passed"
