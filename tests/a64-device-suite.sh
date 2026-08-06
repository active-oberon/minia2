#!/usr/bin/env bash
#
# Everything this port can be asked, run on a real AArch64 machine.
#
# This script lives inside the bundle that tests/a64-bundle.sh assembles, and runs from its
# root: no build tree, no Docker, no emulator, nothing but the bundle and a C library. It is
# the same set of checks the tree runs under qemu, minus the emulator -- and one more, the
# language suites, which had never been run anywhere but under one.
#
# Why a real processor is not the same evidence as qemu: qemu-user does not reorder memory
# accesses and a Cortex-A does, so the whole class of "a barrier is missing here" is invisible
# under the emulator by construction -- and the collector, the write barriers and leave
# tracking are exactly what rests on those barriers. Everything below that touches threads is
# therefore a different test here than it is at home, running the same code.
#
# Two differences from the checks at home, both deliberate:
#
#   -  the modules under test are LOADED into the runtime rather than linked into an image of
#      their own. That is now the honest arrangement -- dynamic loading works on AArch64 since
#      the port was finished -- and it exercises the loader on top of what the module tests.
#   -  the suites run natively, so their cases execute in the process that compiled them.
#
# Usage: ./run.sh [-q|--quick]           (-q skips the language suites, which take a while)
# Results land in results/: one log per check, plus the JSON report of the suites.

set -uo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
oberon="$root/oberon"
lib="$root/lib"
results="$root/results"
quick=0
case "${1:-}" in
	-q|--quick) quick=1 ;;
	"") ;;
	*) echo "usage: $(basename "$0") [-q|--quick]" >&2; exit 2 ;;
esac

for tool in timeout mktemp od awk sed grep realpath; do
	command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool (install coreutils)" >&2; exit 2; }
done
[ -x "$oberon" ] || { echo "no runtime at $oberon" >&2; exit 2; }
[ -f "$lib/Compiler.GofU8" ] || { echo "no AArch64 objects in $lib" >&2; exit 2; }

mkdir -p "$results"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "machine:  $(uname -m), $(uname -r)"
if [ -r /proc/cpuinfo ]; then
	# Which cores this actually ran on belongs in the record: a heterogeneous phone migrates a
	# thread between microarchitectures with different reordering windows, which is a stricter
	# test than a uniform SMP box, and a year from now nobody will remember what the phone was.
	parts="$(sed -n 's/^CPU part[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | sort | uniq -c | tr -s ' \n' ' ')"
	echo "cores:    $(grep -c '^processor' /proc/cpuinfo)${parts:+, parts: $parts}"
fi
echo "runtime:  $oberon"
echo

pass=0; fail=0; skip=0
declare -a FAILED=()

# One check: a name, a log file, and a predicate over the log. The runtime always exits 0, so
# the verdict is read off the transcript -- except for the timeout, which is the one failure
# that leaves nothing in the transcript to read.
report() {
	local name="$1" status="$2" log="$3" want="$4" took="${_ELAPSED:-0}s"
	if [ "$status" -eq 124 ]; then
		printf '  FAIL  %-28s did not finish in time\n' "$name"; FAILED+=("$name"); fail=$((fail+1)); return
	fi
	if [ -n "$want" ] && ! grep -qE "$want" "$log"; then
		printf '  FAIL  %-28s no "%s" in %s\n' "$name" "$want" "${log#$root/}"
		FAILED+=("$name"); fail=$((fail+1))
		tail -12 "$log" | tr -d '\r' | sed 's/^/          /'
		return
	fi
	# How long each of these takes is worth keeping: the same checks under an emulator at home
	# take minutes where a real processor takes seconds, and that ratio is the story.
	printf '  ok    %-28s %6s  %s\n' "$name" "$took" "${log#$root/}"; pass=$((pass+1))
}

# Feed commands to the shell of the runtime. `exit` is what leaves it: on end of input it spins
# rather than stopping. The runtime reads its working directory from $PWD, not from getcwd().
#
# Every caller that names a search path also names the working directory, and that is not
# belt-and-braces: with an empty search path a bare file name resolves against the working
# directory, and the moment ANY entry is added that fallback is gone -- while Files.New and
# Files.Register go on writing there. So a module that registers a file and reads it back by
# name works alone and stops working as soon as the caller adds a path. (Not an AArch64 thing:
# same on x86-64, see the note in tests/A64GCStress.Mod.)
shell() {
	local log="$1" limit="$2"; shift 2
	local cmd; cmd="$(printf '%s\n' "$@")"
	local status=0 started=$SECONDS
	( cd "$work" && PWD="$work" printf '%s\nexit\n' "$cmd" \
		| timeout "$limit" "$oberon" > "$log" 2>&1 ) || status=$?
	_ELAPSED=$((SECONDS - started))
	return $status
}

