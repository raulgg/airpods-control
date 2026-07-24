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
  [ "$actual" = "$expected" ] || fail "$description: expected '$expected', got '$actual'"
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
[ ! -e "$ROOT/build/airpods" ] || fail "legacy build/airpods artifact exists"

# Excluding avbypass.dylib proves these parser-only paths return before the
# entitlement bootstrap and private-framework lookup.
PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/airpods-control-test.XXXXXX")
trap 'rm -rf "$PROBE_DIR"' EXIT HUP INT TERM
cp "$BUILT_CLI" "$PROBE_DIR/airpods-control"
CLI="$PROBE_DIR/airpods-control"

global_help=$("$CLI")
assert_contains "$global_help" \
  'airpods-control [--device NAME] <resource> <command>' "bare command help"
assert_contains "$("$CLI" --help)" 'Resources:' "long global help"
assert_contains "$("$CLI" -h)" 'Resources:' "short global help"
assert_contains "$("$CLI" --help)" '--debug' "global debug help"
assert_contains "$("$CLI" --help)" '--device NAME' "global device help"
assert_contains "$("$CLI" --help)" 'Read, set, list, or cycle listening modes.' \
  "global listening-mode command summary"

assert_contains "$("$CLI" lm --help)" 'listening-mode set <mode>' "lm help"
assert_contains "$("$CLI" listening-mode -h)" 'listening-mode list' "listening-mode help"
assert_contains "$("$CLI" lm cycle --help)" 'listening-mode cycle' "lm cycle help"
assert_contains "$("$CLI" lm --help)" 'anc, nc' "listening-mode alias help"
assert_contains "$("$CLI" ca get --help)" 'conversation-awareness get' "ca help"
assert_contains "$("$CLI" conversation-awareness set on -h)" \
  'conversation-awareness set <on|off>' "conversation-awareness help"
assert_contains "$("$CLI" --json lm set adaptive --json --help)" \
  'listening-mode set <mode>' "help precedence"

assert_equal '0.1.0' "$("$CLI" --version)" "--version"
assert_equal '0.1.0' "$("$CLI" -v)" "-v"
assert_equal '0.1.0' "$("$CLI" version)" "version command"
assert_equal '{"result":"ok","version":"0.1.0"}' \
  "$("$CLI" --json version)" "JSON version"

"$CLI" --version >"$PROBE_DIR/plain.stdout" 2>"$PROBE_DIR/plain.stderr"
assert_equal '0.1.0' "$(cat "$PROBE_DIR/plain.stdout")" "plain stdout"
assert_equal '' "$(cat "$PROBE_DIR/plain.stderr")" "normal command has no diagnostics"

"$CLI" --debug --version >"$PROBE_DIR/debug.stdout" 2>"$PROBE_DIR/debug.stderr"
assert_equal '0.1.0' "$(cat "$PROBE_DIR/debug.stdout")" "debug preserves stdout"
assert_contains "$(cat "$PROBE_DIR/debug.stderr")" \
  'debug: cli.command="version"' "debug uses stderr"

expect_failure 2 bad-args "$CLI" lm
expect_failure 2 bad-args "$CLI" conversation-awareness
expect_failure 2 bad-args "$CLI" get
expect_failure 2 bad-args "$CLI" set adaptive
expect_failure 2 bad-args "$CLI" list
expect_failure 2 bad-args "$CLI" toggle transparency adaptive
expect_failure 2 bad-args "$CLI" lm toggle transparency adaptive
expect_failure 2 bad-args "$CLI" ca toggle
expect_failure 2 bad-args "$CLI" cycle
expect_failure 2 bad-args "$CLI" lm cycle extra
expect_failure 2 bad-args "$CLI" lm cycle --modes
expect_failure 2 bad-args "$CLI" lm cycle --modes transparency
expect_failure 2 bad-args "$CLI" lm cycle --modes transparency,transparency
expect_failure 2 bad-args "$CLI" lm cycle --modes transparency,normal
expect_failure 2 bad-args "$CLI" lm cycle --modes trans,transparency
expect_failure 2 bad-args "$CLI" lm cycle --modes ,transparency,adaptive
expect_failure 2 bad-args "$CLI" lm cycle --modes transparency,,adaptive
expect_failure 2 bad-args "$CLI" lm cycle --modes transparency,adaptive,
expect_failure 2 bad-args "$CLI" lm cycle --modes transparency,adaptive extra
expect_failure 2 '{"error":"bad-args","result":"error"}' \
  "$CLI" lm cycle --modes anc --json
expect_failure 2 bad-args "$CLI" lm set normal
expect_failure 2 bad-args "$CLI" ca set true
expect_failure 2 bad-args "$CLI" lm --version
expect_failure 2 bad-args "$CLI" -- lm get
expect_failure 2 bad-args "$CLI" --device AirPods version
expect_failure 2 bad-args "$CLI" lm get --device
expect_failure 2 bad-args "$CLI" --device One --device Two lm get
expect_failure 2 '{"error":"bad-args","result":"error"}' "$CLI" --json
expect_failure 2 '{"error":"bad-args","result":"error"}' \
  "$CLI" lm get --json --json

set +e
duplicate_debug_output=$(
  "$CLI" --debug --debug lm get 2>"$PROBE_DIR/duplicate-debug.stderr"
)
duplicate_debug_status=$?
set -e
assert_equal 2 "$duplicate_debug_status" "duplicate debug exit status"
assert_equal bad-args "$duplicate_debug_output" "duplicate debug output"
assert_contains "$(cat "$PROBE_DIR/duplicate-debug.stderr")" \
  'warning: cli.parse="bad-args"' "duplicate debug diagnostics"

for alias in anc nc trans automatic auto; do
  expect_failure 1 no-device "$CLI" lm set "$alias"
done

expect_failure 1 no-device "$CLI" lm cycle
expect_failure 1 no-device "$CLI" lm cycle --modes off,trans,anc
expect_failure 1 \
  '{"device":null,"error":"no-device","listeningMode":null,"result":"error"}' \
  "$CLI" lm cycle --json

expect_failure 1 no-device "$CLI" lm --device 'Missing AirPods' get
expect_failure 1 no-device "$CLI" --device 'Missing AirPods' ca get

expect_failure 1 \
  '{"device":null,"error":"no-device","listeningMode":null,"result":"error"}' \
  "$CLI" lm get --json
expect_failure 1 \
  '{"device":null,"error":"no-device","listeningMode":null,"result":"error","supportedListeningModes":[]}' \
  "$CLI" --json lm list
expect_failure 1 \
  '{"conversationAwareness":null,"device":null,"error":"no-device","result":"error"}' \
  "$CLI" ca get --json

set +e
"$CLI" --debug lm get >"$PROBE_DIR/operation.stdout" 2>"$PROBE_DIR/operation.stderr"
operation_status=$?
set -e
assert_equal 1 "$operation_status" "debug operational exit status"
assert_equal no-device "$(cat "$PROBE_DIR/operation.stdout")" \
  "debug operational stdout"
assert_contains "$(cat "$PROBE_DIR/operation.stderr")" \
  'debug: cli.command="listening-mode.get"' "debug operational diagnostics"

printf '%s\n' 'CLI contract tests passed'
