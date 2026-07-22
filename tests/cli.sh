#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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
  printf '%s' "$haystack" | grep -F "$needle" >/dev/null ||
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
assert_contains "$global_help" 'airpods-control <resource> <command>' "bare command help"
assert_contains "$("$CLI" --help)" 'Resources:' "long global help"
assert_contains "$("$CLI" -h)" 'Resources:' "short global help"

assert_contains "$("$CLI" lm --help)" 'listening-mode set <mode>' "lm help"
assert_contains "$("$CLI" listening-mode -h)" 'listening-mode list' "listening-mode help"
assert_contains "$("$CLI" ca get --help)" 'conversation-awareness get' "ca help"
assert_contains "$("$CLI" conversation-awareness set on -h)" \
  'conversation-awareness set <on|off>' "conversation-awareness help"
assert_contains "$("$CLI" --json lm set adaptive --json --help)" \
  'listening-mode set <mode>' "help precedence"

assert_equal '0.1.0' "$("$CLI" --version)" "--version"
assert_equal '0.1.0' "$("$CLI" -v)" "-v"
assert_equal '0.1.0' "$("$CLI" version)" "version command"
assert_equal '{"version":"0.1.0"}' "$("$CLI" --json version)" "JSON version"

expect_failure 2 bad-args "$CLI" lm
expect_failure 2 bad-args "$CLI" conversation-awareness
expect_failure 2 bad-args "$CLI" get
expect_failure 2 bad-args "$CLI" set adaptive
expect_failure 2 bad-args "$CLI" list
expect_failure 2 bad-args "$CLI" toggle transparency adaptive
expect_failure 2 bad-args "$CLI" lm toggle transparency adaptive
expect_failure 2 bad-args "$CLI" ca toggle
expect_failure 2 bad-args "$CLI" lm set anc
expect_failure 2 bad-args "$CLI" ca set true
expect_failure 2 bad-args "$CLI" lm --version
expect_failure 2 bad-args "$CLI" -- lm get
expect_failure 2 '{"error":"bad-args"}' "$CLI" --json
expect_failure 2 '{"error":"bad-args"}' "$CLI" lm get --json --json

printf '%s\n' 'CLI contract tests passed'
