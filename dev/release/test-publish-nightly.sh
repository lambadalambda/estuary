#!/bin/sh
set -eu

case "$(basename "$0")" in
    gh)
        command=$1
        operation=$2
        shift 2
        case "$command:$operation" in
            release:view)
                [ -f "$FAKE_STATE/release" ] || exit 1
                shift
                if [ "$#" -eq 0 ]; then exit 0; fi
                if [ "${FAIL_RELEASE_VIEW:-}" = 1 ]; then exit 9; fi
                case "$*" in
                    "--json assets --jq .assets[].name")
                        if [ "${FAIL_ASSET_VIEW:-}" = 1 ]; then exit 9; fi
                        for asset in "$FAKE_STATE"/assets/*; do
                            [ -f "$asset" ] && basename "$asset"
                        done
                        ;;
                    "--json body --jq .body")
                        if [ "${FAIL_BODY_VIEW:-}" = 1 ]; then exit 9; fi
                        [ -f "$FAKE_STATE/body" ] \
                            && while IFS= read -r line; do printf '%s\n' "$line"; done <"$FAKE_STATE/body"
                        ;;
                    *) exit 2 ;;
                esac
                ;;
            release:create)
                touch "$FAKE_STATE/release"
                ;;
            release:upload)
                shift
                cp "$1" "$FAKE_STATE/assets/$(basename "$1")"
                ;;
            release:download)
                shift
                pattern=
                destination=
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        --pattern) pattern=$2; shift 2 ;;
                        --dir) destination=$2; shift 2 ;;
                        *) exit 2 ;;
                    esac
                done
                if [ -f "$FAKE_STATE/fail-download-once" ]; then
                    rm "$FAKE_STATE/fail-download-once"
                    exit 9
                fi
                [ ! -e "$destination/$pattern" ] || exit 17
                cp "$FAKE_STATE/assets/$pattern" "$destination/$pattern"
                ;;
            release:edit)
                shift
                notes=
                while [ "$#" -gt 0 ]; do
                    case "$1" in
                        --notes) notes=$2; shift 2 ;;
                        *) shift ;;
                    esac
                done
                printf '%s\n' "$notes" >"$FAKE_STATE/body"
                count=0
                [ ! -f "$FAKE_STATE/edit-count" ] \
                    || count=$(while IFS= read -r line; do printf '%s' "$line"; done <"$FAKE_STATE/edit-count")
                printf '%s\n' "$((count + 1))" >"$FAKE_STATE/edit-count"
                ;;
            *) exit 2 ;;
        esac
        exit 0
        ;;
    git)
        case "$1:$2" in
            rev-parse:HEAD) printf '%s\n' "$TEST_HEAD" ;;
            rev-parse:--short) printf '%.7s\n' "$TEST_HEAD" ;;
            merge-base:--is-ancestor)
                [ -f "$FAKE_STATE/ancestor-$3-$4" ]
                ;;
            *) exit 2 ;;
        esac
        exit 0
        ;;
    verify-dmg)
        [ -f "$1" ]
        exit 0
        ;;
esac

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
SELF="$SCRIPT_DIR/$(basename "$0")"
PUBLISH="$SCRIPT_DIR/publish-nightly.sh"
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/publish-nightly-test.XXXXXX")
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT HUP INT TERM
mkdir "$tmp_dir/bin" "$tmp_dir/state" "$tmp_dir/state/assets"
ln -s "$SELF" "$tmp_dir/bin/gh"
ln -s "$SELF" "$tmp_dir/bin/git"
ln -s "$SELF" "$tmp_dir/bin/verify-dmg"
export PATH="$tmp_dir/bin:$PATH"
export FAKE_STATE="$tmp_dir/state"
export VERIFY_DMG="$tmp_dir/bin/verify-dmg"
export GITHUB_REPOSITORY=owner/repo

current=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
newer=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export TEST_HEAD=$current GITHUB_SHA=$current
printf 'local-one\n' >"$tmp_dir/build.dmg"

if GITHUB_REF=refs/heads/topic "$PUBLISH" "$tmp_dir/build.dmg" >/dev/null 2>&1; then
    printf '%s\n' 'non-main publication unexpectedly succeeded' >&2
    exit 1
fi

export GITHUB_REF=refs/heads/main
"$PUBLISH" "$tmp_dir/build.dmg"
grep -Fq "<!-- estuary-commit:$current -->" "$FAKE_STATE/body"
[ "$(while IFS= read -r line; do printf '%s' "$line"; done <"$FAKE_STATE/edit-count")" = 1 ]

export TEST_HEAD=$newer GITHUB_SHA=$newer
touch "$FAKE_STATE/ancestor-$current-$newer"
touch "$FAKE_STATE/fail-download-once"
if "$PUBLISH" "$tmp_dir/build.dmg" >/dev/null 2>&1; then
    printf '%s\n' 'interrupted upload unexpectedly succeeded' >&2
    exit 1
fi
[ -f "$FAKE_STATE/assets/Estuary-$newer.dmg" ]

printf 'different-local-bytes\n' >"$tmp_dir/build.dmg"
"$PUBLISH" "$tmp_dir/build.dmg"
grep -Fq "<!-- estuary-commit:$newer -->" "$FAKE_STATE/body"
[ "$(while IFS= read -r line; do printf '%s' "$line"; done <"$FAKE_STATE/edit-count")" = 2 ]

export FAIL_ASSET_VIEW=1
if "$PUBLISH" "$tmp_dir/build.dmg" >/dev/null 2>&1; then
    printf '%s\n' 'asset API failure unexpectedly succeeded' >&2
    exit 1
fi
unset FAIL_ASSET_VIEW
[ "$(while IFS= read -r line; do printf '%s' "$line"; done <"$FAKE_STATE/edit-count")" = 2 ]

export FAIL_BODY_VIEW=1
if "$PUBLISH" "$tmp_dir/build.dmg" >/dev/null 2>&1; then
    printf '%s\n' 'body API failure unexpectedly succeeded' >&2
    exit 1
fi
unset FAIL_BODY_VIEW
[ "$(while IFS= read -r line; do printf '%s' "$line"; done <"$FAKE_STATE/edit-count")" = 2 ]

export TEST_HEAD=$current GITHUB_SHA=$current
"$PUBLISH" "$tmp_dir/build.dmg"
[ "$(while IFS= read -r line; do printf '%s' "$line"; done <"$FAKE_STATE/edit-count")" = 2 ]

export TEST_HEAD=$newer
if "$PUBLISH" "$tmp_dir/build.dmg" >/dev/null 2>&1; then
    printf '%s\n' 'HEAD/SHA mismatch unexpectedly succeeded' >&2
    exit 1
fi

printf '%s\n' 'publish-nightly tests passed'
