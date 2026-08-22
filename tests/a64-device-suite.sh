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
# Checked, because the interesting way for this to fail is silently. mktemp writes into $TMPDIR or
# /tmp, and on Android there is no /tmp: with neither, mktemp fails, `work` is the empty string, and
# every path built on it -- the working directory of each check, the module each one compiles -- turns
# into a path starting at the root, which is read only. What that looks like is not a missing
# temporary directory but three failing collector runs and a compile that cannot open its own input.
# So: say it here instead.
work="$(mktemp -d)" || work=""
[ -n "$work" ] && [ -d "$work" ] || {
	echo "mktemp could not make a working directory${TMPDIR:+ in $TMPDIR}" >&2
	echo "set TMPDIR to a writable directory (Android has no /tmp)" >&2
	exit 2
}
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

# 4b. `ob build`, and then the program it built. The second half is the point: the suite proved for
#     months that the compiler works on the device and never once started what it produced -- so on
#     Android `ob build` wrote a plain A2 image, the kernel refused it with "only supports
#     position-independent executables", and this run stayed green. A build whose output nobody
#     starts is not a build that works.
s=0; started=$SECONDS
( cd "$work" && PWD="$work" timeout 600 "$root/ob" build "$root/examples/Hello.Mod" -o "$work/hello" \
	> "$results/obbuild.log" 2>&1 ) || s=$?
if [ "$s" -eq 0 ] && [ -x "$work/hello" ]; then
	( cd "$work" && PWD="$work" timeout 120 "$work/hello" >> "$results/obbuild.log" 2>&1 ) || s=$?
elif [ "$s" -eq 0 ]; then
	echo "ob build reported success and left no executable at $work/hello" >> "$results/obbuild.log"
	s=1
fi
_ELAPSED=$((SECONDS - started))
report "ob build, and running it" "$s" "$results/obbuild.log" 'Hello from A2'

# 4c. The language server, on this machine, answering about a module that imports one thing. Three
#     places in LSP.Mod compiled for a hardcoded platform, so on AArch64 the server looked for
#     .SymUu beside a library of .SymU8 and called every import unknown -- in a two-line Hello.
#     Nothing anywhere ran `ob lsp` off x86-64, which is why it stayed broken through two fixes.
#     A minimal LSP session over stdio: initialize, didOpen, and the first publishDiagnostics.
lspreq() { printf 'Content-Length: %d\r\n\r\n%s' "${#1}" "$1"; }
lsphello='{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/LspProbe.Mod","languageId":"oberon","version":1,"text":"MODULE LspProbe;\nIMPORT KernelLog;\nBEGIN KernelLog.String(\"x\"); KernelLog.Ln\nEND LspProbe.\n"}}}'
s=0; started=$SECONDS
{
	lspreq '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":"file:///tmp","capabilities":{}}}'
	lspreq '{"jsonrpc":"2.0","method":"initialized","params":{}}'
	lspreq "$lsphello"
	sleep 45
} | ( cd "$work" && PWD="$work" timeout 120 "$root/ob" lsp > "$results/lsp.log" 2>&1 ) || s=$?
_ELAPSED=$((SECONDS - started))
if grep -q 'could not import' "$results/lsp.log"; then
	printf '  FAIL  %-28s the server could not import KernelLog\n' "the language server"
	FAILED+=("the language server"); fail=$((fail+1))
	grep -o 'could not import [A-Za-z]*' "$results/lsp.log" | sort -u | sed 's/^/          /'
else
	report "the language server" "$s" "$results/lsp.log" '"diagnostics":\[\]'
fi

# 5. A fault on a thread that is not ours goes back to whoever handled it before us. Only in the
#    Android bundle, because only there is the harness built (tests/a64-bundle.sh) -- and only there
#    does it matter in earnest: an application belongs to ART before it belongs to us, and ART
#    catches SIGSEGV to check for nil itself, so every fault in the process would otherwise arrive
#    at our trap handler on threads we have no process for.
#
#    `sigchain` installs a handler of its own, starts this image on a thread of its own, and faults
#    on the thread that stayed behind. Its own handler has to be the one that runs -- and the shell's
#    banner in the same transcript is what says A2 was up and had taken the signal over by then.
if [ -x "$root/sigchain" ]; then
	s=0; started=$SECONDS
	( cd "$work" && PWD="$work" sleep 30 \
		| A2_IMAGE="$root/oberon.img" timeout 120 "$root/sigchain" > "$results/sigchain.log" 2>&1 ) || s=$?
	_ELAPSED=$((SECONDS - started))
	if ! grep -q 'Shell v' "$results/sigchain.log"; then
		printf '  FAIL  %-28s the image did not come up, so nothing was proved\n' "foreign thread's fault"
		FAILED+=("foreign thread's fault"); fail=$((fail+1))
		tail -12 "$results/sigchain.log" | tr -d '\r' | sed 's/^/          /'
	else
		report "foreign thread's fault" "$s" "$results/sigchain.log" \
			'handler installed before A2 was given the signal'
	fi
fi

