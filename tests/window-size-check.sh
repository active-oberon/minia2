#!/bin/sh
# Check the actual X11 window, since Displays.Display.width can be right while the window is maximized.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
app_pid=
trap 'if [ -n "$app_pid" ]; then kill "$app_pid" 2>/dev/null || true; fi; rm -rf "$work"' EXIT

ob build "$root/examples/Window.Mod" --gui=800x600 -o "$work/A2WindowSizeCheck" >/dev/null
"$work/A2WindowSizeCheck" >"$work/app.log" 2>&1 &
app_pid=$!

window_id=
for attempt in 1 2 3 4 5 6 7 8 9 10; do
	window_id=$(xwininfo -root -tree | awk '/"A2WindowSizeCheck --/ {id=$1} END {print id}')
	[ -n "$window_id" ] && break
	sleep 1
done
[ -n "$window_id" ] || { cat "$work/app.log" >&2; exit 1; }

geometry=$(xwininfo -id "$window_id")
width=$(printf '%s\n' "$geometry" | awk '/^[[:space:]]*Width:/ {print $2}')
height=$(printf '%s\n' "$geometry" | awk '/^[[:space:]]*Height:/ {print $2}')
[ "$width" = 800 ] && [ "$height" = 600 ] || {
	echo "window size: ${width}x${height}, expected 800x600" >&2
	exit 1
}
echo "window size: 800x600"
