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

rm -f "$PREFIX/bin/airpods-control"
rm -f \
  "$PREFIX/libexec/airpods-control/airpods-control" \
  "$PREFIX/libexec/airpods-control/avbypass.dylib"
rm -f "$PREFIX/share/man/man1/airpods-control.1"
rmdir "$PREFIX/libexec/airpods-control" 2>/dev/null || true

echo "Uninstalled airpods-control from $PREFIX"
