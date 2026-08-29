#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/install-from-source.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

tmp_base=${TMPDIR:-/tmp}
tmp_base=${tmp_base%/}
TMP=$(mktemp -d "$tmp_base/install-from-source.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

expect_failure() {
	description=$1
	shift
	if "$@" >"$TMP/failure.out" 2>&1; then
		fail "$description: command unexpectedly succeeded"
	fi
}

[ -x "$SCRIPT" ] || fail "missing $SCRIPT"

(
	export CLT_CLANG=/nonexistent/clang
	export CLT_SWIFTC=/nonexistent/swiftc
	export CLT_WAIT_SECS=0
	expect_failure "install without developer tools" "$SCRIPT" --from-tree
)

# Truncated download: drop the trailing invocation so the function is never called.
truncated=$TMP/truncated.sh
sed '$d' "$SCRIPT" >"$truncated"
sh "$truncated" || fail "truncated script should be a no-op"

stub=$TMP/stub
brew_root=$TMP/brew-root
mkdir -p "$stub" "$brew_root"
cat >"$stub/brew" <<'EOF'
#!/bin/sh
[ "$1" = list ] && exit 0
[ "$1" = --prefix ] && printf '%s\n' "$FAKE_BREW_PREFIX"
EOF
chmod +x "$stub/brew"

PREFIX="$TMP/nested install"
mkdir -p "$PREFIX"

repo_binary=$ROOT/build/airpods-control
repo_binary_existed=0
before_sum=
if [ -f "$repo_binary" ]; then
	repo_binary_existed=1
	before_sum=$(cksum <"$repo_binary")
fi

BREW="$stub/brew" FAKE_BREW_PREFIX="$brew_root" \
	"$SCRIPT" --from-tree --prefix "$PREFIX" >/dev/null 2>&1
[ -L "$PREFIX/bin/airpods-control" ] || fail "install did not create symlink"
expected_version=$(tr -d '[:space:]' <"$ROOT/version.txt")
got=$("$PREFIX/bin/airpods-control" --version) || fail "installed binary did not run"
[ "$got" = "$expected_version" ] ||
	fail "installed version $got, expected $expected_version"

if [ "$repo_binary_existed" -eq 1 ]; then
	after_sum=$(cksum <"$repo_binary")
	[ "$before_sum" = "$after_sum" ] ||
		fail "installer clobbered $repo_binary"
else
	[ ! -f "$repo_binary" ] ||
		fail "installer created $repo_binary"
fi

# Upgrade over an owned install whose binary cannot report a version.
mv "$PREFIX/libexec/airpods-control/airpods-control" \
	"$PREFIX/libexec/airpods-control/airpods-control.real"
printf '#!/bin/sh\nexit 1\n' >"$PREFIX/libexec/airpods-control/airpods-control"
chmod +x "$PREFIX/libexec/airpods-control/airpods-control"
output=$(BREW="$stub/brew" FAKE_BREW_PREFIX="$brew_root" \
	"$SCRIPT" --from-tree --prefix "$PREFIX" 2>&1) ||
	fail "upgrade aborted when old --version failed: $output"
got=$("$PREFIX/bin/airpods-control" --version) ||
	fail "repaired binary did not run"
[ "$got" = "$expected_version" ] ||
	fail "repaired binary reported $got, expected $expected_version"

foreign=$TMP/foreign
mkdir -p "$foreign/bin"
printf 'nope\n' >"$foreign/bin/airpods-control"
expect_failure "foreign binary" "$SCRIPT" --from-tree --prefix "$foreign"
[ "$(cat "$foreign/bin/airpods-control")" = nope ] ||
	fail "installer changed a foreign command"

BREW="$stub/brew" FAKE_BREW_PREFIX="$brew_root" \
	expect_failure "Homebrew-owned prefix" \
	"$SCRIPT" --from-tree --prefix "$brew_root"
[ ! -e "$brew_root/bin/airpods-control" ] ||
	fail "installer replaced the Homebrew-owned command"

rm -f "$PREFIX/libexec/airpods-control/airpods-control.real"
(
	export CLT_CLANG=/nonexistent/clang
	export CLT_SWIFTC=/nonexistent/swiftc
	export CLT_WAIT_SECS=0
	export BREW="$stub/brew"
	export FAKE_BREW_PREFIX="$PREFIX"
	"$SCRIPT" --from-tree --prefix "$PREFIX" --uninstall >/dev/null 2>&1
) || fail "uninstall consulted install-only prerequisites"
[ ! -e "$PREFIX/bin/airpods-control" ] || fail "uninstall left the command"

echo "ok: install-from-source fixtures"
