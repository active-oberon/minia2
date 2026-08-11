#!/usr/bin/env bash
#
# Run the test suites compiled for AArch64, executing them under qemu.
#
# This is `ob test -t a64` over every tests/*.Test file: each case is compiled for UnixA64 by the
# host compiler and, where the suite executes rather than only compiles, loaded and run in an
# AArch64 image that `ob` links for the occasion. The two language suites are the point of it --
# 5450 compilation and 695 execution cases, the same ones that run on x86-64 -- and the library
# suites come along because they are in the same directory.
#
# It needs no SDK image: `ob` only wants an SDK layout, which is assembled here out of the built
# tree ($SDK/oberon, lib/, lib-a64/, boot-modules.txt). The A64 objects come from
# tests/a64-stdlib-check.sh, which has to have run first, and running needs what
# tests/a64-system-check.sh needs -- qemu-user and an AArch64 C library, `task a64-sysroot` or
# A64_SYSROOT providing the latter where the distribution does not. Without them the suites that
# execute would be skipped and the run would say nothing about AArch64, so this exits 2 instead.
#
# Usage: tests/a64-suites-check.sh [build directory] [object directory]

set -eo pipefail

absolute() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*) printf '%s\n' "$PWD/$1" ;;
	esac
}

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
build="$(absolute "$build")"
objects="${2:-$root/target/A64/bin}"
objects="$(absolute "$objects")"

oberon="$build/oberon"
[ -x "$oberon" ] || oberon="$build/oberon.exe"
if [ ! -x "$oberon" ]; then
	echo "no built runtime in $build; run 'task Linux64' or 'task oberon' first" >&2
	exit 2
fi
if [ ! -f "$objects/Compiler.GofU8" ]; then
	echo "no A64 standard library in $objects; run tests/a64-stdlib-check.sh first" >&2
	exit 2
fi

qemu="${A2_QEMU:-$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)}"
sysroot="${A64_SYSROOT:-${A2_A64_SYSROOT:-}}"
if [ -z "$sysroot" ]; then
	for candidate in "$root/target/A64/sysroot" /usr/aarch64-linux-gnu /usr/local/aarch64-linux-gnu; do
		[ -f "$candidate/lib/ld-linux-aarch64.so.1" ] && sysroot="$candidate" && break
	done
fi
if [ -z "$qemu" ] || [ -z "$sysroot" ] || [ ! -f "$sysroot/lib/ld-linux-aarch64.so.1" ]; then
	echo "[SKIP] running the A64 suites needs qemu-user and an AArch64 C library" >&2
	exit 2
fi

# The SDK layout `ob` expects, out of the built tree. Symbol and object files are linked rather
# than copied: there are some 1800 of them and none is written to.
sdk="$(mktemp -d)"
trap 'rm -rf "$sdk"' EXIT
mkdir -p "$sdk/lib" "$sdk/lib-a64"
ln -s "$oberon" "$sdk/oberon"
ln -s "$build"/bin/*.SymUu "$build"/bin/*.GofUu "$sdk/lib/"
ln -s "$objects"/*.SymU8 "$objects"/*.GofU8 "$sdk/lib-a64/"
cp "$root/configs/moduleListLinux.txt" "$sdk/boot-modules.txt"

report="${A64_SUITES_REPORT:-$(dirname "$objects")/a64-suites-report.json}"
log="${A64_SUITES_LOG:-$(dirname "$objects")/a64-suites-check.log}"

# The whole transcript goes to a file: it is thousands of lines, the run takes the better part of
# an hour under an emulator, and the case it is on is the only way to tell a slow run from a hung
# one while it is going.
status=0
(cd "$root/tests" && A2SDK="$sdk" A2_QEMU="$qemu" A2_A64_SYSROOT="$sysroot" \
	timeout "${A64_SUITES_TIMEOUT:-10800}" bash "$root/sdk/ob" test -t a64 --report "$report" \
	> "$log" 2>&1) || status=$?

tail -1 "$log" | tr -d '\r'

if [ "$status" -eq 0 ]; then
	# A run in which nothing executed would pass on compilation alone and say nothing about
	# AArch64, which is the one outcome this check exists to rule out.
	if ! grep -q 'AArch64 cases run under' "$log"; then
		echo "the A64 suites did not execute anything -- no image or no emulator:" >&2
		# awk rather than `grep | head`: with `pipefail` the closed pipe would be this
		# script's exit status instead of the 1 it means to report.
		awk '/^ob test:|SKIP  whole file/ && n++ < 10' "$log" >&2
		exit 1
	fi
	exit 0
fi

if [ "$status" -eq 124 ]; then
	echo "the A64 suites did not finish in ${A64_SUITES_TIMEOUT:-10800} seconds;" >&2
else
	echo "the A64 suites reported failures;" >&2
	awk '/^  FAIL |^  FIXED / && n++ < 20' "$log" >&2
fi
echo "  the whole of it is in $log, the summary in $report" >&2
exit 1
