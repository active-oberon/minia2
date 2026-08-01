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

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
out="${2:-$root/target/A64/bin}"

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
		Compiler.Compile -p=UnixA64 --destPath=$out/ $root/source/$module ~
	" </dev/null) 2>&1 | tr -d '\r' ) || true
	if printf '%s\n' "$output" | grep -q ' done\.'; then
		ok=$((ok+1))
	else
		failed+=("$module")
		printf '  %s FAILED\n' "$module" >&2
		printf '%s\n' "$output" | grep -E 'error' | head -4 | sed 's/^/      /' >&2
	fi
done < "$root/configs/moduleListA64.txt"

total=$(( ok + ${#failed[@]} ))
echo "UnixA64 standard library: $ok of $total modules compiled"
if [ ${#failed[@]} -gt 0 ]; then
	echo "still failing: ${failed[*]}" >&2
	exit 1
fi
