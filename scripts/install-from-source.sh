#!/bin/sh
# Fetch, compile, and install (or replace) airpods-control from a Git tag.
# Wrap work in a function so a truncated curl | sh download does nothing.

install_from_source() {
	set -eu

	REPO_HTTPS=https://github.com/raulgg/airpods-control.git
	RELEASES_LATEST=https://github.com/raulgg/airpods-control/releases/latest
	FORMULA_NAME=airpods-control
	EXPECTED_SYMLINK=../libexec/airpods-control/airpods-control
	CLANG=/usr/bin/clang
	SWIFTC=/usr/bin/swiftc
	LIPO=/usr/bin/lipo
	CODESIGN=/usr/bin/codesign
	CLT_CLANG=${CLT_CLANG:-$CLANG}
	CLT_SWIFTC=${CLT_SWIFTC:-$SWIFTC}
	CLT_WAIT_SECS=${CLT_WAIT_SECS:-300}

	SCRIPT_VERSION=0.3.0 # x-release-please-version

	E_USAGE=2
	E_CLT=3
	E_BREW=4
	E_FOREIGN=5
	E_FETCH=6
	E_BUILD=7
	E_PREFIX=8
	E_VERSION=9

	die() {
		code=$1
		shift
		printf '%s\n' "$*" >&2
		exit "$code"
	}

	usage() {
		die "$E_USAGE" "usage: install-from-source.sh [--version vX.Y.Z|latest] [--prefix DIR] [--from-tree] [--uninstall]"
	}

	version_arg=
	prefix_arg=/usr/local
	from_tree=0
	do_uninstall=0

	while [ "$#" -gt 0 ]; do
		case $1 in
			--version)
				[ "$#" -ge 2 ] || usage
				version_arg=$2
				shift 2
				;;
			--prefix)
				[ "$#" -ge 2 ] || usage
				prefix_arg=$2
				shift 2
				;;
			--from-tree)
				from_tree=1
				shift
				;;
			--uninstall)
				do_uninstall=1
				shift
				;;
			-h | --help)
				usage
				;;
			*)
				usage
				;;
		esac
	done

	script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || script_dir=
	repo_root=
	if [ -n "$script_dir" ] && [ -f "$script_dir/../version.txt" ]; then
		repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
	fi
	resolve_prefix=
	if [ -n "$repo_root" ] && [ -x "$repo_root/scripts/resolve-prefix.sh" ]; then
		resolve_prefix=$repo_root/scripts/resolve-prefix.sh
	fi

	plain_version() {
		printf '%s\n' "$1" | sed 's/^v//'
	}

	is_semver() {
		printf '%s\n' "$1" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
	}

	resolve_latest_tag() {
		url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "$RELEASES_LATEST") ||
			die "$E_FETCH" "error: could not resolve latest release"
		tag=${url##*/}
		printf '%s\n' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' ||
			die "$E_VERSION" "error: latest redirect was not a stable tag: $tag"
		printf '%s\n' "$tag"
	}

	if [ -z "$version_arg" ]; then
		version_arg=v$(plain_version "$SCRIPT_VERSION")
	fi
	case $version_arg in
		latest)
			tag=$(resolve_latest_tag)
			;;
		v*)
			tag=$version_arg
			;;
		*)
			tag=v$version_arg
			;;
	esac
	requested=$(plain_version "$tag")
	is_semver "$requested" ||
		die "$E_VERSION" "error: invalid version: $version_arg"

	ensure_clt() {
		if [ -x "$CLT_CLANG" ] && [ -x "$CLT_SWIFTC" ]; then
			return 0
		fi
		printf 'Command Line Tools not found.\n' >&2
		if [ "$CLT_WAIT_SECS" -gt 0 ]; then
			printf 'Opening the Command Line Tools installer.\n' >&2
			xcode-select --install >/dev/null 2>&1 || true
		fi
		elapsed=0
		while [ "$elapsed" -lt "$CLT_WAIT_SECS" ]; do
			if [ -x "$CLT_CLANG" ] && [ -x "$CLT_SWIFTC" ]; then
				return 0
			fi
			sleep 2
			elapsed=$((elapsed + 2))
		done
		die "$E_CLT" "error: Command Line Tools missing. Install them, then retry. xcode-select --install"
	}

	ensure_clt

	tmp_base=${TMPDIR:-/tmp}
	tmp_base=${tmp_base%/}
	workdir=$(mktemp -d "$tmp_base/airpods-control-install.XXXXXX")
	cleanup() { rm -rf "$workdir"; }
	trap cleanup EXIT HUP INT TERM

	src_tree=
	if [ "$from_tree" -eq 1 ]; then
		[ -n "$repo_root" ] ||
			die "$E_USAGE" "error: --from-tree requires a clone (cannot run from a pipe)"
		src_tree=$repo_root
	else
		if ! git clone --depth 1 --branch "$tag" "$REPO_HTTPS" "$workdir/src" \
			>/dev/null 2>"$workdir/clone.err"; then
			die "$E_FETCH" "error: git clone of $tag failed"
		fi
		src_tree=$workdir/src
	fi

	tree_version=$(tr -d '[:space:]' <"$src_tree/version.txt")
	[ "$tree_version" = "$requested" ] ||
		die "$E_VERSION" "error: version.txt is $tree_version, expected $requested"

	if [ -z "$resolve_prefix" ]; then
		resolve_prefix=$src_tree/scripts/resolve-prefix.sh
	fi
	[ -x "$resolve_prefix" ] ||
		die "$E_PREFIX" "error: missing resolve-prefix.sh"
	prefix=$("$resolve_prefix" "$prefix_arg") || exit "$E_PREFIX"

	BREW=${BREW:-brew}
	if command -v "$BREW" >/dev/null 2>&1; then
		if "$BREW" list --formula "$FORMULA_NAME" >/dev/null 2>&1; then
			brew_prefix=$("$BREW" --prefix)
			if brew_prefix=$("$resolve_prefix" "$brew_prefix"); then
				if [ "$prefix" = "$brew_prefix" ]; then
					die "$E_BREW" "error: Homebrew already owns $FORMULA_NAME at $brew_prefix. Use: brew upgrade $FORMULA_NAME"
				fi
				printf 'warning: Homebrew has %s; installing to %s anyway\n' \
					"$FORMULA_NAME" "$prefix" >&2
			fi
		fi
	fi

	command_path=$prefix/bin/airpods-control
	if [ -e "$command_path" ] || [ -L "$command_path" ]; then
		if [ ! -L "$command_path" ] ||
			[ "$(readlink "$command_path")" != "$EXPECTED_SYMLINK" ]; then
			die "$E_FOREIGN" "error: refusing to replace command not owned by this package: $command_path"
		fi
	fi

	host_arch=$(uname -m)
	make_vars="PREFIX=$prefix ARCHS=$host_arch CLANG=$CLANG SWIFTC=$SWIFTC LIPO=$LIPO CODESIGN=$CODESIGN"

	can_write_prefix() {
		mkdir -p "$prefix/bin" "$prefix/libexec/airpods-control" \
			"$prefix/share/man/man1" 2>/dev/null && [ -w "$prefix/bin" ]
	}

	run_privileged() {
		if can_write_prefix; then
			# shellcheck disable=SC2086
			make -C "$src_tree" $make_vars "$@"
		else
			command -v sudo >/dev/null 2>&1 ||
				die "$E_PREFIX" "error: $prefix is not writable. Pass --prefix DIR or install sudo."
			# shellcheck disable=SC2086
			sudo make -C "$src_tree" $make_vars "$@"
		fi
	}

	if [ "$do_uninstall" -eq 1 ]; then
		run_privileged uninstall
		printf 'uninstalled prefix=%s\n' "$prefix"
		return 0
	fi

	old_version=unknown
	if [ -x "$command_path" ]; then
		old_version=$("$command_path" --version 2>/dev/null) || old_version=unknown
	fi

	# shellcheck disable=SC2086
	make -C "$src_tree" $make_vars all ||
		die "$E_BUILD" "error: build failed"

	run_privileged install ||
		die "$E_BUILD" "error: install failed"

	installed=$("$command_path" --version 2>/dev/null) ||
		die "$E_BUILD" "error: installed binary did not run"
	[ "$installed" = "$requested" ] ||
		die "$E_VERSION" "error: installed version is $installed, expected $requested"

	printf 'installed %s prefix=%s\n' "$installed" "$prefix"
	if [ "$old_version" != unknown ] && [ "$old_version" != "$installed" ]; then
		printf 'upgraded from %s\n' "$old_version"
	fi
	case ":$PATH:" in
		*":$prefix/bin:"*) ;;
		*)
			printf 'note: %s/bin is not on PATH. Add it to run airpods-control by name.\n' \
				"$prefix"
			;;
	esac
}

install_from_source "$@"
