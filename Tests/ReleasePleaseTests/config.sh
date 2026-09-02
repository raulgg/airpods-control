#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CONFIG="$ROOT/release-please-config.json"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

[ -f "$CONFIG" ] || fail "missing $CONFIG"

python3 - "$CONFIG" <<'PY' || fail "release-please-config.json changelog-sections"
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    cfg = json.load(fh)

sections = cfg.get("changelog-sections")
if not isinstance(sections, list) or not sections:
    raise SystemExit("missing changelog-sections")

by_type = {}
for item in sections:
    if not isinstance(item, dict) or "type" not in item or "section" not in item:
        raise SystemExit("changelog-sections entries need type and section")
    by_type[item["type"]] = item

for commit_type in (
    "ci",
    "chore",
    "test",
    "docs",
    "build",
    "style",
    "refactor",
):
    item = by_type.get(commit_type)
    if item is None:
        raise SystemExit(f"missing section {commit_type}")
    if item.get("hidden") is not True:
        raise SystemExit(f"{commit_type} must be hidden")

for commit_type in ("feat", "fix"):
    item = by_type.get(commit_type)
    if item is None:
        raise SystemExit(f"missing section {commit_type}")
    if item.get("hidden") is True:
        raise SystemExit(f"{commit_type} must stay visible")

if cfg.get("draft-pull-request") is not True:
    raise SystemExit("draft-pull-request must be true")
if cfg.get("always-update") is not True:
    raise SystemExit("always-update must be true")
PY

echo "ok: release-please changelog-sections"
