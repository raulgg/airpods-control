#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/resolve-prefix.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

expect_status() {
	expected=$1
	shift
	description=$1
	shift

	set +e
	output=$("$SCRIPT" "$@" 2>&1)
	status=$?
	set -e

	[ "$status" -eq "$expected" ] ||
		fail "$description: expected exit $expected, got $status (${output})"
}

[ -x "$SCRIPT" ] || fail "missing executable script: $SCRIPT"

expect_status 1 "no arguments"
expect_status 1 "relative path" relative/prefix
expect_status 1 "root" /
expect_status 1 "dot component" /tmp/./prefix
expect_status 1 "dotdot component" /tmp/../prefix

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
expect_status 1 "symlink to root" "$root_link"

echo "ok: resolve-prefix fixtures"
