#!/bin/sh
set -eu

APP=${1:-macos/Estuary.app}
PLIST="$APP/Contents/Info.plist"
BINARY="$APP/Contents/MacOS/DeltaApp"

fail() {
    printf '%s\n' "verify-app: $*" >&2
    exit 1
}

[ -d "$APP" ] || fail "missing app bundle: $APP"
[ -f "$PLIST" ] || fail "missing Info.plist"
[ -x "$BINARY" ] || fail "missing executable DeltaApp"

plist_min=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST")
binary_min=$(/usr/bin/vtool -show-build "$BINARY" \
    | awk '$1 == "minos" { print $2; exit }')
[ -n "$binary_min" ] || fail "binary has no macOS minimum-version load command"
[ "$plist_min" = "$binary_min" ] \
    || fail "minimum OS mismatch: plist=$plist_min binary=$binary_min"

build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")
case "$build" in
    ''|*[!0-9]*) fail "CFBundleVersion must be numeric, got: $build" ;;
esac
expected_build=${EXPECTED_BUILD:-$(git rev-list --count HEAD)}
[ "$build" = "$expected_build" ] \
    || fail "stale CFBundleVersion: expected $expected_build, got $build"

commit=$(/usr/libexec/PlistBuddy -c 'Print :EstuaryGitCommit' "$PLIST")
expected_commit=${EXPECTED_COMMIT:-$(git rev-parse --short HEAD)}
[ "$commit" = "$expected_commit" ] \
    || fail "stale EstuaryGitCommit: expected $expected_commit, got $commit"

expected_arch=${EXPECTED_ARCH:-$(uname -m)}
archs=$(lipo -archs "$BINARY")
case " $archs " in
    *" $expected_arch "*) ;;
    *) fail "missing $expected_arch architecture: $archs" ;;
esac

codesign --verify --deep --strict "$APP"

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/estuary-smoke.XXXXXX")
pid=
cleanup() {
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

DCNATIVE_MOCK=1 "$BINARY" >"$tmp_dir/output.log" 2>&1 &
pid=$!
sleep "${SMOKE_SECONDS:-3}"
if ! kill -0 "$pid" 2>/dev/null; then
    if wait "$pid"; then status=0; else status=$?; fi
    pid=
    while IFS= read -r line; do printf '%s\n' "$line" >&2; done <"$tmp_dir/output.log"
    fail "mock launch exited early with status $status"
fi

kill "$pid"
wait "$pid" 2>/dev/null || true
pid=
printf '%s\n' "verified $APP ($archs, macOS $binary_min+, build $build, $commit)"
