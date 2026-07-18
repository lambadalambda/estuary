#!/bin/sh
set -eu

APP=${1:-macos/Estuary.app}
OUTPUT=${2:-Estuary-nightly.dmg}
[ -d "$APP" ] || { printf '%s\n' "package-dmg: missing app bundle: $APP" >&2; exit 1; }

staging=$(mktemp -d "${TMPDIR:-/tmp}/estuary-dmg.XXXXXX")
cleanup() { rm -rf "$staging"; }
trap cleanup EXIT HUP INT TERM

cp -R "$APP" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$OUTPUT"
hdiutil create -volname "Estuary Nightly" -srcfolder "$staging" \
    -ov -format UDZO "$OUTPUT"
