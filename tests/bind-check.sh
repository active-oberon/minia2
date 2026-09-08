#!/usr/bin/env bash
#
# `ob bind` against a real C library, on this host's own ABI.
#
# tests/H2ao.Test measures the generator on ASTs built by hand, which is where the awkward cases
# live; nothing there calls clang, opens a library or crosses the C boundary. This does all three:
# it compiles tests/bind-thing.c into a shared library, has `ob bind` read its header, and then has
# both sides say the same eighteen things about the same types -- sizes, offsets, a union, a run of
# bit fields written on one side and read on the other, and the wrappers over a variadic function.
#
# The check is a diff of the two outputs, so no number is written down here: on a host where the
# ABI differs, both sides move together or the diff shows it.
#
# Also the loader: the library is named to `ob bind` by a RELATIVE path, which is what a library
# built beside the program is. Until 2026-09-08 Unix.Dlopen could only open a name starting with
# '/', so that alone was a failure.
#
# Needs an SDK (`task Linux64 && task bundle`), a C compiler, and clang or zig for `ob bind`.
#
# Usage: tests/bind-check.sh [sdk directory]

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

cc="${CC:-cc}"
command -v "$cc" >/dev/null 2>&1 || { echo "[SKIP] the binding check needs a C compiler" >&2; exit 2; }
command -v clang >/dev/null 2>&1 || command -v zig >/dev/null 2>&1 || {
	echo "[SKIP] the binding check needs clang or zig, which is what reads the header" >&2; exit 2; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp "$root/tests/bind-thing.h" "$root/tests/bind-thing.c" "$root/tests/BindThingProbe.Mod" "$work/"
cd "$work"

lib="libbindthing$( [ "$(uname -o 2>/dev/null)" = "Msys" ] && echo .dll || echo .so )"
"$cc" -shared -fPIC -o "$lib" bind-thing.c
"$cc" -DBIND_THING_MAIN -o bind-thing-ref bind-thing.c
./bind-thing-ref > c-says.txt

# The library by a relative name on purpose -- see the note above.
"$ob" bind bind-thing.h -o CThing.Mod -m CThing --records --varargs 3 -l "./$lib" > bind.log 2>&1 || {
	echo "FAIL  ob bind did not run"; sed 's/^/        /' bind.log | head -12; exit 1; }
sed 's/^/      /' bind.log

# What cannot be translated is named in the module, with its reason; the mixed-type bit field run is
# the one declaration in the header that has to be refused.
if ! grep -q 'mixed -- bit fields of two different types in a row' CThing.Mod; then
	echo "FAIL  the mixed bit field run was not refused with a reason" >&2
	grep -n 'Not translated' -A 5 CThing.Mod >&2 || true
	exit 1
fi

"$ob" build BindThingProbe.Mod -o probe > build.log 2>&1 || {
	echo "FAIL  the probe did not build against the generated module"; sed 's/^/        /' build.log | head -12; exit 1; }
./probe > probe.out 2>&1 || true
# Only the answers are compared: KernelLog.Ln writes CR+LF, and the runtime says things of its own
# on some hosts (Bionic has no pthread_cancel and reports it) -- neither is an ABI disagreement.
tr -d '\r' < probe.out | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' > we-say.txt || true

if ! diff -u c-says.txt we-say.txt > answers.diff; then
	echo "FAIL  the binding and C disagree about their own types:" >&2
	sed 's/^/        /' answers.diff >&2
	echo "      what the probe printed:" >&2
	sed 's/^/        /' probe.out >&2
	exit 1
fi

echo "bind-check: OK — $(wc -l < c-says.txt) answers, C and the generated binding agree"
