#!/bin/bash
# Compiles assets/Chores.icon (an Icon Composer document) into assets/prebuilt/, which install.sh
# copies into the bundle. The output is committed because actool's support for .icon files varies
# between Xcode 26 releases, and every self-update builds on whatever Xcode that Mac has.
# Run it after changing the icon, then commit assets/prebuilt/.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
OUT=$(mktemp -d)
trap 'command rm -rf "$OUT"' EXIT
xcrun actool "$ROOT/assets/Chores.icon" --compile "$OUT" \
  --app-icon Chores --enable-on-demand-resources NO --development-region en \
  --target-device mac --platform macosx --minimum-deployment-target 26.0 \
  --output-partial-info-plist "$OUT/partial.plist" --output-format human-readable-text --errors --warnings
mkdir -p assets/prebuilt
command cp -f "$OUT/Assets.car" "$OUT/Chores.icns" assets/prebuilt/
echo "wrote assets/prebuilt/Assets.car and Chores.icns"
