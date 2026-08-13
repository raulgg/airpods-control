#!/bin/sh
set -eu

PREFIX_INPUT=${1:-/usr/local}
PACKAGE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PREFIX=$("$PACKAGE_DIR/resolve-prefix.sh" "$PREFIX_INPUT")
COMMAND="$PREFIX/bin/airpods-control"
EXPECTED_TARGET=../libexec/airpods-control/airpods-control

# Never remove a command unless this package's symlink proves ownership.
if [ -e "$COMMAND" ] || [ -L "$COMMAND" ]; then
  if [ ! -L "$COMMAND" ] || [ "$(readlink "$COMMAND")" != "$EXPECTED_TARGET" ]; then
    echo "error: refusing to remove command not owned by this package: $COMMAND" >&2
    exit 1
  fi
  rm -f "$COMMAND"
fi

rm -f \
  "$PREFIX/libexec/airpods-control/airpods-control" \
  "$PREFIX/libexec/airpods-control/avbypass.dylib"
rm -f "$PREFIX/share/man/man1/airpods-control.1"
rmdir "$PREFIX/libexec/airpods-control" 2>/dev/null || true

echo "Uninstalled airpods-control from $PREFIX"
