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

expect_status() {
	expected=$1
	description=$2
	shift 2

	set +e
	output=$("$@" 2>&1)
	status=$?
	set -e

	[ "$status" -eq "$expected" ] ||
		fail "$description: expected exit $expected, got $status (${output})"
}

[ -x "$SCRIPT" ] || fail "missing $SCRIPT"

expect_status 2 "unknown flag" "$SCRIPT" --nope
expect_status 9 "invalid version" "$SCRIPT" --from-tree --version not-a-version

(
	export CLT_CLANG=/nonexistent/clang
	export CLT_SWIFTC=/nonexistent/swiftc
	export CLT_WAIT_SECS=0
	expect_status 3 "missing CLT" "$SCRIPT" --from-tree
)

# Truncated download: drop the trailing invocation so the function is never called.
truncated=$TMP/truncated.sh
sed '$d' "$SCRIPT" >"$truncated"
expect_status 0 "truncated script is a no-op" sh "$truncated"

git_stub=$TMP/git-stub
mkdir -p "$git_stub"
cat >"$git_stub/git" <<'EOF'
#!/bin/sh
repo=.
while [ "$#" -gt 0 ]; do
	case $1 in
		-C)
			repo=$2
			shift 2
			;;
		-c)
			shift 2
			;;
		-q | --quiet)
			shift
			;;
		*)
			break
			;;
	esac
done
cmd=${1:-}
[ "$#" -gt 0 ] && shift
case $cmd in
	init)
		mkdir -p "$repo/.git"
		exit 0
		;;
	remote)
		exit 0
		;;
	fetch)
		if [ "${FAKE_GIT_MODE-}" = fail-fetch ]; then
			printf 'fatal: fake clone failure\n' >&2
			exit 1
		fi
		mkdir -p "$repo/scripts"
		printf '0.3.0\n' >"$repo/version.txt"
		exit 0
		;;
	checkout)
		exit 0
		;;
	*)
		printf 'unexpected git command: %s\n' "$cmd" >&2
		exit 1
		;;
esac
EOF
chmod +x "$git_stub/git"

set +e
output=$(
	PATH="$git_stub:$PATH" FAKE_GIT_MODE=fail-fetch \
		"$SCRIPT" --prefix "$TMP/fetch-fail" 2>&1
)
status=$?
set -e
[ "$status" -eq 6 ] ||
	fail "clone failure surfaces git stderr: expected exit 6, got $status (${output})"
printf '%s\n' "$output" | grep -q "fatal: fake clone failure" ||
	fail "clone.err was not printed: $output"
printf '%s\n' "$output" | grep -q "git fetch of v0.3.0 failed" ||
	fail "fetch failure message missing: $output"

set +e
output=$(
	PATH="$git_stub:$PATH" "$SCRIPT" --prefix "$TMP/from-clone" 2>&1
)
status=$?
set -e
[ "$status" -eq 8 ] ||
	fail "clone missing resolver: expected exit 8, got $status (${output})"
printf '%s\n' "$output" | grep -q "this installer is not in v0.3.0" ||
	fail "missing-installer message missing: $output"

PREFIX="$TMP/nested install"
mkdir -p "$PREFIX"

repo_binary=$ROOT/build/airpods-control
repo_binary_existed=0
before_sum=
if [ -f "$repo_binary" ]; then
	repo_binary_existed=1
	before_sum=$(cksum <"$repo_binary")
fi

"$SCRIPT" --from-tree --prefix "$PREFIX" >/dev/null
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
output=$("$SCRIPT" --from-tree --prefix "$PREFIX" 2>&1) ||
	fail "upgrade aborted when old --version failed: $output"
printf '%s\n' "$output" | grep -q "installed $expected_version prefix=" ||
	fail "upgrade success line missing: $output"

foreign=$TMP/foreign
mkdir -p "$foreign/bin"
printf 'nope\n' >"$foreign/bin/airpods-control"
expect_status 5 "foreign binary" "$SCRIPT" --from-tree --prefix "$foreign"

stub=$TMP/stub
brew_root=$TMP/brew-root
mkdir -p "$stub" "$brew_root"
printf '#!/bin/sh\n' >"$stub/brew"
printf 'if [ "$1" = list ]; then exit 0; fi\n' >>"$stub/brew"
printf 'if [ "$1" = --prefix ]; then echo %s; exit 0; fi\n' "$brew_root" >>"$stub/brew"
printf 'exit 1\n' >>"$stub/brew"
chmod +x "$stub/brew"

(
	export BREW="$stub/brew"
	expect_status 4 "brew prefix collision" \
		"$SCRIPT" --from-tree --prefix "$brew_root"
)

collide=$TMP/other-prefix
mkdir -p "$collide"
output=$(
	export BREW="$stub/brew"
	"$SCRIPT" --from-tree --prefix "$collide" 2>&1
) || fail "brew warn path should still install: $output"
printf '%s\n' "$output" | grep -q "warning: Homebrew has airpods-control" ||
	fail "expected brew warning: $output"

rm -f "$PREFIX/libexec/airpods-control/airpods-control.real"
output=$(
	export CLT_CLANG=/nonexistent/clang
	export CLT_SWIFTC=/nonexistent/swiftc
	export CLT_WAIT_SECS=0
	export BREW="$stub/brew"
	"$SCRIPT" --from-tree --prefix "$PREFIX" --uninstall 2>&1
) || fail "uninstall without CLT failed: $output"
printf '%s\n' "$output" | grep -q "uninstalled prefix=" ||
	fail "uninstall success line missing: $output"
if printf '%s\n' "$output" | grep -qi "Command Line Tools"; then
	fail "uninstall probed CLT: $output"
fi
if printf '%s\n' "$output" | grep -q "installing to"; then
	fail "uninstall warned about Homebrew: $output"
fi
[ ! -e "$PREFIX/bin/airpods-control" ] || fail "uninstall left the command"

echo "ok: install-from-source fixtures"
