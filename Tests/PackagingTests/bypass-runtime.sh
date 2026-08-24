#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 AIRPODS_CONTROL_BINARY AVBYPASS_DYLIB" >&2
  exit 1
fi

BINARY=$1
DYLIB=$2
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TMP_BASE=${TMPDIR:-/tmp}
TMP=$(mktemp -d "${TMP_BASE%/}/airpods-control-bypass-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

cp "$BINARY" "$TMP/airpods-control"
cp "$DYLIB" "$TMP/avbypass.dylib"

"$ROOT/scripts/verify-binary-runtime.sh" "$TMP/airpods-control"

mkdir "$TMP/hardened"
cp "$BINARY" "$TMP/hardened/airpods-control"
cp "$DYLIB" "$TMP/hardened/avbypass.dylib"
codesign --force --sign - --options runtime "$TMP/hardened/airpods-control"
if "$ROOT/scripts/verify-binary-runtime.sh" \
  "$TMP/hardened/airpods-control" >/dev/null 2>&1; then
  echo "error: runtime verifier accepted a hardened-runtime binary" >&2
  exit 1
fi

inputs=
for arch in arm64 x86_64; do
  clang -O2 -arch "$arch" -mmacosx-version-min=12.0 -dynamiclib \
    -o "$TMP/empty-$arch.dylib" \
    "$ROOT/Tests/PackagingTests/empty_dylib.c"
  inputs="$inputs $TMP/empty-$arch.dylib"
done
lipo -create $inputs -output "$TMP/avbypass.dylib"
codesign --force --sign - "$TMP/avbypass.dylib"

if "$ROOT/scripts/verify-binary-runtime.sh" "$TMP/airpods-control" >/dev/null 2>&1; then
  echo "error: runtime verifier accepted a non-interposing dylib" >&2
  exit 1
fi

echo "Runtime verifier rejected a hardened-runtime binary"
echo "Runtime verifier rejected a non-interposing dylib"
