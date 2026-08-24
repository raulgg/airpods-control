#!/bin/sh
set -eu

PREFIX_INPUT=${1:-/usr/local}
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREFIX=$("$PACKAGE_DIR/resolve-prefix.sh" "$PREFIX_INPUT")
LIBEXEC_DIR="$PREFIX/libexec/airpods-control"
BIN_DIR="$PREFIX/bin"
MAN_DIR="$PREFIX/share/man/man1"
COMMAND="$BIN_DIR/airpods-control"
EXPECTED_TARGET=../libexec/airpods-control/airpods-control

# The package-specific relative symlink is the ownership marker for upgrades.
if [ -e "$COMMAND" ] || [ -L "$COMMAND" ]; then
  if [ ! -L "$COMMAND" ] || [ "$(readlink "$COMMAND")" != "$EXPECTED_TARGET" ]; then
    echo "error: refusing to replace command not owned by this package: $COMMAND" >&2
    exit 1
  fi
fi

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
if [ ! -L "$COMMAND" ]; then
  ln -s "$EXPECTED_TARGET" "$COMMAND"
fi

echo "Installed airpods-control to $PREFIX"
