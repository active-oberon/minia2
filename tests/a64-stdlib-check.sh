#!/usr/bin/env bash
#
# Compile the headless standard library for UnixA64 and report how much of it gets through.
#
# The list is configs/moduleListA64.txt: what docker/headless-core.txt keeps, in the order
# Release.Build prints for Linux64, less the modules that are x86 by nature. Each module is
# compiled in its own process so that one failure does not hide the modules behind it, and the
# symbol files of the ones already done are found in the output directory.
#
# This is what an AArch64 SDK image would ship as its lib/. It takes minutes rather than seconds,
# which is why it is a task of its own rather than part of `task test`.
#
# Usage: tests/a64-stdlib-check.sh [build directory] [output directory]

set -eo pipefail

# Directories given on the command line are made absolute: every one of them is used after a `cd`
# into the build directory, and a relative one would be read from there rather than from where it
# was given. The output directory need not exist yet, so this does not go through `cd`.
absolute() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*) printf '%s\n' "$PWD/$1" ;;
	esac
}

# What went wrong, as far as the compiler said so. A failure with no line mentioning an error --
# a directory that is not there, say -- would otherwise be reported as nothing at all, because a
# `grep` that matches nothing ends the script under `set -e`.
Reason() {
	printf '%s\n' "$1" | grep -E 'error' | head -"$2" || printf '%s\n' "$1" | tail -"$2"
}

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
build="$(absolute "$build")"
out="${2:-$root/target/A64/bin}"
out="$(absolute "$out")"

oberon="$build/oberon"
[ -x "$oberon" ] || oberon="$build/oberon.exe"
if [ ! -x "$oberon" ]; then
	echo "no built runtime in $build; run 'task Linux64' or 'task oberon' first" >&2
	exit 2
fi

mkdir -p "$out"
ok=0; failed=()
while read -r module; do
	case "$module" in ''|'#'*) continue ;; esac
	if [ ! -f "$root/source/$module" ]; then
		echo "  $module: no such source" >&2
		failed+=("$module")
		continue
	fi
	# </dev/null: the compiler reads standard input, and would eat the rest of the list
	output=$( (cd "$build" && PWD="$build" "$oberon" do "
		System.DoFile oberon.cfg ~
		Files.AddSearchPath $root/source ~
		Files.AddSearchPath $out ~
		Compiler.Compile -p=UnixA64 --destPath='$out/' '$root/source/$module' ~
	" </dev/null) 2>&1 | tr -d '\r' ) || true
	if printf '%s\n' "$output" | grep -q ' done\.'; then
		ok=$((ok+1))
	else
		failed+=("$module")
		printf '  %s FAILED\n' "$module" >&2
		Reason "$output" 4 | sed 's/^/      /' >&2
	fi
done < "$root/configs/moduleListA64.txt"

total=$(( ok + ${#failed[@]} ))
echo "UnixA64 standard library: $ok of $total modules compiled"
if [ ${#failed[@]} -gt 0 ]; then
	echo "still failing: ${failed[*]}" >&2
	exit 1
fi
