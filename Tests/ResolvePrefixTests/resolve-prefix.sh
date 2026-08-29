#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/resolve-prefix.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

expect_rejected() {
	if output=$("$SCRIPT" "$@" 2>&1); then
		fail "accepted unsafe prefix '$*' (${output})"
	fi
}

[ -x "$SCRIPT" ] || fail "missing executable script: $SCRIPT"

# These are one rejection workflow, not separate copies of the same test.
expect_rejected
for prefix in relative/prefix / /tmp/./prefix /tmp/../prefix; do
	expect_rejected "$prefix"
done

TMP_BASE=${TMPDIR:-/tmp}
TMP_BASE=${TMP_BASE%/}
TMP=$(mktemp -d "$TMP_BASE/resolve-prefix.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

canonical_tmp=$(CDPATH= cd -P -- "$TMP" && pwd -P)
got=$("$SCRIPT" "$TMP")
[ "$got" = "$canonical_tmp" ] ||
	fail "existing directory: expected $canonical_tmp, got $got"

nested="$TMP/nested install"
got=$("$SCRIPT" "$nested")
[ "$got" = "$canonical_tmp/nested install" ] ||
	fail "missing nested directory: expected $canonical_tmp/nested install, got $got"

root_link="$TMP/root-prefix"
ln -s / "$root_link"
expect_rejected "$root_link"

echo "ok: resolve-prefix fixtures"
