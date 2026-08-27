#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/verify-release-pr-body.sh"
FIXTURES="$ROOT/Tests/ReleasePleaseTests/fixtures"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

expect_status() {
	expected=$1
	path=$2
	description=$3

	set +e
	output=$("$SCRIPT" "$path" 2>&1)
	status=$?
	set -e

	[ "$status" -eq "$expected" ] ||
		fail "$description: expected exit $expected, got $status (${output})"
}

[ -x "$SCRIPT" ] || fail "missing executable script: $SCRIPT"

expect_status 0 "$FIXTURES/valid-default.body" "generated Release Please body"
expect_status 0 "$FIXTURES/valid-custom-notes.body" "custom notes between delimiters"
expect_status 1 "$FIXTURES/missing-delimiter.body" "rewritten body without ---"
expect_status 1 "$FIXTURES/missing-version-heading.body" "delimiter without version heading"

set +e
output=$(printf '' | "$SCRIPT" 2>&1)
status=$?
set -e
[ "$status" -eq 1 ] || fail "empty stdin: expected exit 1, got $status (${output})"

# GitHub PR bodies use CRLF. The rewritten #45 body failed even though it had
# a version heading, because splitBody looks for a line that is exactly ---.
crlf=$(mktemp "${TMPDIR:-/tmp}/release-pr-body.XXXXXX")
trap 'rm -f "$crlf"' EXIT HUP INT TERM
awk '{ printf "%s\r\n", $0 }' "$FIXTURES/valid-default.body" >"$crlf"
expect_status 0 "$crlf" "generated body with CRLF line endings"

echo "ok: release PR body fixtures"
