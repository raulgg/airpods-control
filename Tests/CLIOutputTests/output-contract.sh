#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
PROBE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/airpods-control-output.XXXXXX")
trap 'rm -rf "$PROBE_DIR"' EXIT HUP INT TERM

SWIFTC=${SWIFTC:-swiftc}
"$SWIFTC" \
  -swift-version 5 \
  -warnings-as-errors \
  -module-cache-path "$PROBE_DIR/module-cache" \
  -o "$PROBE_DIR/output-contract" \
  "$ROOT/Sources/AirPodsControl/CLIOutput.swift" \
  "$ROOT/Sources/AirPodsControl/TerminalReason.swift" \
  "$ROOT/Tests/CLIOutputTests/output-contract-main.swift"

assert_output() {
  scenario="$1"
  expected_status="$2"
  expected_output="$3"

  set +e
  "$PROBE_DIR/output-contract" "$scenario" \
    >"$PROBE_DIR/$scenario.actual" \
    2>"$PROBE_DIR/$scenario.stderr"
  actual_status=$?
  set -e

  [ "$actual_status" -eq "$expected_status" ] || {
    printf '%s\n' \
      "FAIL: $scenario output process exited $actual_status (expected $expected_status)" >&2
    exit 1
  }
  [ ! -s "$PROBE_DIR/$scenario.stderr" ] || {
    printf '%s\n' "FAIL: $scenario output process wrote stderr" >&2
    exit 1
  }
  printf '%s\n' "$expected_output" >"$PROBE_DIR/$scenario.expected"
  cmp -s "$PROBE_DIR/$scenario.actual" "$PROBE_DIR/$scenario.expected" || {
    printf '%s\n' "FAIL: $scenario output contract changed" >&2
    exit 1
  }
}

assert_output json 0 \
  '{"bool":true,"integer":7,"nested":{"control":"line\n\tesc\u001b","quote":"a\"b","slash":"a\/b"},"null":null}'
assert_output plain 0 'plain output'
assert_output signal 130 '{"result":"interrupted","signal":2}'

printf '%s\n' 'CLI output contracts passed'
