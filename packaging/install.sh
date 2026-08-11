#!/bin/sh
set -eu

PREFIX=${1:-/usr/local}

case "$PREFIX" in
  /*) ;;
  *)
    echo "error: PREFIX must be an absolute path" >&2
    exit 1
    ;;
esac

case "$PREFIX" in
  / | *//* | */./* | */. | */../* | */..)
    echo "error: PREFIX must not resolve through root, . or ..: $PREFIX" >&2
    exit 1
    ;;
esac

PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIBEXEC_DIR="$PREFIX/libexec/airpods-control"
BIN_DIR="$PREFIX/bin"
MAN_DIR="$PREFIX/share/man/man1"

install -d "$LIBEXEC_DIR" "$BIN_DIR" "$MAN_DIR"
install -m 755 \
  "$PACKAGE_DIR/libexec/airpods-control/airpods-control" \
  "$LIBEXEC_DIR/airpods-control"
install -m 755 \
  "$PACKAGE_DIR/libexec/airpods-control/avbypass.dylib" \
  "$LIBEXEC_DIR/avbypass.dylib"
install -m 644 \
  "$PACKAGE_DIR/share/man/man1/airpods-control.1" \
  "$MAN_DIR/airpods-control.1"
ln -sfn ../libexec/airpods-control/airpods-control "$BIN_DIR/airpods-control"

echo "Installed airpods-control to $PREFIX"
