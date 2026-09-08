#!/usr/bin/env bash
#
# A shared library next to the program can be opened.
#
# Unix.Dlopen used to hand the name to dlopen only when it started with '/'; everything else was
# tried under six hardcoded directories, so `./lib.so` -- and anything the dynamic loader itself
# finds through LD_LIBRARY_PATH, RPATH or the ld.so cache -- could not be opened at all. The
# Windows twin resolves a relative name against the working directory and always could.
#
# Three answers, and the three together are the point:
#   ./probe.so   loads   -- the name as given reaches dlopen
#   probe.so     fails   -- a bare name is not silently looked for in the working directory
#   <system lib> loads   -- the hardcoded fallback still answers for a bare name
#
# Needs an SDK (`task Linux64 && task bundle`) and any shared library on the system; no C compiler.
#
# Usage: tests/hostlibs-check.sh [build directory]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${1:-$root/target/bundle}"
case "$sdk" in /*) ;; *) sdk="$PWD/$sdk" ;; esac

ob="$sdk/ob"
[ -x "$ob" ] || ob="$sdk/ob.exe"
if [ ! -x "$ob" ]; then
	echo "no SDK in $sdk; run 'task Linux64 && task bundle' first" >&2
	exit 2
fi

# Any shared library will do for the first two answers; the third one measures the hardcoded
# fallback, which only applies to the directories the runtime knows -- so it is asked only when the
# library was found in one of those. Termux keeps its libraries under $PREFIX, and Bionic will not
# dlopen a system library for an image a2boot mapped itself, so there the fallback has nothing to
# answer for.
standard="/lib/x86_64-linux-gnu /lib/aarch64-linux-gnu /lib64 /usr/lib64 /lib /usr/lib"
system=""; fallback=""
for name in libz.so.1 libz.so libm.so.6 libc.so.6; do
	for dir in $standard ${PREFIX:+$PREFIX/lib} /system/lib64; do
		[ -f "$dir/$name" ] || continue
		system="$dir/$name"
		case " $standard " in *" $dir "*) fallback="$name" ;; esac
		break 2
	done
done
[ -n "$system" ] || { echo "[SKIP] the loader check needs a shared library on this system" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$system" "$work/probe.so"
cp "$root/tests/HostLibsProbe.Mod" "$work/"
cd "$work"

# A relative name is relative to the process's working directory, which is this one.
printf '%s\n' ./probe.so probe.so $fallback > names.txt

"$ob" build HostLibsProbe.Mod -o probe > build.log 2>&1 || {
	echo "FAIL  the probe did not build"; sed 's/^/        /' build.log | head -12; exit 1; }
output="$(./probe 2>&1 | tr -d '\r')"

status=0
expect() {	# expect <name> <loaded|failed>
	if printf '%s\n' "$output" | grep -qx "$1 -> $2"; then
		echo "[ OK ] $1 -> $2"
	else
		echo "[FAIL] $1: expected $2, got: $(printf '%s\n' "$output" | grep -m1 -- "^$1 -> " || echo 'no answer')" >&2
		status=1
	fi
}

expect ./probe.so loaded
expect probe.so failed
if [ -n "$fallback" ]; then
	expect "$fallback" loaded
else
	echo "[ -- ] the hardcoded fallback is not asked here: $system is not in a directory it knows"
fi

[ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; exit 1; }
echo "hostlibs-check: OK"
