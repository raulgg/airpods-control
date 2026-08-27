#!/bin/sh
set -eu

# Release Please tags a merged release PR only if the live GitHub body still
# matches its parser: a line that is exactly "---", then notes whose first
# heading is "## [X.Y.Z]" (or "## X.Y.Z"). See
# googleapis/release-please src/util/pull-request-body.ts.

usage() {
  echo "usage: $0 <body-file>" >&2
  echo "       $0  (read body from stdin)" >&2
  exit 1
}

if [ "$#" -gt 1 ]; then
	usage
fi

if [ "$#" -eq 1 ]; then
	if [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
		usage
	fi
	body=$(tr -d '\r' <"$1")
else
	body=$(tr -d '\r')
fi

notes=$(printf '%s\n' "$body" | awk '
  $0 == "---" { found = 1; next }
  found { print }
  END { if (!found) exit 1 }
') || {
	echo "error: pull request body has no --- delimiter line" >&2
	exit 1
}

heading=$(printf '%s\n' "$notes" | sed '/[^[:space:]]/,$!d' | sed -n '1p')
if ! printf '%s\n' "$heading" | grep -Eq '^#{2,} \[?[0-9]+\.[0-9]+\.[0-9]+'; then
	echo "error: notes after --- must start with a ## [X.Y.Z] heading" >&2
	exit 1
fi
