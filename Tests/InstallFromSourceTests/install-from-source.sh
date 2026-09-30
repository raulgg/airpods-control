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
if [ "$1" = list ]; then
	[ "$2" = --formula ] || exit 1
	name=$3
	for owned in ${FAKE_BREW_FORMULAS:-pods-control}; do
		[ "$name" = "$owned" ] && exit 0
	done
	exit 1
fi
if [ "$1" = --prefix ]; then
	printf '%s\n' "$FAKE_BREW_PREFIX"
	exit 0
fi
exit 1
EOF
chmod +x "$stub/brew"

assert_new_layout() {
	prefix=$1
	[ -L "$prefix/bin/pods-control" ] ||
		fail "missing pods-control symlink in $prefix"
	[ -L "$prefix/bin/airpods-control" ] ||
		fail "missing airpods-control symlink in $prefix"
	[ "$(readlink "$prefix/bin/pods-control")" = \
		"../libexec/pods-control/pods-control" ] ||
		fail "pods-control symlink target in $prefix"
	[ "$(readlink "$prefix/bin/airpods-control")" = \
		"../libexec/pods-control/pods-control" ] ||
		fail "airpods-control symlink target in $prefix"
	[ -x "$prefix/libexec/pods-control/pods-control" ] ||
		fail "missing libexec binary in $prefix"
	[ -f "$prefix/libexec/pods-control/avbypass.dylib" ] ||
		fail "missing avbypass.dylib in $prefix"
	[ ! -e "$prefix/libexec/airpods-control" ] ||
		fail "legacy libexec remains in $prefix"
	[ -f "$prefix/share/man/man1/pods-control.1" ] ||
		fail "missing pods-control man page in $prefix"
	[ -f "$prefix/share/man/man1/airpods-control.1" ] ||
		fail "missing airpods-control man page in $prefix"
	got=$("$prefix/bin/pods-control" --version 2>"$TMP/version.err") ||
		fail "pods-control --version failed in $prefix"
	[ ! -s "$TMP/version.err" ] ||
		fail "pods-control --version wrote stderr in $prefix"
	[ "$got" = "$expected_version" ] ||
		fail "pods-control version $got in $prefix, expected $expected_version"
	got=$("$prefix/bin/airpods-control" --version 2>"$TMP/version.err") ||
		fail "airpods-control --version failed in $prefix"
	[ ! -s "$TMP/version.err" ] ||
		fail "compat command wrote stderr in $prefix: $(cat "$TMP/version.err")"
	[ "$got" = "$expected_version" ] ||
		fail "airpods-control version $got in $prefix, expected $expected_version"
}

assert_removed() {
	prefix=$1
	[ ! -e "$prefix/bin/pods-control" ] ||
		fail "uninstall left pods-control in $prefix"
	[ ! -e "$prefix/bin/airpods-control" ] ||
		fail "uninstall left airpods-control in $prefix"
	[ ! -e "$prefix/libexec/pods-control" ] ||
		fail "uninstall left new libexec in $prefix"
	[ ! -e "$prefix/libexec/airpods-control" ] ||
		fail "uninstall left legacy libexec in $prefix"
	[ ! -e "$prefix/share/man/man1/pods-control.1" ] ||
		fail "uninstall left pods-control man page in $prefix"
	[ ! -e "$prefix/share/man/man1/airpods-control.1" ] ||
		fail "uninstall left airpods-control man page in $prefix"
}

PREFIX="$TMP/nested install"
mkdir -p "$PREFIX"
expected_version=$(tr -d '[:space:]' <"$ROOT/version.txt")

repo_binary=$ROOT/build/pods-control
repo_binary_existed=0
before_sum=
if [ -f "$repo_binary" ]; then
	repo_binary_existed=1
	before_sum=$(cksum <"$repo_binary")
fi

BREW="$stub/brew" FAKE_BREW_PREFIX="$brew_root" \
	"$SCRIPT" --from-tree --prefix "$PREFIX" >/dev/null 2>&1
assert_new_layout "$PREFIX"

"$PREFIX/bin/pods-control" --help >"$TMP/help.out" 2>"$TMP/help.err"
[ ! -s "$TMP/help.err" ] || fail "help wrote stderr"
grep -q 'airpods-control is the same command' "$TMP/help.out" ||
	fail "help does not document the compat command"
if grep -i -q 'deprecat' "$TMP/help.out" "$TMP/help.err"; then
	fail "help deprecates the compat command"
fi

if ! MANPAGER=cat PAGER=cat man -M "$PREFIX/share/man" pods-control \
	>"$TMP/man-pods.out" 2>"$TMP/man-pods.err"; then
	fail "man pods-control failed: $(cat "$TMP/man-pods.err")"
fi
grep -q pods-control "$TMP/man-pods.out" ||
	fail "man pods-control did not name the command"
if ! MANPAGER=cat PAGER=cat man -M "$PREFIX/share/man" airpods-control \
	>"$TMP/man-alias.out" 2>"$TMP/man-alias.err"; then
	fail "man airpods-control failed: $(cat "$TMP/man-alias.err")"
fi
grep -q pods-control "$TMP/man-alias.out" ||
	fail "man airpods-control did not show the pods-control page"

if [ "$repo_binary_existed" -eq 1 ]; then
	after_sum=$(cksum <"$repo_binary")
	[ "$before_sum" = "$after_sum" ] ||
		fail "installer clobbered $repo_binary"
