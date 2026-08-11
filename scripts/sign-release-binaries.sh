#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_DIR=${BUILD_DIR:-$ROOT/build}
CODESIGN_IDENTITY=${CODESIGN_IDENTITY:?CODESIGN_IDENTITY is required}
CODESIGN_KEYCHAIN=${CODESIGN_KEYCHAIN:-}
ENTITLEMENTS="$ROOT/packaging/release.entitlements"
EXPECTED_ENTITLEMENT=com.apple.security.cs.allow-dyld-environment-variables
BINARY="$BUILD_DIR/airpods-control"
DYLIB="$BUILD_DIR/avbypass.dylib"

[ -x "$BINARY" ] || {
  echo "error: missing executable: $BINARY" >&2
  exit 1
}
[ -f "$DYLIB" ] || {
  echo "error: missing dylib: $DYLIB" >&2
  exit 1
}
[ -f "$ENTITLEMENTS" ] || {
  echo "error: missing entitlements: $ENTITLEMENTS" >&2
  exit 1
}

validate_entitlements() {
  file=$1
  label=$2

  plutil -lint "$file" >/dev/null
  dictionary=$(/usr/libexec/PlistBuddy -c Print "$file")
  key_count=$(printf '%s\n' "$dictionary" | grep -Ec ' = ' || true)
  if [ "$key_count" -ne 1 ]; then
    echo "error: $label must contain exactly one entitlement" >&2
    exit 1
  fi
  value=$(/usr/libexec/PlistBuddy -c "Print :$EXPECTED_ENTITLEMENT" "$file")
  if [ "$value" != true ]; then
    echo "error: $label must enable $EXPECTED_ENTITLEMENT" >&2
    exit 1
  fi
  if grep -Fq 'com.apple.security.cs.disable-library-validation' "$file"; then
    echo "error: $label disables library validation" >&2
    exit 1
  fi
}

validate_entitlements "$ENTITLEMENTS" "release entitlements"

timestamp=--timestamp
if [ "$CODESIGN_IDENTITY" = "-" ]; then
  timestamp=--timestamp=none
fi

sign() {
  if [ -n "$CODESIGN_KEYCHAIN" ]; then
    codesign "$@" --keychain "$CODESIGN_KEYCHAIN"
  else
    codesign "$@"
  fi
}

sign --force --options runtime "$timestamp" \
  --identifier com.raulgg.airpods-control.avbypass \
  --sign "$CODESIGN_IDENTITY" "$DYLIB"
sign --force --options runtime "$timestamp" \
  --identifier com.raulgg.airpods-control \
  --entitlements "$ENTITLEMENTS" \
  --sign "$CODESIGN_IDENTITY" "$BINARY"

codesign --verify --strict --verbose=2 "$DYLIB"
codesign --verify --strict --verbose=2 "$BINARY"

SIGNED_ENTITLEMENTS=${TMPDIR:-/tmp}/airpods-control-signed-entitlements.plist
DYLIB_ENTITLEMENTS=${TMPDIR:-/tmp}/airpods-control-dylib-entitlements.plist
rm -f "$SIGNED_ENTITLEMENTS" "$DYLIB_ENTITLEMENTS"
codesign -d --entitlements - --xml "$BINARY" >"$SIGNED_ENTITLEMENTS" 2>/dev/null
validate_entitlements "$SIGNED_ENTITLEMENTS" "signed executable"
codesign -d --entitlements - --xml "$DYLIB" >"$DYLIB_ENTITLEMENTS" 2>/dev/null || true
if [ -s "$DYLIB_ENTITLEMENTS" ]; then
  dylib_dictionary=$(/usr/libexec/PlistBuddy -c Print "$DYLIB_ENTITLEMENTS")
  dylib_key_count=$(printf '%s\n' "$dylib_dictionary" | grep -Ec ' = ' || true)
  if [ "$dylib_key_count" -ne 0 ]; then
    echo "error: signed dylib must not contain entitlements" >&2
    exit 1
  fi
fi
rm -f "$SIGNED_ENTITLEMENTS" "$DYLIB_ENTITLEMENTS"

if [ "$CODESIGN_IDENTITY" != "-" ]; then
  binary_team=$(codesign -dv --verbose=4 "$BINARY" 2>&1 |
    sed -n 's/^TeamIdentifier=//p')
  dylib_team=$(codesign -dv --verbose=4 "$DYLIB" 2>&1 |
    sed -n 's/^TeamIdentifier=//p')
  [ -n "$binary_team" ]
  [ "$binary_team" = "$dylib_team" ] || {
    echo "error: executable and dylib TeamIdentifiers differ" >&2
    exit 1
  }
fi

echo "Signed release binaries with $CODESIGN_IDENTITY"
