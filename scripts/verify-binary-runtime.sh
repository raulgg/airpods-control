#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 AIRPODS_CONTROL_BINARY" >&2
  exit 1
fi

BINARY=$1
SIGNATURE_POLICY=${VERIFY_SIGNATURE_POLICY:-adhoc}
TMP_BASE=${TMPDIR:-/tmp}
TMP=$(mktemp -d "${TMP_BASE%/}/airpods-control-runtime.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

resolve_binary_path() {
  path=$1
  hops=0

  while [ -L "$path" ]; do
    hops=$((hops + 1))
    if [ "$hops" -gt 40 ]; then
      echo "error: too many executable symlinks: $1" >&2
      return 1
    fi
    target=$(readlink "$path")
    case "$target" in
      /*) path=$target ;;
      *) path=$(dirname -- "$path")/$target ;;
    esac
    directory=$(CDPATH= cd -P -- "$(dirname -- "$path")" && pwd -P)
    path="$directory/$(basename -- "$path")"
  done

  directory=$(CDPATH= cd -P -- "$(dirname -- "$path")" && pwd -P)
  printf '%s/%s\n' "$directory" "$(basename -- "$path")"
}

RESOLVED_BINARY=$(resolve_binary_path "$BINARY")
DYLIB=$(dirname -- "$RESOLVED_BINARY")/avbypass.dylib
[ -x "$RESOLVED_BINARY" ] || {
  echo "error: missing executable: $RESOLVED_BINARY" >&2
  exit 1
}
[ -f "$DYLIB" ] || {
  echo "error: missing companion dylib: $DYLIB" >&2
  exit 1
}

verify_ad_hoc_signature() {
  candidate=$1
  codesign --verify --strict --verbose=2 "$candidate"
  details=$(codesign -dv --verbose=4 "$candidate" 2>&1)
  printf '%s\n' "$details" | grep -Fqx 'Signature=adhoc' || {
    echo "error: expected an ad-hoc signature: $candidate" >&2
    exit 1
  }
  flags=$(printf '%s\n' "$details" |
    sed -n 's/^CodeDirectory .* flags=\([^ ]*\).*/\1/p')
  [ -n "$flags" ] || {
    echo "error: could not read code-signing flags: $candidate" >&2
    exit 1
  }
  case "$flags" in
    *runtime*)
      echo "error: experimental binary must not enable hardened runtime: $candidate" >&2
      exit 1
      ;;
  esac
}

case "$SIGNATURE_POLICY" in
  adhoc)
    verify_ad_hoc_signature "$RESOLVED_BINARY"
    verify_ad_hoc_signature "$DYLIB"
    ;;
  external) ;;
  *)
    echo "error: unknown signature policy: $SIGNATURE_POLICY" >&2
    exit 1
    ;;
esac

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

if [ "$SIGNATURE_POLICY" = adhoc ]; then
  echo "Verified ad-hoc-signed DYLD interposition"
else
  echo "Verified DYLD interposition"
fi
