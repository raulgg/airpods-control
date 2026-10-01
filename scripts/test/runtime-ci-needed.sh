#!/bin/sh
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$DIR/../runtime-ci-needed.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -x "$SCRIPT" ] || fail "missing executable script: $SCRIPT"

expect() {
  expected=$1
  description=$2
  got=$("$SCRIPT")
  [ "$got" = "$expected" ] ||
    fail "$description: expected $expected, got $got"
}

expect false "empty diff" </dev/null

printf '%s\n' '"Sources/AirPodsControl/caf\303\251.swift"' |
  expect false "quoted git path is not a raw Sources path"

printf '%s\n' \
  'docs/cli.md' \
  'README.md' \
  'CONTRIBUTING.md' \
  'docs/man/airpods-control.1' \
  'docs/man/pods-control.1' \
  'version.txt' \
  'mise.toml' \
  'Package.swift' \
  'Tests/AirPodsControlTests/CLIParsingTests.swift' \
  'Tests/CLIContractTests/cli.sh' \
  'scripts/test/runtime-ci-needed.sh' \
  'scripts/verify-catalog.sh' \
  'foo/Makefile' \
  '.github/workflows/quality-checks.yml' |
  expect false "docs, unit tests, tooling, and unrelated paths"

while IFS= read -r path; do
  printf '%s\n' "$path" | expect true "$path"
done <<'EOF'
Sources
Sources/AirPodsControl/CLI.swift
Sources/AVBypass/bypass.c
Makefile
build.sh
scripts/verify-runtime.sh
scripts/runtime-ci-needed.sh
Tests/VerifyRuntimeTests
Tests/VerifyRuntimeTests/verify-runtime.sh
.github/workflows/macos-validation.yml
EOF

printf '%s\n' 'docs/cli.md' 'Sources/AirPodsControl/CLI.swift' |
  expect true "mixed docs and Sources"

echo "ok: runtime-ci-needed fixtures"
