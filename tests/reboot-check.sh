#!/usr/bin/env bash
#
# Reboot from the menu, on a hosted A2, is a2.sh starting the runtime again -- Machine.Shutdown has
# no other way out of a Unix process than leaving it. Which way it left is the whole signal: exit 0
# is System.Reboot and a2.sh loops, anything else is System.PowerDown or the window being closed and
# a2.sh stops. Get those two backwards and Shutdown restarts the desktop forever.
#
# Usage: tests/reboot-check.sh [build directory]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
case "$build" in /*) ;; *) build="$PWD/$build" ;; esac

oberon="$build/oberon"
[ -x "$oberon" ] || { echo "no built runtime in $build; run 'task Linux64' first" >&2; exit 2; }

leaves_with() { # command -- the exit code the runtime leaves with
	( cd "$build" && PWD="$build" timeout 60 "$oberon" do "System.DoFile oberon.cfg ~ $1 ~" ) >/dev/null 2>&1
	echo $?
}

status=0
code=$(leaves_with "System.Reboot")
[ "$code" = 0 ] || { echo "[FAIL] System.Reboot left with $code, so a2.sh would not start A2 again" >&2; status=1; }

code=$(leaves_with "WMTerminator.Do")
[ "$code" != 0 ] || { echo "[FAIL] shutting down left with 0, so a2.sh would restart A2 instead of stopping" >&2; status=1; }

[ "$status" = 0 ] && echo "[PASS] reboot and shutdown leave with the codes a2.sh reads them by"
exit "$status"