# 6. The picture a display driver is handed, without a screen to look at. The driver over the
#    window of the application can only be seen there, but what it is fed -- the arithmetic, the row
#    buffer, the strides through Displays.Transfer, the colour word -- is the same code here, and
#    this machine is the one whose backend is new. The shape is compared on the host as well
#    (tests/display-check.sh); here it is enough that the two pictures come out and agree with it.
if [ -f "$lib/DisplayDemo.GofU8" ] && [ -f "$root/tests/display-expected.txt" ]; then
	s=0; shell "$results/display.log" 600 \
		"Files.AddSearchPath $lib" "DisplayDemo.Ascii" "DisplayDemo.Check" || s=$?
	#	Carriage returns off first, and the shell's prompt off the front: the transcript of an
	#	interactive shell puts a `>` in front of the first line each command prints, and the first line
	#	of each of these two pictures is a blank one -- which is exactly the line that would go missing.
	got=$(tr -d '\r' < "$results/display.log" | sed 's/^>*//' | grep -aE '^[ .+#]{78}$' || true)
	if [ "$got" = "$(cat "$root/tests/display-expected.txt")" ]; then
		printf '  ok    %-28s %6s  %s\n' "the picture drawn" "${_ELAPSED}s" "${results#$root/}/display.log"
		pass=$((pass+1))
	else
		printf '  FAIL  %-28s the pictures differ from tests/display-expected.txt\n' "the picture drawn"
		FAILED+=("the picture drawn"); fail=$((fail+1))
		diff "$root/tests/display-expected.txt" <(printf '%s\n' "$got") | head -12 | sed 's/^/          /'
	fi
fi

# 7. A2's own window manager, over a display that is nothing but memory. One layer above the check
#    before it: Raster, WMGraphics, the font compiled into WMDefaultFont, the decoration, and the
#    compositing in WindowManager -- all of it loaded into this runtime, none of it in the image.
#    That is the whole of what the window on a phone shows except the last copy into ANativeWindow,
#    and it is the first time any of it has run on AArch64. Two answers: the window's own picture,
#    which is the same picture everywhere because the font is the embedded one, and where the window
#    landed, which is counted rather than recorded because the title bar is drawn in whatever font
#    the machine happens to have.
if [ -f "$lib/WMDemo.GofU8" ] && [ -f "$root/tests/wm-expected.txt" ]; then
	s=0; shell "$results/wm.log" 900 "Files.AddSearchPath $lib" "WMDemo.Check" || s=$?
	clean=$(tr -d '\r' < "$results/wm.log" | sed 's/^>*//')
	placement=$(printf '%s\n' "$clean" | grep -aoE 'window [0-9]+ of [0-9]+, background [0-9]+ of [0-9]+' | tail -1)
	#	The window's picture is the second of the two printed; the screen's, printed first, is for the
	#	eye in the log and not for comparing -- see the comment above.
	got=$(printf '%s\n' "$clean" | grep -aE '^[ .+#]{78}$' | tail -30)
	whole=0
	case "$placement" in
		*" of "*) set -- $(printf '%s\n' "$placement" | tr -d ','); \
			[ "$2" = "$4" ] && [ "$6" = "$8" ] && [ "$2" != 0 ] && [ "$6" != 0 ] && whole=1 ;;
	esac
	if [ "$whole" = 1 ] && [ "$got" = "$(cat "$root/tests/wm-expected.txt")" ]; then
		printf '  ok    %-28s %6s  %s\n' "the window manager" "${_ELAPSED}s" "${results#$root/}/wm.log"
		pass=$((pass+1))
	elif [ "$whole" != 1 ]; then
		printf '  FAIL  %-28s %s\n' "the window manager" "the window is not where it was put: ${placement:-nothing said}"
		FAILED+=("the window manager"); fail=$((fail+1))
		tail -12 "$results/wm.log" | sed 's/^/          /'
	else
		printf '  FAIL  %-28s the window differs from tests/wm-expected.txt\n' "the window manager"
		FAILED+=("the window manager"); fail=$((fail+1))
		diff "$root/tests/wm-expected.txt" <(printf '%s\n' "$got") | head -12 | sed 's/^/          /'
	fi
fi

# 8. The language suites -- the point of the exercise. Some 6965 cases, of which the two
#    language suites are 5450 that compile and 695 that run; they have only ever run under an
#    emulator. `ob` sees an AArch64 runtime in this bundle and treats a64 as the native target,
#    so nothing here is cross-compiled and nothing is emulated.
if [ "$quick" = 1 ]; then
	echo "  skip  language suites            (--quick)"; skip=$((skip+1))
else
	echo "  ..    language suites            running; this is the long one"
	s=0; started=$SECONDS
	#    -j: a case is a process, and a phone has cores. Four rather than all of them because
	#    this has not been run on a device yet and a compiler per core is the memory-hungry
	#    shape; A64_SUITES_JOBS overrides, and 1 is the old behaviour.
	( cd "$root/tests" && A2SDK="$root" \
		timeout "${A64_SUITES_TIMEOUT:-10800}" "$root/ob" test -t a64 \
			-j "${A64_SUITES_JOBS:-4}" \
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
