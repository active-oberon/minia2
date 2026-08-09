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

# Where what is compiled here goes, and where it is loaded from -- and this is not a detail.
#
# The runtime's own search path is bin, source, data, work, in that order, and the loader takes the
# first answer. bin holds an object file for every module of the system, WindowManager among them. So
# a check that compiles a module out of source/ into the working directory and then runs it does not
# run what it compiled: it compiles, throws the result somewhere further down the path, and loads the
# object that was built the last time somebody ran `task sdk`. This check did exactly that, and it is
# why the zoom below came up as 1 with the source in front of it saying 4.
#
# AOSPATH is what settles it: UnixFiles seeds the search path from that variable before oberon.cfg
# appends bin, so a directory named there is looked in first. A fresh one each run, holding nothing
# but the three modules under test, so that neither a stale object nor an object from a previous run
# of this check can answer for the source.
#
# The build directory is named second, and has to be. An empty search path is what made a name with no
# directory in it -- oberon.cfg, on the line below -- resolve against the process's own directory;
# setting AOSPATH takes that away, and the configuration file stops being found at all.
#
# Getting the objects there is the working directory and not --destPath, which would look right and
# does something else: a compiler given a destination looks for the symbol files of what it imports
# there and nowhere else, so the first module fails to import KernelLog. The working directory is
# where the compiler writes when it is not told otherwise.
objects="$build/work-wmcheck"
rm -rf "$objects"
mkdir -p "$objects"

# The runtime reads its working directory from $PWD rather than from getcwd().
output=$( (cd "$build" && PWD="$build" AOSPATH="$objects:$build" "$oberon" do "
	System.DoFile oberon.cfg ~
	Files.SetWorkPath '$objects' ~
	Compiler.Compile '$root/source/Raster.Mod' '$root/source/WindowManager.Mod' '$root/source/WMDemo.Mod' ~
	WMDemo.Check ~
") 2>&1 | tr -d '\r' ) || true

for module in Raster WindowManager WMDemo; do
	if ! printf '%s\n' "$output" | grep -q "$module.Mod => $module done\."; then
		echo "$module did not compile:" >&2
		printf '%s\n' "$output" | grep -E 'error' | head -10 >&2 || printf '%s\n' "$output" | tail -10 >&2
		exit 1
	fi
	# Compiled is not loaded, which is the whole point of the directory above: an object file that is
	# not there is a check that silently answers for whatever bin has.
	[ -f "$objects/$module.GofUu" ] || { echo "no object file for $module in $objects" >&2; exit 1; }
done

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
