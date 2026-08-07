#!/usr/bin/env bash
#
# What a display driver is handed: the picture, checked without a screen.
#
# A backend over a window can only be seen on a device, but almost everything that can be wrong with
# it is not about the window: the arithmetic that draws, the row buffer, the strides through
# Displays.Transfer, the colour word. DisplayDemo.Check draws the Mandelbrot set at the size of a
# phone screen into a display that is nothing but memory and prints what landed there, coarsely; the
# shape it prints must be the shape DisplayDemo.Ascii computes straight from the arithmetic.
#
# Both pictures are compared against what they printed on the day the driver was first seen working on
# a real screen (tests/display-expected.txt) -- against a recorded shape rather than against each
# other, because they are not the same shape: Ascii evaluates 78 by 30 points, while Check draws a
# million and looks at every fourteenth column and every seventy-eighth row, so the two disagree in
# the details wherever a cell straddles the edge of the set. What each one catches is different, which
# is why both are kept: Ascii moves when the arithmetic changes, Check when the picture does.
#
# Usage: tests/display-check.sh [build directory]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
case "$build" in /*) ;; *) build="$PWD/$build" ;; esac

oberon="$build/oberon"
[ -x "$oberon" ] || oberon="$build/oberon.exe"
if [ ! -x "$oberon" ]; then
	echo "no built runtime in $build; run 'task Linux64' first" >&2
	exit 2
fi

expected="$root/tests/display-expected.txt"
[ -f "$expected" ] || { echo "no expected picture at $expected" >&2; exit 2; }

# The runtime reads its working directory from $PWD rather than from getcwd().
output=$( (cd "$build" && PWD="$build" "$oberon" do "
	System.DoFile oberon.cfg ~
	Compiler.Compile '$root/source/DisplayDemo.Mod' ~
	DisplayDemo.Ascii ~
	DisplayDemo.Check ~
") 2>&1 | tr -d '\r' ) || true

if ! printf '%s\n' "$output" | grep -q ' done\.'; then
	echo "DisplayDemo did not compile:" >&2
	printf '%s\n' "$output" | grep -E 'error' | head -10 >&2 || printf '%s\n' "$output" | tail -10 >&2
	exit 1
fi

# Both pictures are 30 lines of 78 columns made of the four characters below, and nothing else in the
# transcript looks like that -- which is how they are picked out of it without counting lines.
picture=$(printf '%s\n' "$output" | grep -E '^[ .+#]{78}$' || true)
lines=$(printf '%s\n' "$picture" | grep -c . || true)
if [ "$lines" -ne 60 ]; then
	echo "expected two pictures of 30 lines, got $lines line(s):" >&2
	printf '%s\n' "$output" | tail -20 >&2
	exit 1
fi

if [ "$picture" != "$(cat "$expected")" ]; then
	echo "the pictures changed from tests/display-expected.txt (arithmetic first, drawn second):" >&2
	diff "$expected" <(printf '%s\n' "$picture") | head -30 >&2
	exit 1
fi

echo "display: the set computed and the set drawn through Displays are both as recorded, at 1080 x 2340"
