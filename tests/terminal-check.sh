#!/bin/bash
# The half of the terminal that only a terminal can answer for.
#
# What a key sequence *means* is decided by TerminalCodes and checked in tests/Terminal.Test,
# in this process and without a device. What is left is the part that is a device: raw mode
# through termios, the window size through an ioctl, and the settings put back afterwards.
# None of that can be exercised by a program whose input is a file, so this gives it a real
# pseudo-terminal -- which is all `script` is -- and types into it.
#
# Usage: tests/terminal-check.sh [SDK directory]     (default: target/bundle)
set -eo pipefail
export LC_ALL=C

root="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${1:-$root/target/bundle}"
case "$sdk" in /*) ;; *) sdk="$PWD/$sdk" ;; esac

[ -x "$sdk/ob" ] || { echo "no SDK in $sdk; run 'task bundle' first" >&2; exit 2; }
command -v script >/dev/null 2>&1 || { echo "no 'script' here, and nothing else makes a terminal" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/terminal-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp "$root/docker/examples/Keys.Mod" "$work/"

fail=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }

echo "=== a program that is not looking at a terminal says so"
notty="$( cd "$work" && echo | timeout 120 "$sdk/ob" run Keys.Mod 2>&1 || true )"
case "$notty" in
	*"not a terminal"*) ok "input from a file is refused, and named" ;;
	*) bad "no complaint about input that is not a terminal"; printf '%s\n' "$notty" | tail -3 | sed 's/^/        /' ;;
esac

echo "=== the same program, on a terminal of its own"
# script(1) allocates the pseudo-terminal and passes our standard input through to it. The keys
# are the bytes a terminal sends: a letter, Ctrl and the right arrow, F5, the wheel, and q.
keys="$(printf 'a\033[1;5C\033[15~\033[<64;3;4Mq')"
transcript="$work/transcript"
printf '%s' "$keys" | ( cd "$work" && timeout 180 script -qec "$sdk/ob run Keys.Mod" /dev/null ) \
	> "$transcript" 2>&1 || { bad "the program did not leave on q"; }

# What is left after the escape sequences are taken out is what the program drew.
drawn="$(tr -d '\r' < "$transcript" | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g')"

grep -q "terminal is 80 by 24" <<<"$drawn" \
	&& ok "asked the terminal its size, and was told 80 by 24" \
	|| bad "did not report the size of its terminal"

grep -q "character  a" <<<"$drawn" \
	&& ok "a letter arrived as itself" \
	|| bad "the letter did not arrive"

grep -q "Ctrl-key  Right" <<<"$drawn" \
	&& ok "an arrow with Ctrl held arrived as both" \
	|| bad "Ctrl and the right arrow did not arrive"

grep -q "key  F5" <<<"$drawn" \
	&& ok "a function key arrived" \
	|| bad "F5 did not arrive"

grep -q "wheel  up  at 3,4" <<<"$drawn" \
	&& ok "the wheel arrived, where it was turned" \
	|| bad "the wheel did not arrive"

# The frame is drawn with box characters, which are what a terminal draws pictures with.
grep -q "╭" <<<"$drawn" && grep -q "╯" <<<"$drawn" \
	&& ok "drew its frame in box-drawing characters" \
	|| bad "no frame in the transcript"

# Raw mode has to be given back, or the terminal is left unusable for whatever runs next.
grep -q "1049h" "$transcript" && grep -q "1049l" "$transcript" \
	&& ok "took a screen of its own and gave it back" \
	|| bad "the alternate screen was not returned"

grep -q "?25l" "$transcript" && grep -q "?25h" "$transcript" \
	&& ok "hid the cursor while drawing and showed it again" \
	|| bad "the cursor was left hidden"

grep -q "?1006h" "$transcript" && grep -q "?1006l" "$transcript" \
	&& ok "asked for the mouse and stopped asking" \
	|| bad "mouse reporting was left on"

echo
if [ "$fail" = 0 ]; then echo "terminal-check: OK"; else echo "terminal-check: FAILED"; fi
exit "$fail"
