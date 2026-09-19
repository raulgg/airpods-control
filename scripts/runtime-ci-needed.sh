#!/bin/sh
# Print true if any stdin path should run the Intel and macOS 26 runtime
# jobs. Those jobs exist to catch DYLD interpose and private-API breakage
# on a host that is not the macOS 15 test runner.
set -eu

needed=false
while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  case "$path" in
    Sources | Sources/* | \
    Makefile | \
    build.sh | \
    scripts/verify-runtime.sh | \
    scripts/runtime-ci-needed.sh | \
    Tests/VerifyRuntimeTests | Tests/VerifyRuntimeTests/* | \
    .github/workflows/macos-validation.yml)
      needed=true
      ;;
  esac
done

printf '%s\n' "$needed"
