#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 ARCHIVE" >&2
  exit 1
fi

ARCHIVE=$1
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
VERSION=$(cat "$ROOT/version.txt")
PACKAGE_NAME="airpods-control-$VERSION-macos-universal"
TMP_BASE=${TMPDIR:-/tmp}
TMP=$(mktemp -d "${TMP_BASE%/}/airpods-control-package.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

tar -xzf "$ARCHIVE" -C "$TMP"
PACKAGE_ROOT="$TMP/$PACKAGE_NAME"
BINARY="$PACKAGE_ROOT/libexec/airpods-control/airpods-control"
DYLIB="$PACKAGE_ROOT/libexec/airpods-control/avbypass.dylib"

[ "$(readlink "$PACKAGE_ROOT/bin/airpods-control")" = \
  "../libexec/airpods-control/airpods-control" ]
[ -f "$PACKAGE_ROOT/share/man/man1/airpods-control.1" ]
[ -f "$PACKAGE_ROOT/LICENSE" ]
[ -f "$PACKAGE_ROOT/README.md" ]
lipo "$BINARY" -verify_arch arm64 x86_64
lipo "$DYLIB" -verify_arch arm64 x86_64
codesign --verify --verbose=2 "$BINARY"
codesign --verify --verbose=2 "$DYLIB"

if [ "${VERIFY_GATEKEEPER:-0}" = 1 ]; then
  quarantine="0081;$(printf '%x' "$(date +%s)");GitHub Actions;"
  xattr -w com.apple.quarantine "$quarantine" "$BINARY" "$DYLIB"
  spctl --assess --type execute --verbose=4 "$BINARY"
fi

"$ROOT/scripts/verify-binary-runtime.sh" "$BINARY"
[ "$("$PACKAGE_ROOT/bin/airpods-control" --version)" = "$VERSION" ]

for unsafe_prefix in "$TMP/target/.." "$TMP//target"; do
  if "$PACKAGE_ROOT/install.sh" "$unsafe_prefix" >/dev/null 2>&1; then
    echo "error: installer accepted unsafe prefix: $unsafe_prefix" >&2
    exit 1
  fi
  if "$PACKAGE_ROOT/uninstall.sh" "$unsafe_prefix" >/dev/null 2>&1; then
    echo "error: uninstaller accepted unsafe prefix: $unsafe_prefix" >&2
    exit 1
  fi
done

PREFIX="$TMP/install-prefix"
"$PACKAGE_ROOT/install.sh" "$PREFIX"
[ "$(readlink "$PREFIX/bin/airpods-control")" = \
  "../libexec/airpods-control/airpods-control" ]
[ "$("$PREFIX/bin/airpods-control" --version)" = "$VERSION" ]
"$PACKAGE_ROOT/uninstall.sh" "$PREFIX"
[ ! -e "$PREFIX/bin/airpods-control" ]
[ ! -e "$PREFIX/libexec/airpods-control/airpods-control" ]
[ ! -e "$PREFIX/libexec/airpods-control/avbypass.dylib" ]
[ ! -e "$PREFIX/share/man/man1/airpods-control.1" ]

echo "Verified $ARCHIVE"
