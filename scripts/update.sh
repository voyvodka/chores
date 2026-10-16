#!/bin/bash
# Run by Chores.app from its own clone (~/.local/share/chores/source) after it checked out a release
# tag: builds that tag, waits until no job is running (re-registering the scheduler stops running
# jobs), installs it, records the outcome for the app, and reopens the app either way.
#   update.sh <tag>
set -uo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: update.sh <tag>}"
ROOT="$HOME/.local/share/chores"
STATE="$ROOT/update-state.json"
APP="$HOME/Applications/Chores.app"
RUNNER="$HOME/.local/bin/chores"
STARTED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

finish() {
  local ok=$1 message=$2
  printf '{"tag":"%s","ok":%s,"message":"%s","startedAt":"%s","finishedAt":"%s"}\n' \
    "$TAG" "$ok" "$message" "$STARTED" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STATE.tmp" &&
    command mv -f "$STATE.tmp" "$STATE"
  open "$APP"
  exit 0
}

echo "== $(date) updating to $TAG"
# Build first, while the old app and scheduler keep working; install.sh's own build is then a no-op.
swift build -c release --product chores && swift build -c release --product ChoresApp ||
  finish false "build failed"

for _ in $(seq 1 180); do
  "$RUNNER" list 2>/dev/null | grep -q '\[running\]' || break
  sleep 10
done
if "$RUNNER" list 2>/dev/null | grep -q '\[running\]'; then
  finish false "a job was still running after 30 minutes"
fi

scripts/install.sh --no-launch || finish false "install failed"
finish true ""
