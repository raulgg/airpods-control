#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BUILT_CLI="$ROOT/build/airpods-control"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  expected="$1"
  actual="$2"
  description="$3"
  [ "$actual" = "$expected" ] ||
    fail "$description: expected '$expected', got '$actual'"
}

assert_contains() {
  haystack="$1"
  needle="$2"
  description="$3"
  printf '%s' "$haystack" | grep -F -- "$needle" >/dev/null ||
    fail "$description: expected output containing '$needle'"
}

expect_failure() {
  expected_status="$1"
  expected_output="$2"
  shift 2

  set +e
  actual_output=$("$@")
  actual_status=$?
  set -e

  assert_equal "$expected_status" "$actual_status" "exit status for $*"
  assert_equal "$expected_output" "$actual_output" "output for $*"
}

[ -x "$BUILT_CLI" ] || fail "missing executable: run make first"
VERSION=$(cat "$ROOT/version.txt")
[ -n "$VERSION" ] || fail "empty version file"

# Omitting avbypass.dylib proves these parser-only journeys finish before the
# entitlement bootstrap and private-framework lookup.
PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/airpods-control-test.XXXXXX")
trap 'rm -rf "$PROBE_DIR"' EXIT HUP INT TERM
cp "$BUILT_CLI" "$PROBE_DIR/airpods-control"
CLI="$PROBE_DIR/airpods-control"
MISSING_DEVICE='__airpods_control_cli_contract_missing__'

"$CLI" --help >/dev/null
"$CLI" lm --help >/dev/null
"$CLI" status --help >/dev/null
"$CLI" support-report --help >/dev/null

assert_equal "$VERSION" "$("$CLI" --version)" "plain version"
assert_equal "{\"result\":\"ok\",\"version\":\"$VERSION\"}" \
  "$("$CLI" --json version)" "JSON version"

"$CLI" --debug --version >"$PROBE_DIR/debug.stdout" \
  2>"$PROBE_DIR/debug.stderr"
assert_equal "$VERSION" "$(cat "$PROBE_DIR/debug.stdout")" \
  "debug preserves stdout"
[ -s "$PROBE_DIR/debug.stderr" ] ||
  fail "debug version should emit diagnostics on stderr"

# Representative failures exercise command shape, option ownership, duplicate
# globals, and cycle validation. Detailed parser seams stay in the Swift suite.
expect_failure 2 bad-args "$CLI" unknown-command
expect_failure 2 bad-args "$CLI" lm set
expect_failure 2 bad-args "$CLI" lm cycle --modes transparency
expect_failure 2 '{"error":"bad-args","result":"error"}' \
  "$CLI" lm get --json --json
expect_failure 2 '{"error":"bad-args","result":"error"}' \
  "$CLI" support-report --json

# Exercise the executable's script-facing no-device contract as one journey.
# Valid mutating invocations stay in the Swift suite. This black-box contract
# never runs one against production discovery, even with a sentinel name.
expect_failure 1 no-device "$CLI" \
  --device "$MISSING_DEVICE" lm set anc
expect_failure 1 \
  '{"device":null,"error":"no-device","listeningMode":null,"result":"error","supportedListeningModes":[]}' \
  "$CLI" --device "$MISSING_DEVICE" --json lm list
expect_failure 1 \
  '{"conversationAwareness":null,"device":null,"error":"no-device","result":"error"}' \
  "$CLI" --device "$MISSING_DEVICE" ca get --json
expect_failure 1 \
  '{"devices":[],"error":"no-device","result":"error"}' \
  "$CLI" --json status

set +e
support_report_output=$(
  "$CLI" support-report 2>"$PROBE_DIR/support-report.stderr"
)
support_report_status=$?
set -e
assert_equal 1 "$support_report_status" "support-report no-device exit status"
assert_contains "$support_report_output" \
  'Connect exactly one compatible AirPods or Beats device' \
  "support-report unique-device guidance"
assert_equal '' "$(cat "$PROBE_DIR/support-report.stderr")" \
  "support-report no-device has no prompt"

# --with-write-tests authorizes real writes. This probe copy has no bypass
# dylib, and this immediately preceding operational command proves discovery is
# blocked before the consented invocation runs.
expect_failure 1 no-device "$CLI" lm get
set +e
support_report_writes_output=$(
  "$CLI" support-report --with-write-tests \
    2>"$PROBE_DIR/support-report-writes.stderr"
)
support_report_writes_status=$?
set -e
assert_equal 1 "$support_report_writes_status" \
  "consented support-report no-device exit status"
assert_contains "$support_report_writes_output" \
  'Connect exactly one compatible AirPods or Beats device' \
  "consented support-report unique-device guidance"
assert_equal '' "$(cat "$PROBE_DIR/support-report-writes.stderr")" \
  "no device means no consent prompt and no writes"

printf '%s\n' 'CLI contract tests passed'
