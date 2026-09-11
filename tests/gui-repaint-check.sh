#!/usr/bin/env bash
#
# A windowed program's picture, after something covered it.
#
# `ob build --gui` links a display and no window manager, and this display keeps no copy of the
# screen -- it draws into the X window and reads back out of it. So whatever the server discards
# is gone, and until 2026-09-11 a covered window came back blank. Found on a Raspberry Pi by the
# one person who minimised it; reproduced here in two minutes once the server was the right kind.
#
# The server has to be a plain one. On a composited desktop -- Xwayland, mutter, anything modern
# -- every window is redirected to a pixmap of its own and nothing is ever lost, so this check
# would pass against a build with none of the fix in it. Hence Xephyr, and hence the skip when
# it is not installed.
#
# Usage: tests/gui-repaint-check.sh [bundle directory]
# Exit: 0 the picture survived, 1 it did not, 2 the machine cannot answer (no Xephyr, no SDK, no
#       C compiler, no Xlib headers).

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="${1:-$root/target/bundle}"
display="${GUI_REPAINT_DISPLAY:-:77}"
colour=0x102838				# the background examples/Window.Mod fills with

[ -x "$bundle/ob" ] || { echo "no SDK in $bundle (task bundle)" >&2; exit 2; }
[ -d "$bundle/lib-gui" ] || { echo "$bundle carries no windowed objects" >&2; exit 2; }
command -v Xephyr >/dev/null || { echo "no Xephyr to run a plain X server on" >&2; exit 2; }
command -v cc >/dev/null || command -v gcc >/dev/null || { echo "no C compiler for the probe" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/guirepaint.XXXXXX")"
xephyr=""; program=""
cleanup() {
	[ -z "$program" ] || kill "$program" 2>/dev/null || true
	[ -z "$xephyr" ] || kill "$xephyr" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT

CC="$(command -v cc || command -v gcc)"
"$CC" -O1 -o "$work/probe" "$root/tests/gui-repaint.c" -lX11 2>"$work/cc.log" || {
	sed 's/^/    /' "$work/cc.log" >&2; echo "the probe did not compile (Xlib headers?)" >&2; exit 2; }

Xephyr "$display" -screen 640x480 -nolisten tcp >"$work/xephyr.log" 2>&1 &
xephyr=$!
for _ in $(seq 20); do [ -e "/tmp/.X11-unix/X${display#:}" ] && break; sleep 1; done
[ -e "/tmp/.X11-unix/X${display#:}" ] || { echo "Xephyr did not come up" >&2; exit 2; }

( cd "$bundle" && DISPLAY="$display" ./ob run --gui=400x300 examples/Window.Mod ) >"$work/window.log" 2>&1 &
program=$!
for _ in $(seq 60); do grep -q "Escape to leave" "$work/window.log" 2>/dev/null && break; sleep 1; done
grep -q "Escape to leave" "$work/window.log" || {
	sed 's/^/    /' "$work/window.log" >&2; echo "the windowed program did not come up" >&2; exit 2; }
sleep 1

status=0
DISPLAY="$display" "$work/probe" "$colour" || status=$?
case "$status" in
	0) echo "[PASS] the picture survives being covered" ;;
	1) echo "[FAIL] a covered window comes back blank -- backing store is not being asked for" >&2 ;;
	*) echo "[SKIP] there was nothing to measure" >&2 ;;
esac
exit "$status"
