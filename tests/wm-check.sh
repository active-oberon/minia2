#!/usr/bin/env bash
#
# A2's own window manager, brought up and painted, without a screen to look at.
#
# tests/display-check.sh answers for the display driver: what lands in a frame buffer when one module
# owns it. This answers for everything above that -- Raster, WMGraphics, the embedded font, the
# decoration, the compositing in WindowManager -- by registering a display that is nothing but memory,
# bringing the window manager up over it, opening a window and reading the memory back.
#
# Two things are checked, and they are different in kind:
#
#   -  the window's own image, as a coarse picture, against tests/wm-expected.txt. The window draws
#      itself in the font compiled into WMDefaultFont rather than whatever the machine has on disk,
#      so this picture is the same picture on a desktop with data/ full of OpenType fonts and on a
#      phone with none.
#   -  where it landed on the screen, as two counts printed by WMDemo.Check. The screen itself cannot
#      be recorded: the title bar is drawn by the decoration in whatever font the font manager found,
#      which is not the same font everywhere. Counts of "the window here, the background there" are.
#
# Usage: tests/wm-check.sh [build directory]

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

expected="$root/tests/wm-expected.txt"
[ -f "$expected" ] || { echo "no expected picture at $expected" >&2; exit 2; }

# The runtime reads its working directory from $PWD rather than from getcwd().
output=$( (cd "$build" && PWD="$build" "$oberon" do "
	System.DoFile oberon.cfg ~
	Compiler.Compile '$root/source/Raster.Mod' '$root/source/WMDemo.Mod' ~
	WMDemo.Check ~
") 2>&1 | tr -d '\r' ) || true

if ! printf '%s\n' "$output" | grep -q 'WMDemo.Mod => WMDemo done\.'; then
	echo "WMDemo did not compile:" >&2
	printf '%s\n' "$output" | grep -E 'error' | head -10 >&2 || printf '%s\n' "$output" | tail -10 >&2
	exit 1
fi

# A picture that never settled is a picture caught mid-paint, and comparing one is how a check starts
# failing at random on a loaded machine.
if printf '%s\n' "$output" | grep -q 'never settled'; then
	echo "the window manager never stopped painting:" >&2
	printf '%s\n' "$output" | tail -10 >&2
	exit 1
fi

# `window N of N, background M of M` -- both have to be whole. A window drawn somewhere else moves the
# first, a window drawn over everything moves the second.
placement=$(printf '%s\n' "$output" | grep -aoE 'window [0-9]+ of [0-9]+, background [0-9]+ of [0-9]+' | tail -1)
if [ -z "$placement" ]; then
	echo "WMDemo.Check said nothing about where the window landed:" >&2
	printf '%s\n' "$output" | tail -20 >&2
	exit 1
fi
read -r _ inside _ insideOf _ outside _ outsideOf <<<"$(printf '%s\n' "$placement" | tr -d ',')"
if [ "$inside" != "$insideOf" ] || [ "$outside" != "$outsideOf" ] || [ "$inside" = 0 ] || [ "$outside" = 0 ]; then
	echo "the window is not where it was put: $placement" >&2
	exit 1
fi

# Two pictures of 30 lines each: the screen first, the window second, in the four characters the
# display check also uses -- and nothing else in the transcript looks like that.
picture=$(printf '%s\n' "$output" | grep -aE '^[ .+#]{78}$' || true)
lines=$(printf '%s\n' "$picture" | grep -c . || true)
if [ "$lines" -ne 60 ]; then
	echo "expected two pictures of 30 lines, got $lines line(s):" >&2
	printf '%s\n' "$output" | tail -20 >&2
	exit 1
fi

window=$(printf '%s\n' "$picture" | tail -30)
if [ "$window" != "$(cat "$expected")" ]; then
	echo "the window changed from tests/wm-expected.txt:" >&2
	diff "$expected" <(printf '%s\n' "$window") | head -30 >&2
	exit 1
fi

echo "window manager: it came up over a display of nothing but memory, and the window is as recorded ($placement)"
