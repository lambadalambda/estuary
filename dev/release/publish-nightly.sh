#!/bin/sh
set -eu

DMG=${1:-Estuary-nightly.dmg}
VERIFY_DMG=${VERIFY_DMG:-$(CDPATH= cd -- "$(dirname "$0")" && pwd)/verify-dmg.sh}

fail() {
    printf '%s\n' "publish-nightly: $*" >&2
    exit 1
}

[ "${GITHUB_REF:-}" = refs/heads/main ] \
    || fail "refusing to publish non-main ref: ${GITHUB_REF:-unset}"
[ -n "${GITHUB_SHA:-}" ] || fail "GITHUB_SHA is unset"
[ -n "${GITHUB_REPOSITORY:-}" ] || fail "GITHUB_REPOSITORY is unset"
[ -f "$DMG" ] || fail "missing disk image: $DMG"

head=$(git rev-parse HEAD)
[ "$head" = "$GITHUB_SHA" ] \
    || fail "checked-out HEAD $head does not match GITHUB_SHA $GITHUB_SHA"

asset="Estuary-${GITHUB_SHA}.dmg"
if ! gh release view nightly >/dev/null 2>&1; then
    gh release create nightly --prerelease --target "$GITHUB_SHA" \
        --title "Estuary nightly" --notes "No verified build published yet."
fi

if ! assets=$(gh release view nightly --json assets --jq '.assets[].name'); then
    fail "could not read existing nightly assets"
fi
exists=false
while IFS= read -r existing; do
    if [ "$existing" = "$asset" ]; then exists=true; fi
done <<EOF
$assets
EOF

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/estuary-publish.XXXXXX")
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT HUP INT TERM
mkdir "$tmp_dir/upload" "$tmp_dir/download"

if [ "$exists" = false ]; then
    local_sha=$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)
    cp "$DMG" "$tmp_dir/upload/$asset"
    gh release upload nightly "$tmp_dir/upload/$asset"
fi
gh release download nightly --pattern "$asset" --dir "$tmp_dir/download"
"$VERIFY_DMG" "$tmp_dir/download/$asset"
published_sha=$(shasum -a 256 "$tmp_dir/download/$asset" | cut -d ' ' -f 1)
if [ "$exists" = false ] && [ "$published_sha" != "$local_sha" ]; then
    fail "downloaded asset checksum differs from the uploaded image"
fi

if ! body=$(gh release view nightly --json body --jq '.body'); then
    fail "could not read nightly release body"
fi
published=$(printf '%s\n' "$body" \
    | sed -n 's/.*<!-- estuary-commit:\([0-9a-f]*\) -->.*/\1/p')
case "$body" in
    *'<!-- estuary-commit:'*)
        [ -n "$published" ] || fail "nightly release has a malformed commit marker"
        ;;
esac
if [ -n "$published" ] \
    && ! git merge-base --is-ancestor "$published" "$GITHUB_SHA"; then
    printf '%s\n' "keeping newer or unrelated nightly pointer at $published"
    exit 0
fi

short_sha=$(git rev-parse --short HEAD)
url="https://github.com/${GITHUB_REPOSITORY}/releases/download/nightly/${asset}"
gh release edit nightly --prerelease \
    --title "Estuary nightly ($short_sha)" \
    --notes "[Download this verified build](${url}) of \`main\` at ${GITHUB_SHA}.

SHA-256: \`${published_sha}\`

Ad-hoc signed (no Apple developer certificate): on first launch,
right-click the app and choose Open, or run
\`xattr -dr com.apple.quarantine /Applications/Estuary.app\`.

<!-- estuary-commit:${GITHUB_SHA} -->"
