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
BUILD_INFO="$PACKAGE_ROOT/BUILD.txt"

[ "$(readlink "$PACKAGE_ROOT/bin/airpods-control")" = \
  "../libexec/airpods-control/airpods-control" ]
[ -f "$PACKAGE_ROOT/share/man/man1/airpods-control.1" ]
[ -f "$PACKAGE_ROOT/LICENSE" ]
[ -f "$PACKAGE_ROOT/README.md" ]
[ -f "$BUILD_INFO" ]
[ -x "$PACKAGE_ROOT/resolve-prefix.sh" ]
grep -Eq '^commit=(unknown|[0-9a-f]{40})$' "$BUILD_INFO"
grep -Eq '^native_arch=(arm64|x86_64)$' "$BUILD_INFO"
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

ROOT_PREFIX="$TMP/root-prefix"
ln -s / "$ROOT_PREFIX"
if output=$("$PACKAGE_ROOT/resolve-prefix.sh" "$ROOT_PREFIX" 2>&1); then
  echo "error: prefix resolver accepted a path resolving to root" >&2
  exit 1
fi
printf '%s\n' "$output" | grep -Fq 'PREFIX resolves to root'

COLLISION_PREFIX="$TMP/collision-prefix"
mkdir -p "$COLLISION_PREFIX/bin"
printf 'foreign-command\n' >"$COLLISION_PREFIX/bin/airpods-control"
if "$PACKAGE_ROOT/install.sh" "$COLLISION_PREFIX" >/dev/null 2>&1; then
  echo "error: installer replaced a command it does not own" >&2
  exit 1
fi
[ "$(cat "$COLLISION_PREFIX/bin/airpods-control")" = foreign-command ]
[ ! -e "$COLLISION_PREFIX/libexec/airpods-control/airpods-control" ]
[ ! -e "$COLLISION_PREFIX/share/man/man1/airpods-control.1" ]

REAL_PARENT="$TMP/real prefix"
PREFIX_ALIAS="$TMP/prefix-alias"
mkdir -p "$REAL_PARENT"
ln -s "$REAL_PARENT" "$PREFIX_ALIAS"
PREFIX_INPUT="$PREFIX_ALIAS/nested install"
PREFIX="$REAL_PARENT/nested install"

"$PACKAGE_ROOT/install.sh" "$PREFIX_INPUT"
[ "$(readlink "$PREFIX/bin/airpods-control")" = \
  "../libexec/airpods-control/airpods-control" ]
[ -x "$PREFIX/libexec/airpods-control/airpods-control" ]
[ -x "$PREFIX/libexec/airpods-control/avbypass.dylib" ]
"$ROOT/scripts/verify-binary-runtime.sh" "$PREFIX/bin/airpods-control"

# An owned symlink permits upgrades, but the installed dylib remains mandatory.
"$PACKAGE_ROOT/install.sh" "$PREFIX_INPUT"
rm -f "$PREFIX/libexec/airpods-control/avbypass.dylib"
if "$ROOT/scripts/verify-binary-runtime.sh" \
  "$PREFIX/bin/airpods-control" >/dev/null 2>&1; then
  echo "error: installed runtime passed without its companion dylib" >&2
  exit 1
fi
"$PACKAGE_ROOT/install.sh" "$PREFIX_INPUT"

rm -f "$PREFIX/bin/airpods-control"
printf 'foreign-command\n' >"$PREFIX/bin/airpods-control"
if "$PACKAGE_ROOT/uninstall.sh" "$PREFIX_INPUT" >/dev/null 2>&1; then
  echo "error: uninstaller removed a command it does not own" >&2
  exit 1
fi
[ "$(cat "$PREFIX/bin/airpods-control")" = foreign-command ]
[ -e "$PREFIX/libexec/airpods-control/airpods-control" ]
[ -e "$PREFIX/libexec/airpods-control/avbypass.dylib" ]
[ -e "$PREFIX/share/man/man1/airpods-control.1" ]

rm -f "$PREFIX/bin/airpods-control"
"$PACKAGE_ROOT/uninstall.sh" "$PREFIX_INPUT"
[ ! -e "$PREFIX/bin/airpods-control" ]
[ ! -e "$PREFIX/libexec/airpods-control/airpods-control" ]
[ ! -e "$PREFIX/libexec/airpods-control/avbypass.dylib" ]
[ ! -e "$PREFIX/share/man/man1/airpods-control.1" ]

echo "Verified $ARCHIVE"
