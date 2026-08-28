#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 PREFIX" >&2
  exit 1
fi

prefix=$1

case "$prefix" in
  /*) ;;
  *)
    echo "error: PREFIX must be an absolute path" >&2
    exit 1
    ;;
esac

case "$prefix" in
  / | *//* | */./* | */. | */../* | */..)
    echo "error: PREFIX must not be root or contain . or .. components: $prefix" >&2
    exit 1
    ;;
esac

while [ "$prefix" != / ] && [ "${prefix%/}" != "$prefix" ]; do
  prefix=${prefix%/}
done

candidate=$prefix
suffix=
while [ ! -d "$candidate" ]; do
  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    echo "error: PREFIX path component is not a directory: $candidate" >&2
    exit 1
  fi
  component=${candidate##*/}
  suffix="/$component$suffix"
  candidate=${candidate%/*}
  [ -n "$candidate" ] || candidate=/
done

resolved=$(CDPATH= cd -P -- "$candidate" && pwd -P)
resolved="${resolved%/}$suffix"
[ -n "$resolved" ] || resolved=/
if [ "$resolved" = / ]; then
  echo "error: PREFIX resolves to root: $1" >&2
  exit 1
fi

printf '%s\n' "$resolved"
