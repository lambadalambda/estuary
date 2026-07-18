#!/bin/sh
set -eu

DMG=${1:-Estuary-nightly.dmg}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

fail() {
    printf '%s\n' "verify-dmg: $*" >&2
    exit 1
}

[ -f "$DMG" ] || fail "missing disk image: $DMG"
hdiutil verify "$DMG"

mount_dir=$(mktemp -d "${TMPDIR:-/tmp}/estuary-dmg.XXXXXX")
mounted=false
cleanup() {
    if [ "$mounted" = true ]; then
        hdiutil detach "$mount_dir" -quiet || true
    fi
    rmdir "$mount_dir" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$mount_dir" -quiet
mounted=true
[ -L "$mount_dir/Applications" ] || fail "Applications link is missing"
[ "$(readlink "$mount_dir/Applications")" = /Applications ] \
    || fail "Applications link has the wrong target"
"$SCRIPT_DIR/verify-app.sh" "$mount_dir/Estuary.app"

hdiutil detach "$mount_dir" -quiet
mounted=false
rmdir "$mount_dir"
trap - EXIT HUP INT TERM
printf '%s\n' "verified $DMG"
