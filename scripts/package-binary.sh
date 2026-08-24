#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=${BUILD_DIR:-$ROOT/build}
DIST_DIR=${DIST_DIR:-$ROOT/dist}
VERSION_FILE=${VERSION_FILE:-$ROOT/version.txt}
MAKE=${MAKE:-make}
SWIFTC=${SWIFTC:-swiftc}
CLANG=${CLANG:-clang}

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
rm -f "$ARCHIVE" "$DIST_DIR/SHA256SUMS" "$DIST_DIR/BUILD.txt"
"$MAKE" -C "$ROOT" install \
  BUILD_DIR="$BUILD_DIR" \
  DESTDIR="$PACKAGE_ROOT" \
  PREFIX=
install -m 755 "$ROOT/packaging/install.sh" "$PACKAGE_ROOT/install.sh"
install -m 755 "$ROOT/packaging/uninstall.sh" "$PACKAGE_ROOT/uninstall.sh"
install -m 755 "$ROOT/packaging/resolve-prefix.sh" "$PACKAGE_ROOT/resolve-prefix.sh"
install -m 644 "$ROOT/LICENSE" "$ROOT/README.md" "$PACKAGE_ROOT/"

BUILD_COMMIT=${BUILD_COMMIT:-}
if [ -z "$BUILD_COMMIT" ]; then
  BUILD_COMMIT=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)
fi
BUILD_COMMIT=${BUILD_COMMIT:-unknown}
printf '%s\n' "$BUILD_COMMIT" | grep -Eq '^(unknown|[0-9a-f]{40})$' || {
  echo "error: BUILD_COMMIT must be a full Git commit or unknown" >&2
  exit 1
}
{
  printf 'commit=%s\n' "$BUILD_COMMIT"
  printf 'native_arch=%s\n' "$(uname -m)"
  printf 'runner_arch=%s\n' "${RUNNER_ARCH:-local}"
  printf 'macos_version=%s\n' "$(sw_vers -productVersion)"
  printf 'swift_version=%s\n' "$("$SWIFTC" --version 2>/dev/null | sed -n '1p')"
  printf 'clang_version=%s\n' "$("$CLANG" --version | sed -n '1p')"
} >"$PACKAGE_ROOT/BUILD.txt"
install -m 644 "$PACKAGE_ROOT/BUILD.txt" "$DIST_DIR/BUILD.txt"

COPYFILE_DISABLE=1 tar -czf "$ARCHIVE" -C "$DIST_DIR" "$PACKAGE_NAME"
(
  cd "$DIST_DIR"
  shasum -a 256 "$(basename "$ARCHIVE")" >SHA256SUMS
)
rm -rf "$PACKAGE_ROOT"

echo "Packaged $ARCHIVE"
