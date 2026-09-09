#!/usr/bin/env bash
#
# The size of a pixel, and the zoom that follows from it.
#
# Displays.Display.unit is a pixel in 36000ths of a millimetre, and WindowManager.ZoomForUnit is the
# only reader: a dense screen is laid out at twice the size, a nominal one is left alone. The X11
# driver never set the field -- it answered 0 for every screen, which reads as "nominal" -- so A2 in
# a window on a HiDPI screen came up laid out at a fraction of its size. Both other displays in the
# tree have always answered (Windows from LogPixelsX, Android from the application), and this is the
# check that the X11 one keeps answering.
#
# Xephyr is what makes it measurable without hardware: it is an X server whose density is an
# argument, so the same binary can be shown a 200 dpi screen and a 96 dpi one in the same run.
#
# Usage: tests/zoom-check.sh [bundle directory]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="${1:-$root/target/bundle}"
case "$bundle" in /*) ;; *) bundle="$PWD/$bundle" ;; esac

command -v Xephyr >/dev/null || { echo "no Xephyr; the pixel size cannot be measured without an X server of a known density" >&2; exit 2; }
[ -x "$bundle/ob" ] || { echo "no SDK at $bundle (run 'task bundle')" >&2; exit 2; }
[ -d "$bundle/lib-gui" ] || { echo "$bundle ships no windowed objects (lib-gui/)" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/zoom-check.XXXXXX")"
display=":97"
cleanup() { pkill -f "Xephyr $display" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

cd "$work"
"$bundle/ob" build --gui "$root/tests/ZoomProbe.Mod" >"$work/build.log" 2>&1 || {
	echo "FAIL  the probe did not build"; sed 's/^/        /' "$work/build.log" | tail -8; exit 1
}

fail=0

# One screen, one density, one answer. The tolerance is two percent: the server reports whole
# millimetres, so 1200 pixels at 200 dpi is 152 mm and not 152.4, and the unit that follows is 4560
# rather than 4572.
probe() {
	local dpi="$1" wantZoom="$2" said unit zoom want
	pkill -f "Xephyr $display" 2>/dev/null || true
	Xephyr "$display" -screen 1200x800 -dpi "$dpi" -nolisten tcp >"$work/xephyr-$dpi.log" 2>&1 &
	local server=$!
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		DISPLAY="$display" XAUTHORITY= "$bundle/ob" version >/dev/null 2>&1 && break
		sleep 0.5
	done
	sleep 1
	# tr -d: Trace.Ln writes CR LF, so without this the number carries a carriage return and every
	# comparison below fails while printing two values that look identical.
	said="$(DISPLAY="$display" XAUTHORITY= timeout 60 ./ZoomProbe 2>&1 | tr -d '\r' | grep '^zoom:' || true)"
	kill "$server" 2>/dev/null || true
	case "$said" in
		*unit=*zoom=*) ;;
		*) echo "FAIL  at $dpi dpi the probe said nothing about the pixel: ${said:-<no output>}"; fail=1; return ;;
	esac
	unit="${said##*unit=}"; unit="${unit%% *}"
	zoom="${said##*zoom=}"; zoom="${zoom%% *}"
	want=$(( 914400 / dpi ))						# 36000 * 25.4, over the density
	if [ "$zoom" != "$wantZoom" ]; then
		echo "FAIL  at $dpi dpi the zoom is $zoom and not $wantZoom ($said)"; fail=1; return
	fi
	if [ "$unit" -lt $(( want * 98 / 100 )) ] || [ "$unit" -gt $(( want * 102 / 100 )) ]; then
		echo "FAIL  at $dpi dpi a pixel is $unit and not about $want ($said)"; fail=1; return
	fi
	echo "ok    at $dpi dpi a pixel is $unit/36000 mm and the view zooms $zoom"
}

probe 200 2			# a dense screen: laid out at twice the size
probe 96 1			# the density the layout was drawn for: left alone

echo
if [ "$fail" = 0 ]; then echo "zoom-check: OK"; else echo "zoom-check: FAILED"; fi
exit "$fail"
