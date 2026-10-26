#!/bin/sh
# Regenerates every derived icon asset from the SVG sources in design/.
#   design/umbar-island.svg, umbar-activity.svg -> boringNotch/AppIcon.icon/Assets/
#   AppIcon.icon (Default, Dark)                 -> logo2.imageset PNGs (512 px)
#   design/umbar-menubar.svg                     -> MenuBarIcon.imageset (template)
# Requires Xcode 27 (Icon Composer's ictool).
set -eu
cd "$(dirname "$0")/.."
ICTOOL="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
cp design/umbar-island.svg boringNotch/AppIcon.icon/Assets/island.svg
cp design/umbar-activity.svg boringNotch/AppIcon.icon/Assets/activity.svg
cp design/umbar-menubar.svg boringNotch/Assets.xcassets/MenuBarIcon.imageset/umbar-menubar.svg
for rendition in Default Dark; do
  suffix=""; [ "$rendition" = Dark ] && suffix="-dark"
  "$ICTOOL" boringNotch/AppIcon.icon --export-image \
    --output-file "boringNotch/Assets.xcassets/logo2.imageset/umbar-icon$suffix.png" \
    --platform macOS --rendition "$rendition" --width 256 --height 256 --scale 2 >/dev/null
done
