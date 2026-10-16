#!/bin/bash
# Brings the app's string catalog in line with the code, as Xcode does on build: the compiler emits
# every localizable string it sees (`Text("…")`, `String(localized:)`, …) as .stringsdata, and
# xcstringstool adds new keys and marks removed ones stale. Translate what it adds, then run
# `swift test` (StringCatalogTests fails while a key lacks a Turkish translation).
set -euo pipefail
cd "$(dirname "$0")/.."

CATALOG=Sources/ChoresApp/Resources/Localizable.xcstrings
swift build --product ChoresApp >/dev/null
DATA=$(find .build/out/Intermediates.noindex -path '*ChoresApp*' -name '*.stringsdata' \
  ! -name 'resource_bundle_accessor.stringsdata' ! -name 'GeneratedStringSymbols_*')
[[ -n "$DATA" ]] || { echo "no .stringsdata found; did the build system change?" >&2; exit 1; }
# shellcheck disable=SC2086
xcrun xcstringstool sync "$CATALOG" --stringsdata $DATA
echo "synced $CATALOG"
