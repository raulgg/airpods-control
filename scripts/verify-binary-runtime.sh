#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 AIRPODS_CONTROL_BINARY" >&2
  exit 1
fi

BINARY=$1
TMP_BASE=${TMPDIR:-/tmp}
TMP=$(mktemp -d "${TMP_BASE%/}/airpods-control-runtime.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

set +e
"$BINARY" --debug listening-mode list \
  >"$TMP/stdout" 2>"$TMP/stderr"
status=$?
set -e

case "$status" in
  0 | 1) ;;
  *)
    cat "$TMP/stderr" >&2
    echo "error: read-only runtime smoke test exited $status" >&2
    exit 1
    ;;
esac

grep -Fq 'bypass.status="reexec"' "$TMP/stderr"
grep -Fq 'bypass.status="active"' "$TMP/stderr"

echo "Verified hardened-runtime dylib injection"
