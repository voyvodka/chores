#!/bin/bash
# Builds and installs the runner (~/.local/bin/chores) and the app (~/Applications/Chores.app),
# then relaunches the app. --runner-only skips the app; --no-launch installs without opening it.
set -euo pipefail

LAUNCH=1
if [[ "${1:-}" == "--no-launch" ]]; then LAUNCH=0; shift; fi

cd "$(dirname "$0")/.."
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Chores.app"
BUNDLE_ID="dev.voyvodka.chores"

swift build -c release --product chores
mkdir -p "$BIN_DIR"
# Replace via rename: overwriting the binary in place while launchd runs it can crash that run.
command cp -f .build/release/chores "$BIN_DIR/.chores.new"
command mv -f "$BIN_DIR/.chores.new" "$BIN_DIR/chores"
echo "installed runner: $BIN_DIR/chores"

[[ "${1:-}" == "--runner-only" ]] && exit 0

swift build -c release --product ChoresApp
STAGE=$(mktemp -d)
trap 'command rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/Chores.app"
mkdir -p "$BUNDLE/Contents/MacOS"
command cp -f .build/release/ChoresApp "$BUNDLE/Contents/MacOS/ChoresApp"
# The runner also lives in the bundle: the scheduler agent must run a program inside the app to be
# listed under Chores in System Settings › Login Items.
command cp -f .build/release/chores "$BUNDLE/Contents/MacOS/chores"
# The string catalog compiles into SwiftPM's resource bundle; SwiftUI reads strings from the main
# bundle, so its .lproj folders go straight into Contents/Resources. en.lproj stays empty: English
# is the source language, but macOS lists only localizations that exist as folders.
mkdir -p "$BUNDLE/Contents/Resources/en.lproj"
command cp -R .build/release/Chores_ChoresApp.bundle/Contents/Resources/*.lproj "$BUNDLE/Contents/Resources/"
mkdir -p "$BUNDLE/Contents/Library/LaunchAgents"
cat >"$BUNDLE/Contents/Library/LaunchAgents/dev.voyvodka.chores.scheduler.plist" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.voyvodka.chores.scheduler</string>
  <key>BundleProgram</key><string>Contents/MacOS/chores</string>
  <key>ProgramArguments</key><array><string>chores</string><string>scheduler</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>AssociatedBundleIdentifiers</key><array><string>$BUNDLE_ID</string></array>
</dict>
</plist>
AGENT
# The self-updater reads these back: the release this build came from, its commit, and where to
# fetch newer releases from.
DESCRIBE=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
if [[ $DESCRIBE =~ ^v([0-9]+\.[0-9]+\.[0-9]+) ]]; then VERSION=${BASH_REMATCH[1]}; else VERSION=0.0.0; fi
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
ORIGIN=$(git remote get-url origin 2>/dev/null || echo "")
cat >"$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Chores</string>
  <key>CFBundleDisplayName</key><string>Chores</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
  <key>CFBundleExecutable</key><string>ChoresApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>ChoresVersion</key><string>$DESCRIBE</string>
  <key>ChoresCommit</key><string>$COMMIT</string>
  <key>ChoresSourceRepository</key><string>$ORIGIN</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$BUNDLE/Contents/MacOS/chores"
codesign --force --sign - "$BUNDLE"

# -a: during a self-update this script descends from the app, and pkill skips its own ancestors.
pkill -a -x ChoresApp 2>/dev/null || true
mkdir -p "$APP_DIR"
# Keep the old bundle until the new one is in place, so a failed move leaves a working app.
OLD="$STAGE/Chores.old.app"
[[ -e "$APP" ]] && command mv -f "$APP" "$OLD"
if ! command mv -f "$BUNDLE" "$APP"; then
  [[ -e "$OLD" ]] && command mv -f "$OLD" "$APP"
  echo "install failed: could not move the new bundle into place; previous app restored" >&2
  exit 1
fi
# Notifications are refused to bundles LaunchServices does not know about.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "installed app: $APP"

# The scheduler agent lives in the bundle. A replaced bundle has a new signature, which launchd
# refuses to spawn (EX_CONFIG) under the old registration, so register it afresh (no UI). Right
# after the bundle is replaced even a fresh registration can still end in EX_CONFIG until the
# system has caught up with the new signature, so retry until launchd reports it running.
SERVICE="gui/$(id -u)/dev.voyvodka.chores.scheduler"
scheduler_running() { launchctl print "$SERVICE" 2>/dev/null | grep -q 'job state = running'; }
for attempt in 1 2 3 4; do
  "$APP/Contents/MacOS/ChoresApp" --unregister-scheduler >/dev/null
  sleep 3
  "$APP/Contents/MacOS/ChoresApp" --register-scheduler >/dev/null
  for _ in {1..10}; do
    scheduler_running && break 2
    sleep 1
  done
  echo "scheduler agent not running yet (attempt $attempt), registering again" >&2
  sleep $((attempt * 5))
done
if ! scheduler_running; then
  echo "scheduler agent is not running; run install.sh again or use Start in the menu" >&2
  exit 1
fi
echo "scheduler agent running"
[[ $LAUNCH == 1 ]] && open "$APP" --args "$@"
exit 0
