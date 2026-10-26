#!/usr/bin/env bash
# CI build of the boringNotch scheme (product umbar.app): resolve Swift
# packages strictly from the committed Package.resolved, then build Debug
# without code signing.
#
# usage: scripts/ci-build.sh [extra xcodebuild build args...]
#
# Environment:
#   DERIVED_DATA  DerivedData directory (default: build/DerivedData in the repo,
#                 the same default as scripts/test.sh, so the test run reuses
#                 the packages resolved here).
#
# Why -onlyUsePackageVersionsFromResolvedFile: the project's package
# requirements are ranges (upToNextMajor), so a plain resolve may pick a newer
# version than the one reviewed in Package.resolved. With the flag, xcodebuild
# fails instead of moving a pin, and the git diff check below fails if the file
# was rewritten anyway. A dependency change therefore always arrives as a
# reviewed Package.resolved diff (card #48).
#
# Why CODE_SIGNING_ALLOWED=NO: CI holds no certificates by design. Signing,
# notarization and DMG packaging happen on the release Mac (card #27), never
# here.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="${DERIVED_DATA:-$repo/build/DerivedData}"
project="$repo/boringNotch.xcodeproj"
resolved="boringNotch.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

xcodebuild -resolvePackageDependencies \
    -project "$project" \
    -scheme boringNotch \
    -derivedDataPath "$derived_data" \
    -onlyUsePackageVersionsFromResolvedFile

if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if ! git -C "$repo" diff --exit-code -- "$resolved"; then
        echo "ci-build: package resolution rewrote $resolved; commit the reviewed change instead" >&2
        exit 1
    fi
fi

xcodebuild build \
    -project "$project" \
    -scheme boringNotch \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    -onlyUsePackageVersionsFromResolvedFile \
    CODE_SIGNING_ALLOWED=NO \
    "$@"
