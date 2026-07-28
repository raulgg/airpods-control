#!/bin/sh
# Diffs the product catalog in Sources/AirPodsControl/AppleAudioProducts.swift
# against the Bluetooth product IDs macOS declares in its CoreTypes bundles.
#
# macOS tags each known accessory with public.bluetooth-vendor-product-id in
# /System/Library/CoreServices/CoreTypes.bundle/Contents/Library/CoreTypes-NNNN
# .bundle/Contents/Info.plist. That is first-party data, refreshed with every
# system update, so it is the closest thing to an authoritative list.
#
# This is deliberately not part of `make test`: the answer depends on the
# macOS version of whoever runs it, and older systems legitimately describe
# fewer products. Run it when adding hardware or after a major system upgrade.

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
catalog="$root/Sources/AirPodsControl/AppleAudioProducts.swift"
coretypes=/System/Library/CoreServices/CoreTypes.bundle/Contents/Library

if [ ! -f "$catalog" ]; then
  echo "error: catalog not found at $catalog" >&2
  exit 1
fi

if [ ! -d "$coretypes" ]; then
  echo "error: CoreTypes bundles not found at $coretypes" >&2
  echo "       This system does not publish the pairings; nothing to verify." >&2
  exit 1
fi

exec /usr/bin/python3 - "$catalog" "$coretypes" <<'PY'
import glob
import json
import os
import re
import subprocess
import sys

catalog_path, coretypes_dir = sys.argv[1], sys.argv[2]

# Apple's Bluetooth vendor ID. Anything else is another manufacturer.
APPLE_VENDOR = 76
# CoreTypes describes keyboards, remotes and tags too; keep the audio lines.
AUDIO = re.compile(r"airpods|beats", re.IGNORECASE)
# Bundles predating this product ID do not carry the pairing tags at all.
CORETYPES_FLOOR = 0x2014

catalog = {}
entry = re.compile(r'^\s*0x([0-9A-Fa-f]{4}):\s*\(\.\w+,\s*"([^"]+)"\)')
with open(catalog_path) as handle:
    for line in handle:
        found = entry.match(line)
        if found:
            catalog[int(found.group(1), 16)] = found.group(2)

system = {}
pattern = os.path.join(coretypes_dir, "*.bundle", "Contents", "Info.plist")
for path in glob.glob(pattern):
    converted = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", path],
        capture_output=True, text=True,
    )
    if converted.returncode != 0:
        continue
    try:
        plist = json.loads(converted.stdout)
    except ValueError:
        continue
    declarations = plist.get("UTExportedTypeDeclarations", [])
    declarations += plist.get("UTImportedTypeDeclarations", [])
    for declaration in declarations:
        identifier = declaration.get("UTTypeIdentifier", "")
        tags = declaration.get("UTTypeTagSpecification", {})
        pairs = tags.get("public.bluetooth-vendor-product-id", [])
        if isinstance(pairs, str):
            pairs = [pairs]
        for pair in pairs:
            parsed = re.match(r"^(\d+):(\d+)$", pair)
            if not parsed:
                continue
            vendor, product = int(parsed.group(1)), int(parsed.group(2))
            if vendor == APPLE_VENDOR and AUDIO.search(identifier):
                system[product] = identifier

missing = sorted(set(system) - set(catalog))
unconfirmed = sorted(
    product for product in set(catalog) - set(system)
    if product >= CORETYPES_FLOOR
)
older = sorted(product for product in set(catalog) - set(system)
               if product < CORETYPES_FLOOR)

print("catalog entries:      %d" % len(catalog))
print("audio pairings found: %d" % len(system))
print()

if missing:
    print("MISSING from the catalog (macOS knows these, the CLI does not):")
    for product in missing:
        print("  0x%04X (%d)  %s" % (product, product, system[product]))
    print()

if unconfirmed:
    print("In the catalog but absent from this system's CoreTypes:")
    for product in unconfirmed:
        print("  0x%04X (%d)  %s" % (product, product, catalog[product]))
    print("  These are newer than 0x%04X, so they should normally appear."
          % CORETYPES_FLOOR)
    print("  A newer macOS may simply not describe them yet.")
    print()

if older:
    print("Predating CoreTypes coverage, not checkable here: %s"
          % ", ".join("0x%04X" % product for product in older))
    print()

if missing:
    print("Add the entries above, then rerun.")
    sys.exit(1)

print("No gaps: every audio pairing this system declares is in the catalog.")
PY
