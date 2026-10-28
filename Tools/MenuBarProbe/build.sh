#!/bin/zsh
# Builds MenuBarProbe.app for spike C4 (card #107).
#
# usage: build.sh <output-dir> [signing-identity]
#   signing-identity defaults to "-" (ad-hoc). Hardened Runtime and umbar's
#   own boringNotch.entitlements are embedded, as for PasteboardProbe, so
#   TCC sees the same runtime/entitlement profile as the app.
#
# Why an .app launched with `open` instead of a bare CLI: TCC attributes a
# CLI's Screen Recording / Accessibility checks to its responsible process
# (Terminal, sshd), which may hold grants the app never will. Launched by
# launchd, the probe is its own responsible process with no grants at all,
# which is exactly umbar's state on a fresh install.
#
# Why not an Xcode target: the spike must not touch project.pbxproj while
# other branches edit it.
set -euo pipefail
here=${0:A:h}
repo=${here:h:h}
outdir=${1:?output dir}
identity=${2:--}
app=$outdir/MenuBarProbe.app

rm -rf $app
mkdir -p $app/Contents/MacOS
cp $here/Info.plist $app/Contents/Info.plist
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos27.0 \
  -o $app/Contents/MacOS/MenuBarProbe \
  $here/main.swift $repo/boringNotch/private/MenuBarGeometry/MenuBarCollision.swift
codesign --force --options runtime --timestamp=none \
  --entitlements $repo/boringNotch/boringNotch.entitlements --sign "$identity" $app
codesign -dv $app 2>&1 | grep -E "Identifier|flags|CDHash="