# 1. It boots, and the shell answers. System.Time asks the C library of this machine for the
#    date, so an answer means the glue against libc is right, not merely that the image ran.
s=0; shell "$results/boot.log" 120 "System.Time" || s=$?
report boot "$s" "$results/boot.log" '[0-9]{2}\.[0-9]{2}\.[0-9]{4}'

# 2. The collector, the write barriers and leave tracking, three times over. A race that shows
#    up one run in ten is a defect too, and this is the check that a real processor changes.
for n in 1 2 3; do
	s=0; shell "$results/gc-$n.log" 900 \
		"Files.AddSearchPath $lib" "Files.AddSearchPath $work" "A64GCStress.Run" || s=$?
	report "collector, run $n" "$s" "$results/gc-$n.log" 'A64GCStress: passed'
done

# 3. Loading modules into a running system: calls into the image, between two loaded modules,
#    within one, a module body, an active object body, a method through a type descriptor, a
#    procedure variable, and a collection with loaded code on the stack.
s=0; shell "$results/loader.log" 900 \
	"Files.AddSearchPath $lib" "Files.AddSearchPath $work" "A64Loader.Run" || s=$?
report "module loading" "$s" "$results/loader.log" 'A64Loader: passed'

# 4. The machine compiles a module itself and runs what it built. The order of the commands is
#    the recipe: the object directory goes on the search path first, because that is where the
#    compiler itself is loaded from; the module is named absolutely, because a relative name is
#    resolved against the work path; no --destPath, because giving one makes the compiler look
#    for symbol files there and nowhere else; then the directory it just wrote into goes on the
#    path as well, since what the system was started in is not on it by itself.
cp "$root/tests/A64OnDevice.Mod" "$work/"
s=0; shell "$results/selfhost.log" 1800 \
	"Files.AddSearchPath $lib" \
	"Compiler.Compile -p=UnixA64 '$work/A64OnDevice.Mod'" \
	"Files.AddSearchPath $work" \
	"A64OnDevice.Run" || s=$?
report "compiling on the device" "$s" "$results/selfhost.log" 'A64OnDevice: passed'
if [ ! -f "$work/A64OnDevice.GofU8" ] && [ "$s" -ne 124 ]; then
	echo "        (and it wrote no object file)"
fi

# 5. The language suites -- the point of the exercise. Some 6965 cases, of which the two
#    language suites are 5450 that compile and 695 that run; they have only ever run under an
#    emulator. `ob` sees an AArch64 runtime in this bundle and treats a64 as the native target,
#    so nothing here is cross-compiled and nothing is emulated.
if [ "$quick" = 1 ]; then
	echo "  skip  language suites            (--quick)"; skip=$((skip+1))
else
	echo "  ..    language suites            running; this is the long one"
	s=0; started=$SECONDS
	( cd "$root/tests" && A2SDK="$root" \
		timeout "${A64_SUITES_TIMEOUT:-10800}" bash "$root/ob" test -t a64 \
			--report "$results/suites.json" > "$results/suites.log" 2>&1 ) || s=$?
	_ELAPSED=$((SECONDS - started))
	line="$(grep -a '^ob test: .* case(s)' "$results/suites.log" | tail -1 | tr -d '\r')"
	if [ "$s" -eq 124 ]; then
		printf '  FAIL  %-28s did not finish in time\n' "language suites"
		FAILED+=("language suites"); fail=$((fail+1))
	elif [ "$s" -eq 0 ]; then
		printf '  ok    %-28s %6s  %s\n' "language suites" "${_ELAPSED}s" "${line#ob test: }"
		pass=$((pass+1))
	else
		printf '  FAIL  %-28s %s\n' "language suites" "${line:-left with $s}"
		FAILED+=("language suites"); fail=$((fail+1))
		awk '/^  FAIL |^  FIXED / && n++ < 20 { print "          " $0 }' "$results/suites.log"
	fi
	# A run that executed nothing would pass on compilation alone and say nothing about this
	# machine, which is the one outcome the whole trip exists to rule out.
	if ! grep -q 'AArch64 cases run natively' "$results/suites.log"; then
		echo "        WARNING: the suites did not run natively -- check ${results#$root/}/suites.log"
	fi
fi

echo
summary="$pass passed, $fail failed"
[ "$skip" -eq 0 ] || summary="$summary, $skip skipped"
echo "$summary; logs in ${results#$root/}/"
[ "$fail" -eq 0 ] || { printf 'failed: %s\n' "${FAILED[*]}"; exit 1; }