else
	[ ! -f "$repo_binary" ] ||
		fail "installer created $repo_binary"
fi

old_prefix=$TMP/old-layout
mkdir -p "$old_prefix/bin" "$old_prefix/libexec/airpods-control"
printf '%s\n' '#!/bin/sh' "printf '%s\\n' 0.0.1" \
	>"$old_prefix/libexec/airpods-control/airpods-control"
chmod +x "$old_prefix/libexec/airpods-control/airpods-control"
ln -s ../libexec/airpods-control/airpods-control \
	"$old_prefix/bin/airpods-control"
output=$(BREW="$stub/brew" FAKE_BREW_PREFIX="$brew_root" \
	"$SCRIPT" --from-tree --prefix "$old_prefix" 2>&1) ||
	fail "old-layout upgrade failed: $output"
printf '%s\n' "$output" | grep -q 'upgraded from 0.0.1' ||
	fail "old-layout upgrade did not report the previous version: $output"
assert_new_layout "$old_prefix"

# Upgrade over an owned install whose binary cannot report a version.
mv "$PREFIX/libexec/pods-control/pods-control" \
	"$PREFIX/libexec/pods-control/pods-control.real"
printf '#!/bin/sh\nexit 1\n' >"$PREFIX/libexec/pods-control/pods-control"
chmod +x "$PREFIX/libexec/pods-control/pods-control"
output=$(BREW="$stub/brew" FAKE_BREW_PREFIX="$brew_root" \
	"$SCRIPT" --from-tree --prefix "$PREFIX" 2>&1) ||
	fail "upgrade aborted when old --version failed: $output"
assert_new_layout "$PREFIX"

foreign_legacy=$TMP/foreign-legacy
mkdir -p "$foreign_legacy/bin"
printf 'nope\n' >"$foreign_legacy/bin/airpods-control"
expect_failure "foreign legacy command" \
	"$SCRIPT" --from-tree --prefix "$foreign_legacy"
[ "$(cat "$foreign_legacy/bin/airpods-control")" = nope ] ||
	fail "installer changed a foreign airpods-control command"

foreign_new=$TMP/foreign-new
mkdir -p "$foreign_new/bin"
printf 'nope\n' >"$foreign_new/bin/pods-control"
expect_failure "foreign pods-control command" \
	"$SCRIPT" --from-tree --prefix "$foreign_new"
[ "$(cat "$foreign_new/bin/pods-control")" = nope ] ||
	fail "installer changed a foreign pods-control command"

BREW="$stub/brew" FAKE_BREW_PREFIX="$brew_root" \
	expect_failure "Homebrew-owned prefix" \
	"$SCRIPT" --from-tree --prefix "$brew_root"
grep -q 'brew upgrade pods-control' "$TMP/failure.out" ||
	fail "Homebrew conflict omitted brew upgrade pods-control: $(cat "$TMP/failure.out")"
grep -q 'brew upgrade airpods-control' "$TMP/failure.out" ||
	fail "Homebrew conflict omitted brew upgrade airpods-control: $(cat "$TMP/failure.out")"
grep -q 'owns pods-control' "$TMP/failure.out" ||
	fail "Homebrew conflict did not name pods-control: $(cat "$TMP/failure.out")"
[ ! -e "$brew_root/bin/pods-control" ] ||
	fail "installer replaced the Homebrew-owned command"
[ ! -e "$brew_root/bin/airpods-control" ] ||
	fail "installer created a compat command in the Homebrew prefix"

FAKE_BREW_FORMULAS=airpods-control BREW="$stub/brew" \
	FAKE_BREW_PREFIX="$brew_root" \
	expect_failure "Homebrew-owned legacy formula" \
	"$SCRIPT" --from-tree --prefix "$brew_root"
grep -q 'owns airpods-control' "$TMP/failure.out" ||
	fail "legacy Homebrew conflict did not name airpods-control: $(cat "$TMP/failure.out")"
grep -q 'brew upgrade pods-control or brew upgrade airpods-control' \
	"$TMP/failure.out" ||
	fail "legacy Homebrew conflict omitted both upgrade commands: $(cat "$TMP/failure.out")"
[ ! -e "$brew_root/bin/pods-control" ] ||
	fail "legacy Homebrew conflict installed pods-control"
[ ! -e "$brew_root/bin/airpods-control" ] ||
	fail "legacy Homebrew conflict installed airpods-control"

rm -f "$PREFIX/libexec/pods-control/pods-control.real"
(
	export CLT_CLANG=/nonexistent/clang
	export CLT_SWIFTC=/nonexistent/swiftc
	export CLT_WAIT_SECS=0
	export BREW="$stub/brew"
	export FAKE_BREW_PREFIX="$PREFIX"
	"$SCRIPT" --from-tree --prefix "$PREFIX" --uninstall >/dev/null 2>&1
) || fail "uninstall consulted install-only prerequisites"
assert_removed "$PREFIX"
(
	export CLT_CLANG=/nonexistent/clang
	export CLT_SWIFTC=/nonexistent/swiftc
	export CLT_WAIT_SECS=0
	export BREW="$stub/brew"
	export FAKE_BREW_PREFIX="$old_prefix"
	"$SCRIPT" --from-tree --prefix "$old_prefix" --uninstall >/dev/null 2>&1
) || fail "old-layout uninstall failed"
assert_removed "$old_prefix"

echo "ok: install-from-source fixtures"
