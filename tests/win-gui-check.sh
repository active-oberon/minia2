#!/usr/bin/env bash
#
# The windowed half of `ob build --gui` on Windows.
#
# There is no Xephyr here and no injector for keys, so this is not tests/zoom-check.sh ported: it is
# what can be measured without either -- the size the driver gives a program that asked for one, the
# pixel size it reports, and that the display goes up at all in the two places it is installed from
# (a linked binary, and `ob run` inside ob itself). The probe is the same module the Linux check
# uses: it asks the display and leaves, so nothing waits for a keystroke.
#
# What this check is worth: the Windows half was built from data and had never been run once, and the
# first run of it found three defects -- a positional size the driver dropped on the floor, a size
# read as the outer window rather than the drawing area, and `ob run --gui` installing the display
# before lib was on the search path (Display imports User32 out of the payload here, where the Linux
# lib-gui happens to be closed under its own imports).
#
# Usage: tests/win-gui-check.sh [bundle directory]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
	MINGW*|MSYS*|CYGWIN*) ;;
	*) echo "not Windows: a window here needs the machine it is drawn on" >&2; exit 2 ;;
esac

# The argument arrives from `task` as a Windows path (I:/Projects/...), which this shell does not
# read as absolute at all: without the conversion it was appended to $PWD and the SDK "was missing".
bundle="${1:-$root/target/bundle-win64}"
case "$bundle" in ?:*) bundle="$(cygpath -u "$bundle")" ;; esac		# a drive letter, not a path
case "$bundle" in /*) ;; *) bundle="$PWD/$bundle" ;; esac
[ -x "$bundle/ob.exe" ] || { echo "no Windows SDK at $bundle (run 'task win-bundle')" >&2; exit 2; }
[ -d "$bundle/lib-gui" ] || { echo "$bundle ships no windowed objects (lib-gui/)" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/win-gui-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Every path handed to the A2 runtime goes through cygpath -m: it takes no /c/... and its own working
# directory is the image's directory, not this shell's, so a relative name would be resolved beside
# ob.exe instead of here.
probe="$(cygpath -m "$root/tests/ZoomProbe.Mod")"
out() { cygpath -m "$work/$1"; }

fail=0

# tr -d: Trace.Ln writes CR LF, so the number would carry a carriage return into every comparison
# below and print two values that look identical.
said() { tr -d '\r' | grep '^zoom:' || true; }

# 1. Nothing asked for is still the window this driver has always opened: the screen, maximized.
#    Only the shape of the answer is checked -- the size is this machine's.
if "$bundle/ob.exe" build --gui "$probe" -o "$(out Probe.exe)" >"$work/build.log" 2>&1; then
	answer="$("$work/Probe.exe" 2>&1 | said)"
	case "$answer" in
		"zoom: "*" x "*unit=*)
			width="${answer#zoom: }"; width="${width%% *}"
			unit="${answer##*unit=}"; unit="${unit%% *}"
			if [ "$width" -gt 0 ] && [ "$unit" -gt 0 ]; then
				echo "ok    a linked window came up, $answer"
			else
				echo "FAIL  the display answered nothing usable: $answer"; fail=1
			fi ;;
		*) echo "FAIL  the linked window said ${answer:-<no output>}"; fail=1 ;;
	esac
else
	echo "FAIL  --gui did not build"; sed 's/^/        /' "$work/build.log" | tail -8; fail=1
fi

# 2. A size that was asked for is the DRAWING AREA, and it is the same number on both hosts. The
#    driver used to take the frame off it -- 800x600 drew into 784x561 -- and before that it read
#    only -w and -h, so the size never arrived at all and the window came up maximized.
if "$bundle/ob.exe" build --gui=640x480 "$probe" -o "$(out ProbeSized.exe)" >"$work/build-sized.log" 2>&1; then
	answer="$("$work/ProbeSized.exe" 2>&1 | said)"
	case "$answer" in
		"zoom: 640 x 480"*) echo "ok    --gui=640x480 asks for the drawing area and gets it" ;;
		*) echo "FAIL  --gui=640x480 gave ${answer:-<no output>}"; fail=1 ;;
	esac
else
	echo "FAIL  --gui=640x480 did not build"; sed 's/^/        /' "$work/build-sized.log" | tail -8; fail=1
fi

# 3. The other place the display is installed from: inside ob itself, with nothing linked.
answer="$(cd "$work" && "$bundle/ob.exe" run --gui=640x480 "$probe" 2>&1 | said)"
case "$answer" in
	"zoom: 640 x 480"*) echo "ok    ob run --gui=640x480 puts the display up in ob itself" ;;
	*) echo "FAIL  ob run --gui=640x480 gave ${answer:-<no output>}"; fail=1 ;;
esac

# 4. A size nobody can read is refused, not replaced by some other size.
case "$("$bundle/ob.exe" build --gui=800 "$probe" 2>&1)" in
	*"--gui takes a size like 800x600"*) echo "ok    a size it cannot read is refused" ;;
	*) echo "FAIL  --gui=800 was not refused"; fail=1 ;;
esac

# 5. And the promise the whole lib-gui arrangement is for: without the flag there is no window
#    system in the SDK at all, on this host as on the other.
case "$("$bundle/ob.exe" build "$probe" -o "$(out NoGui.exe)" 2>&1)" in
	*"could not import Displays"*) echo "ok    without --gui, IMPORT Displays is still an error" ;;
	*) echo "FAIL  Displays was importable without --gui"; fail=1 ;;
esac

echo
if [ "$fail" = 0 ]; then echo "win-gui-check: OK"; else echo "win-gui-check: FAILED"; fi
exit "$fail"
