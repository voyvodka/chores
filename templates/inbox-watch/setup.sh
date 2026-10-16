#!/bin/bash
# Installs the inbox-watch job into Chores and connects it to Gmail and Claude.
# Safe to re-run: it refreshes the template files, keeps config.json, state.json and rules.md.
#   setup.sh                    first install, or update after pulling the repo
#   setup.sh --reconnect        sign in to Gmail again (password changed, access revoked)
#   setup.sh --client FILE      replace the Google OAuth client
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
chores=$(command -v chores || echo "$HOME/.local/bin/chores")
[[ -x "$chores" ]] || { echo "chores not found. Run scripts/install.sh in the Chores repository first." >&2; exit 1; }
[[ -x /usr/bin/python3 ]] || { echo "/usr/bin/python3 is missing. Install the Command Line Tools with xcode-select --install." >&2; exit 1; }

jobs_dir=$("$chores" paths | awk '/^jobs:/ {print $2}')
dest="$jobs_dir/inbox-watch"
mkdir -p "$dest"
for f in inbox.py prompt.md job.json; do
  command cp -f "$here/$f" "$dest/$f"
done
[[ -e "$dest/rules.md" ]] || command cp -f "$here/rules.md" "$dest/rules.md"
echo "Job files: $dest"

/usr/bin/python3 "$dest/inbox.py" setup "$@"

"$chores" validate inbox-watch
"$chores" install inbox-watch
echo
echo "Installed. It shows up in the Chores menu as \"Inbox\" and runs every day at 09:00 and 17:00."
echo "To try it now: chores run inbox-watch   (reads the last 24 hours of mail and spends a little Claude quota)"
