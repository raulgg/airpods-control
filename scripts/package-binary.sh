#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=${BUILD_DIR:-$ROOT/build}
DIST_DIR=${DIST_DIR:-$ROOT/dist}
VERSION_FILE=${VERSION_FILE:-$ROOT/version.txt}
MAKE=${MAKE:-make}

VERSION=$(cat "$VERSION_FILE")
printf '%s\n' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || {
  echo "error: $VERSION_FILE must contain a stable semantic version" >&2
  exit 1
}

BINARY="$BUILD_DIR/airpods-control"
DYLIB="$BUILD_DIR/avbypass.dylib"
PACKAGE_NAME="airpods-control-$VERSION-macos-universal"
PACKAGE_ROOT="$DIST_DIR/$PACKAGE_NAME"
ARCHIVE="$DIST_DIR/$PACKAGE_NAME.tar.gz"

[ -x "$BINARY" ] || {
  echo "error: missing executable: $BINARY" >&2
  exit 1
}
[ -f "$DYLIB" ] || {
  echo "error: missing dylib: $DYLIB" >&2
  exit 1
}

lipo "$BINARY" -verify_arch arm64 x86_64
lipo "$DYLIB" -verify_arch arm64 x86_64
codesign --verify --verbose=2 "$BINARY"
codesign --verify --verbose=2 "$DYLIB"

rm -rf "$PACKAGE_ROOT"
rm -f "$ARCHIVE" "$DIST_DIR/SHA256SUMS"
"$MAKE" -C "$ROOT" install \
  BUILD_DIR="$BUILD_DIR" \
  DESTDIR="$PACKAGE_ROOT" \
  PREFIX=
install -m 755 "$ROOT/packaging/install.sh" "$PACKAGE_ROOT/install.sh"
install -m 755 "$ROOT/packaging/uninstall.sh" "$PACKAGE_ROOT/uninstall.sh"
install -m 644 "$ROOT/LICENSE" "$ROOT/README.md" "$PACKAGE_ROOT/"

COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" -C "$DIST_DIR" "$PACKAGE_NAME"
(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$ARCHIVE")" >SHA256SUMS
)
rm -rf "$PACKAGE_ROOT"

echo "Packaged $ARCHIVE"
