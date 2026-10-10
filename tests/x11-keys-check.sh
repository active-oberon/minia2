#!/usr/bin/env bash
# x11-keys-check verifies complete key lifetimes on an isolated X server.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="${1:-$root/target/bundle}"
display="${X11_KEYS_DISPLAY:-:78}"
[ -x "$bundle/ob" ] || { echo "No bundled SDK (task bundle)" >&2; exit 2; }
command -v Xephyr >/dev/null || { echo "No Xephyr" >&2; exit 2; }
[ ! -e "/tmp/.X11-unix/X${display#:}" ] || { echo "Display $display is already in use" >&2; exit 2; }
work="$(mktemp -d "${TMPDIR:-/tmp}/x11keys.XXXXXX")"
server=""; program=""
cleanup() {
    [ -z "$program" ] || kill "$program" 2>/dev/null || true
    [ -z "$server" ] || kill "$server" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT
cc -Wall -Wextra -Werror -o "$work/probe" "$root/tests/x11-keys.c" -lX11
cp "$root/tests/X11Keys.Mod" "$work/"
(cd "$work" && "$bundle/ob" build --gui=400x300 X11Keys.Mod -o keys)
Xephyr "$display" -screen 640x480 -nolisten tcp >"$work/server.log" 2>&1 &
server=$!
for _ in $(seq 50); do
    [ ! -e "/tmp/.X11-unix/X${display#:}" ] || break
    sleep 0.1
done
[ -e "/tmp/.X11-unix/X${display#:}" ] || { cat "$work/server.log"; exit 1; }
DISPLAY="$display" timeout 10 "$work/keys" >"$work/keys.log" 2>&1 &
program=$!
for _ in $(seq 50); do
    if grep -q 'X11Keys: ready' "$work/keys.log"; then break; fi
    sleep 0.1
done
DISPLAY="$display" "$work/probe"
if ! wait "$program"; then
    cat "$work/keys.log"
    echo "[FAIL] key press/release check did not finish" >&2
    exit 1
fi
program=""
cat "$work/keys.log"
