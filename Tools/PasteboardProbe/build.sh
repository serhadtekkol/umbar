#!/bin/zsh
# Builds PasteboardProbe.app for spike A2.
#
# usage: build.sh <output-dir> [signing-identity]
#   signing-identity defaults to "-" (ad-hoc). Pass the Developer ID
#   Application identity to reproduce the distribution configuration.
#   Hardened Runtime (--options runtime) is always on, and the app's own
#   boringNotch.entitlements is embedded, so the probe runs under the same
#   runtime/entitlement profile as umbar. That matters: during the
#   pasteboard alert flow on macOS 27.0.1, tccd logged a Hardened Runtime
#   Apple Events denial for a probe signed without
#   com.apple.security.automation.apple-events (spike A2, evidence E3).
#
# Why not an Xcode target: the spike must not touch project.pbxproj while
# other branches edit it, and the harness has to stay out of the app's
# file-system-synchronized boringNotch/ group.
set -euo pipefail
here=${0:A:h}
repo=${here:h:h}
outdir=${1:?output dir}
identity=${2:--}
app=$outdir/PasteboardProbe.app

rm -rf $app
mkdir -p $app/Contents/MacOS
cp $here/Info.plist $app/Contents/Info.plist
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos27.0 \
  -o $app/Contents/MacOS/PasteboardProbe \
  $here/main.swift $repo/boringNotch/private/Clipboard/ClipboardMonitor.swift
codesign --force --options runtime --timestamp=none \
  --entitlements $repo/boringNotch/boringNotch.entitlements --sign "$identity" $app
codesign -dv $app 2>&1 | grep -E "Identifier|Authority|TeamIdentifier|flags|CDHash="
