#!/bin/bash
# Installs the inbox-watch job into Chores and connects it to Gmail and Claude.
# Safe to re-run: it refreshes the template files, keeps config.json, state.json and rules.md.
#   setup.sh                    first install, or update after pulling the repo
#   setup.sh --reconnect        sign in to Gmail again (password changed, access revoked)
#   setup.sh --client FILE      replace the Google OAuth client
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
chores=$(command -v chores || echo "$HOME/.local/bin/chores")
[[ -x "$chores" ]] || { echo "chores bulunamadı. Önce Chores deposunda scripts/install.sh çalıştır." >&2; exit 1; }
[[ -x /usr/bin/python3 ]] || { echo "/usr/bin/python3 yok. xcode-select --install ile Command Line Tools kur." >&2; exit 1; }

jobs_dir=$("$chores" paths | awk '/^jobs:/ {print $2}')
dest="$jobs_dir/inbox-watch"
mkdir -p "$dest"
for f in inbox.py prompt.md job.json; do
  command cp -f "$here/$f" "$dest/$f"
done
[[ -e "$dest/rules.md" ]] || command cp -f "$here/rules.md" "$dest/rules.md"
echo "Job dosyaları: $dest"

/usr/bin/python3 "$dest/inbox.py" setup "$@"

"$chores" validate inbox-watch
"$chores" install inbox-watch
echo
echo "Kuruldu. Chores menüsünde \"Gelen kutusu\" olarak görünür; her gün 09:00 ve 17:00'de çalışır."
echo "Şimdi denemek için: chores run inbox-watch   (son 24 saatin maillerini okur, biraz Claude kotası harcar)"
