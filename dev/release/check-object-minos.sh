#!/bin/sh
# Fail when any object in a static archive targets a newer macOS than the
# app's minimum. The linked binary's own minos load command stays at the
# Swift target's value no matter what the archive members say, so
# verify-app cannot see this — the archive is the only honest witness
# (see meta/issues/local-core-deployment-target.md).
set -eu

ARCHIVE=${1:?usage: check-object-minos.sh <archive.a> <max-minos>}
MAX=${2:?usage: check-object-minos.sh <archive.a> <max-minos>}

fail() {
    printf '%s\n' "check-object-minos: $*" >&2
    exit 1
}

[ -f "$ARCHIVE" ] || fail "missing archive: $ARCHIVE"

# LC_BUILD_VERSION carries "minos X.Y"; pre-11 objects use
# LC_VERSION_MIN_MACOSX's "version X.Y". Collect the distinct values that
# exceed the cap. sort -V gives numeric version order.
offending=$(
    /usr/bin/otool -l "$ARCHIVE" \
        | awk '$1 == "minos" || ($1 == "version" && $2 ~ /^[0-9]/) { print $2 }' \
        | sort -uV \
        | awk -v max="$MAX" '
            function cmp(a, b,   x, y, i, n) {
                n = split(a, x, "."); split(b, y, ".")
                for (i = 1; i <= n; i++) if (x[i] + 0 != y[i] + 0)
                    return x[i] + 0 - y[i] + 0 > 0 ? 1 : -1
                return 0
            }
            cmp($1, max) > 0 { print }'
)

[ -z "$offending" ] || fail "objects in $ARCHIVE target macOS newer than $MAX: $(
    printf '%s' "$offending" | tr '\n' ' ')"

printf '%s\n' "check-object-minos: all objects in $ARCHIVE target macOS <= $MAX"
