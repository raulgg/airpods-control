#!/bin/sh
# Build a Shields.io endpoint badge from Homebrew's public install analytics.
# The count is anonymous brew install events, not unique users.

set -eu

DEFAULT_FORMULA=raulgg/tap/airpods-control
DEFAULT_PERIOD=90d
DEFAULT_LABEL='brew installs'

usage() {
	die 2 "usage: $0 --analytics-file FILE [--formula NAME] [--period 90d] [--label TEXT] [--output FILE]"
}

die() {
	code=$1
	shift
	printf '%s\n' "$*" >&2
	exit "$code"
}

analytics_file=
formula=$DEFAULT_FORMULA
period=$DEFAULT_PERIOD
label=$DEFAULT_LABEL
output=

while [ "$#" -gt 0 ]; do
	case $1 in
		--analytics-file)
			[ "$#" -ge 2 ] || usage
			analytics_file=$2
			shift 2
			;;
		--formula)
			[ "$#" -ge 2 ] || usage
			formula=$2
			shift 2
			;;
		--period)
			[ "$#" -ge 2 ] || usage
			period=$2
			shift 2
			;;
		--label)
			[ "$#" -ge 2 ] || usage
			label=$2
			shift 2
			;;
		--output)
			[ "$#" -ge 2 ] || usage
			output=$2
			shift 2
			;;
		-h | --help)
			usage
			;;
		*)
			usage
			;;
	esac
done

[ -n "$analytics_file" ] || usage
[ -f "$analytics_file" ] || die 1 "error: analytics file not found: $analytics_file"
case $period in
	30d | 90d | 365d) ;;
	*)
		die 2 "error: period must be 30d, 90d, or 365d"
		;;
esac

command -v python3 >/dev/null 2>&1 || die 1 "error: python3 is required"

badge=$(FORMULA=$formula PERIOD=$period LABEL=$label python3 - "$analytics_file" <<'PY'
import json
import os
import sys

path = sys.argv[1]
formula = os.environ["FORMULA"]
period = os.environ["PERIOD"]
label = os.environ["LABEL"]

try:
    with open(path, encoding="utf-8") as fh:
        payload = json.load(fh)
except json.JSONDecodeError as exc:
    raise SystemExit(f"error: invalid analytics JSON: {exc}") from exc
except OSError as exc:
    raise SystemExit(f"error: cannot read analytics file: {exc}") from exc

if not isinstance(payload, dict):
    raise SystemExit("error: analytics JSON must be an object")

items = payload.get("items")
if not isinstance(items, list):
    raise SystemExit("error: analytics JSON must contain an items array")

total = 0
for item in items:
    if not isinstance(item, dict):
        raise SystemExit("error: analytics items must be objects")
    name = item.get("formula")
    if not isinstance(name, str):
        continue
    if name != formula and not name.startswith(formula + " "):
        continue
    raw = item.get("count", 0)
    if isinstance(raw, bool):
        raise SystemExit("error: invalid install count: %r" % (raw,))
    if isinstance(raw, int):
        count = raw
    elif isinstance(raw, str):
        digits = raw.replace(",", "").strip()
        if not digits.isdigit():
            raise SystemExit("error: invalid install count: %s" % raw)
        count = int(digits)
    else:
        raise SystemExit("error: invalid install count: %r" % (raw,))
    total += count

badge = {
    "schemaVersion": 1,
    "label": label,
    "message": "%s/%s" % (total, period),
    "color": "FBB040",
    "namedLogo": "homebrew",
    "logoColor": "black",
    "cacheSeconds": 3600,
}
json.dump(badge, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
)

if [ -n "$output" ]; then
	printf '%s\n' "$badge" >"$output"
else
	printf '%s\n' "$badge"
fi
