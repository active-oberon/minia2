#!/usr/bin/env bash
#
# The wallpaper a person picks is a setting, and a setting has to still be there next time.
#
# Picking one used to leave the old backdrop underneath it and write nothing down, so the Autostart
# line in Configuration.XML -- a fixed image -- was what every start came up with. WMBackdrop.
# SetBackdropImage replaces instead of stacking and writes the choice back into that line. Both
# halves are checked here: the second pick must not hang on the first one's window, and the line the
# next start reads must name the image picked last.
#
# Usage: tests/backdrop-check.sh [build directory]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
case "$build" in /*) ;; *) build="$PWD/$build" ;; esac

oberon="$build/oberon"
[ -x "$oberon" ] || { echo "no built runtime in $build; run 'task Linux64' first" >&2; exit 2; }

# A working directory of its own: Configuration.Put writes the file there, and the one the desktop
# actually runs on is not a thing a check may overwrite.
work="$build/work-backdropcheck"
rm -rf "$work"; mkdir -p "$work"

# WMDemo.Check leaves a window manager standing over a display that is nothing but memory -- which is
# all a backdrop window needs, and it needs no screen.
output=$( (cd "$build" && PWD="$build" AOSPATH="$work:$build" timeout 180 "$oberon" do "
	System.DoFile oberon.cfg ~
	Files.SetWorkPath '$work' ~
	Compiler.Compile '$root/source/WMDemo.Mod' ~
	WMDemo.Check ~
	WMBackdrop.SetBackdropImage nebula_nord.png ? ? ? ? ~
	WMBackdrop.SetBackdropImage wp_teal_peaks.jpg ? ? ? ? ~
") 2>&1 | tr -d '\r' ) || { echo "the run did not finish -- a second pick waiting on the first window looks exactly like this:" >&2; printf '%s\n' "$output" | tail -10 >&2; exit 1; }

line=$(grep 'name="Desktop wallpaper"' "$work/Configuration.XML" 2>/dev/null || true)
case "$line" in
	*"SetBackdropImage wp_teal_peaks.jpg"*) echo "[PASS] the wallpaper picked last is what the next start reads" ;;
	"") echo "[FAIL] nothing was written to $work/Configuration.XML" >&2; exit 1 ;;
	*) echo "[FAIL] the setting kept an older pick: $line" >&2; exit 1 ;;
esac
