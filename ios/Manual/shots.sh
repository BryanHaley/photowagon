#!/bin/sh
# Makes images/*.jpg from ManualScreenshotsTests' result bundle:
#   TEST_RUNNER_MANUAL_SHOTS=1 xcodebuild … -resultBundlePath <bundle> test-without-building \
#     -only-testing:PhotoWagonUITests/ManualScreenshotsTests
#   ./shots.sh <bundle>
# Needs ImageMagick. Pictures are iPhone 16 Pro screenshots (1206 × 2622).
set -eu
cd "$(dirname "$0")"
work=$(mktemp -d)
xcrun xcresulttool export attachments --path "$1" --output-path "$work" > /dev/null
python3 -I - "$work" <<'PY' | while read -r file name; do
import json, sys
for test in json.load(open(sys.argv[1] + "/manifest.json")):
    for a in test["attachments"]:
        name = a.get("suggestedHumanReadableName", "").split("_0_")[0]
        if a["exportedFileName"].endswith(".png") and not name.startswith(("UI Snapshot", "Screen", "App UI")):
            print(a["exportedFileName"], name)
PY
  case "$name" in
    # Just the bottom bars.
    tool-group|options-bar|ai-remove) crop=1206x420+0+2120 ;;
    # The screen without the status bar and the home bar.
    *) crop=1206x2420+0+130 ;;
  esac
  magick "$work/$file" -crop "$crop" +repage -resize 360x -strip -quality 62 "images/$name.jpg"
done
rm -rf "$work"
du -ch images/*.jpg | tail -1
