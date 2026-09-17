#!/bin/sh
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCRIPT="$DIR/runtime-ci-needed.sh"

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

printf '%s\n' 'docs/cli.md' 'README.md' 'CONTRIBUTING.md' |
  expect false "docs-only"

printf '%s\n' \
  'Tests/AirPodsControlTests/CLIParsingTests.swift' \
  'Tests/CLIContractTests/cli.sh' \
  'Package.swift' |
  expect false "unit-test-only"

printf '%s\n' 'Sources/AirPodsControl/CLI.swift' |
  expect true "Sources change"

printf '%s\n' 'Sources/AVBypass/bypass.c' |
  expect true "interpose source"

printf '%s\n' 'Makefile' |
  expect true "Makefile"

printf '%s\n' 'build.sh' |
  expect true "build.sh"

printf '%s\n' 'scripts/verify-runtime.sh' |
  expect true "verify-runtime script"

printf '%s\n' 'scripts/runtime-ci-needed.sh' |
  expect true "classifier script"

printf '%s\n' 'scripts/runtime-ci-needed.test.sh' |
  expect false "classifier tests"

printf '%s\n' 'Tests/VerifyRuntimeTests/verify-runtime.sh' |
  expect true "verify-runtime tests"

printf '%s\n' '.github/workflows/macos-validation.yml' |
  expect true "validation workflow"

printf '%s\n' 'docs/cli.md' 'Sources/AirPodsControl/CLI.swift' |
  expect true "mixed docs and Sources"

printf '%s\n' 'docs/man/airpods-control.1' 'version.txt' 'mise.toml' |
  expect false "man page version and tooling"

printf '%s\n' '.github/workflows/quality-checks.yml' |
  expect false "unrelated workflow"

printf '%s\n' 'foo/Makefile' 'scripts/verify-catalog.sh' |
  expect false "unrelated Makefile path and catalog script"

printf '%s\n' 'Sources' |
  expect true "Sources directory"

echo "ok: runtime-ci-needed fixtures"
