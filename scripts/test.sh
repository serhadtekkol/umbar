#!/usr/bin/env bash
# Runs the umbar unit tests (target umbarTests) headless.
#
# usage: scripts/test.sh [extra xcodebuild args...]
#   e.g. scripts/test.sh -only-testing:umbarTests/NowPlayingSupervisorTests
#
# Environment:
#   DERIVED_DATA  DerivedData directory (default: build/DerivedData in the repo,
#                 so a run never shares state with Xcode's own DerivedData).
#
# The bundle is hostless: it compiles the app sources it tests (see the
# umbarTests target's Sources phase) instead of launching umbar.app. A hosted
# bundle would start the notch, the Now Playing child and the event tap, and
# read and write the real com.serhadbahadir.umbar defaults and shelf, which
# is the wrong thing for a test run on a machine where umbar is in use.
#
# The scheme is the one Xcode autocreates for the target (.gitignore excludes
# *.xcscheme, so no shared scheme exists). If shared schemes are ever
# committed, commit an "umbarTests" scheme too, or this script loses its scheme.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="${DERIVED_DATA:-$repo/build/DerivedData}"

exec xcodebuild test \
    -project "$repo/boringNotch.xcodeproj" \
    -scheme umbarTests \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    "$@"
