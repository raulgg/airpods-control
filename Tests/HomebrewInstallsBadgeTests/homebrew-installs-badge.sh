#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/homebrew-installs-badge.sh"
FIXTURES="$ROOT/Tests/HomebrewInstallsBadgeTests/fixtures"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

expect_failure() {
	description=$1
	shift
	if "$@" >"$TMP/failure.out" 2>&1; then
		fail "$description: command unexpectedly succeeded"
	fi
}

expect_message() {
	file=$1
	expected=$2
	got=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["message"])' <"$file")
	[ "$got" = "$expected" ] ||
		fail "$file: message $got, expected $expected"
}

expect_field() {
	file=$1
	key=$2
	expected=$3
	got=$(KEY=$key python3 -c 'import json,os,sys; print(json.load(sys.stdin)[os.environ["KEY"]])' <"$file")
	[ "$got" = "$expected" ] ||
		fail "$file: $key $got, expected $expected"
}

[ -x "$SCRIPT" ] || fail "missing executable script: $SCRIPT"

tmp_base=${TMPDIR:-/tmp}
tmp_base=${tmp_base%/}
TMP=$(mktemp -d "$tmp_base/homebrew-installs-badge.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

"$SCRIPT" --analytics-file "$FIXTURES/found.json" --output "$TMP/found.json"
expect_message "$TMP/found.json" 6/90d
expect_field "$TMP/found.json" schemaVersion 1
expect_field "$TMP/found.json" label "brew installs"
expect_field "$TMP/found.json" color FBB040
expect_field "$TMP/found.json" namedLogo homebrew

"$SCRIPT" --analytics-file "$FIXTURES/with-options.json" \
	--output "$TMP/with-options.json"
expect_message "$TMP/with-options.json" 6/90d

"$SCRIPT" --analytics-file "$FIXTURES/missing.json" --output "$TMP/missing.json"
expect_message "$TMP/missing.json" 0/90d

"$SCRIPT" --analytics-file "$FIXTURES/empty-items.json" \
	--period 365d --output "$TMP/empty.json"
expect_message "$TMP/empty.json" 0/365d

"$SCRIPT" --analytics-file "$FIXTURES/wget-30d.json" \
	--formula wget --period 30d --label downloads --output "$TMP/wget.json"
expect_message "$TMP/wget.json" 1415554/30d
expect_field "$TMP/wget.json" label downloads

"$SCRIPT" --analytics-file "$FIXTURES/truncated-missing.json" \
	--output "$TMP/truncated-missing.json"
expect_message "$TMP/truncated-missing.json" '<1/90d'

"$SCRIPT" --analytics-file "$FIXTURES/truncated-found.json" \
	--output "$TMP/truncated-found.json"
expect_message "$TMP/truncated-found.json" 6/90d

expect_failure "missing analytics file" "$SCRIPT"
expect_failure "unknown period" "$SCRIPT" \
	--analytics-file "$FIXTURES/found.json" --period weekly
expect_failure "invalid JSON" "$SCRIPT" \
	--analytics-file "$FIXTURES/invalid.json"
expect_failure "missing file" "$SCRIPT" \
	--analytics-file "$TMP/does-not-exist.json"
expect_failure "window does not match period" "$SCRIPT" \
	--analytics-file "$FIXTURES/found.json" --period 30d
expect_failure "matched item missing count" "$SCRIPT" \
	--analytics-file "$FIXTURES/missing-count.json"

echo "ok: homebrew-installs-badge fixtures"
