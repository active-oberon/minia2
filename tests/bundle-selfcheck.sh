#!/usr/bin/env bash
#
# Does this SDK work? Asked of the tarball, from inside it, with nothing else on the machine.
#
# This script ships as run.sh in the bundle tests/bundle.sh assembles, and it is the whole
# acceptance test of a Docker-free release: every verb of `ob`, then the language suites. It
# knows nothing about the source tree -- no task, no Taskfile, no target/ -- and it must stay
# that way, because that is precisely the claim being checked. tests/bundle-check.sh runs it
# from the tree by unpacking a tarball and calling it here with a scrubbed environment.
#
# The verbs run from a temporary directory outside the SDK and call `ob` by absolute path,
# which is how a user actually works: the project is wherever they are, the SDK is elsewhere,
# and neither knows the other's layout.
#
# Usage: ./run.sh [-q|--quick]     (-q skips the language suites, which take a while)
# Results land in results/: one log per check.

set -uo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
ob="$root/ob"
# Logs go beside the SDK, unless told otherwise. The override is for the Docker image, which
# ships this script inside a read-only /opt/a2sdk: there the results belong in the mount.
results="${A2_RESULTS:-$root/results}"
quick=0
case "${1:-}" in
	-q|--quick) quick=1 ;;
	"") ;;
	*) echo "usage: $(basename "$0") [-q|--quick]" >&2; exit 2 ;;
esac

for tool in timeout mktemp od awk sed grep realpath; do
	command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool (install coreutils)" >&2; exit 2; }
done
[ -x "$ob" ] || { echo "no ob in $root" >&2; exit 2; }
[ -x "$root/oberon" ] || { echo "no runtime at $root/oberon" >&2; exit 2; }

# Said plainly, because the way this fails otherwise is eleven checks failing at once with a
# missing log file each: inside the Docker image /opt/a2sdk belongs to root and the SDK is not
# the place to write to -- set A2_RESULTS to somewhere that is.
mkdir -p "$results" 2>/dev/null || {
	echo "cannot write results to $results -- set A2_RESULTS to a writable directory" >&2
	exit 2
}
work="$(mktemp -d)" || work=""
[ -n "$work" ] && [ -d "$work" ] || {
	echo "mktemp could not make a working directory${TMPDIR:+ in $TMPDIR}" >&2
	echo "set TMPDIR to a writable directory" >&2
	exit 2
}
trap 'rm -rf "$work"' EXIT
cp "$root"/examples/*.Mod "$work/"

echo "machine:  $(uname -m), $(uname -r)"
echo "sdk:      $root ($(cat "$root/VERSION" 2>/dev/null || echo "no VERSION"))"
echo "shell:    ${BASH_VERSION:-unknown}, $(command -v git >/dev/null && echo "git yes" || echo "git no"), $(command -v jq >/dev/null && echo "jq yes" || echo "jq no")"
echo

pass=0; fail=0; skip=0
declare -a FAILED=()

# One check: a name, a log, and a pattern the log has to contain. `ob` exits non-zero on a real
# failure, so unlike the bare runtime both halves are read -- the status and the transcript.
report() {
	local name="$1" status="$2" log="$3" want="$4" took="${_ELAPSED:-0}s"
	if [ "$status" -eq 124 ]; then
		printf '  FAIL  %-30s did not finish in time\n' "$name"; FAILED+=("$name"); fail=$((fail+1)); return
	fi
	if [ "$status" -ne 0 ]; then
		printf '  FAIL  %-30s ob exited %d\n' "$name" "$status"
		FAILED+=("$name"); fail=$((fail+1))
		tail -12 "$log" | tr -d '\r' | sed 's/^/          /'
		return
	fi
	if [ -n "$want" ] && ! grep -qE "$want" "$log"; then
		printf '  FAIL  %-30s no "%s" in %s\n' "$name" "$want" "${log#"$root"/}"
		FAILED+=("$name"); fail=$((fail+1))
		tail -12 "$log" | tr -d '\r' | sed 's/^/          /'
		return
	fi
	printf '  ok    %-30s %6s  %s\n' "$name" "$took" "${log#"$root"/}"; pass=$((pass+1))
}

skipped() { printf '  skip  %-30s %s\n' "$1" "$2"; skip=$((skip+1)); }

# Run one command from the work directory, timed, with its output in a log.
run() {
	local log="$1" limit="$2"; shift 2
	local status=0 started=$SECONDS
	( cd "$work" && timeout "$limit" "$@" > "$log" 2>&1 ) || status=$?
	_ELAPSED=$((SECONDS - started))
	return $status
}

# 1. It knows what it is. The point of the check is the first line of the answer: `ob` was found
#    by absolute path from a directory that is not the SDK, and it located its own runtime -- the
#    thing that used to come from $A2SDK being set for it by a container.
s=0; run "$results/version.log" 60 "$ob" version || s=$?
report "ob version" "$s" "$results/version.log" "sdk *: $root"

# 2. Compile and run in one step, which is the verb everything else rests on: it is a compile
#    against the shipped standard library, a link of nothing, and an execution in this process.
s=0; run "$results/run.log" 300 "$ob" run Hello.Mod || s=$?
report "ob run" "$s" "$results/run.log" 'Hello from A2'

# 3. A standalone executable, and then the executable. Two claims: the linker found the boot
#    modules in lib/, and what came out runs on a machine with no A2 on it -- which this
#    machine, as far as the binary is concerned, is.
s=0; run "$results/build.log" 600 "$ob" build Hello.Mod -o hello || s=$?
report "ob build" "$s" "$results/build.log" 'wrote .*hello'
if [ -x "$work/hello" ]; then
	s=0; run "$results/build-run.log" 120 ./hello || s=$?
	report "the binary it built" "$s" "$results/build-run.log" 'Hello from A2'
else
	skipped "the binary it built" "nothing to run -- the link produced no file"
fi

# 4. One module to an object file, the verb a build system would call. The transcript is checked
#    and so is the file: `ob compile` reporting a path it did not write would pass on the log alone.
s=0; run "$results/compile.log" 300 "$ob" compile JsonDemo.Mod -o obj || s=$?
report "ob compile" "$s" "$results/compile.log" 'wrote .*JsonDemo\.GofUu'
[ -f "$work/obj/JsonDemo.GofUu" ] || { echo "        (and the object file is not there)"; }

# 5. A project of more than one module, which is what anything real is: three of them, with a
#    two-deep import chain, in a directory of their own. The compiler resolves imports from its
#    working directory and nowhere else, so a sibling is importable only because `ob` puts the
#    project there -- and until this was written it did that for the language server, `ob doc`
#    and `ob test`, but not for compile, run or build. So an editor understood a multi-module
#    project and the compiler could not build one, which is the shape of thing a check of every
#    verb over one file each will never notice.
multi="$work/multi"
mkdir -p "$multi"
cat > "$multi/Util.Mod" <<'MOD'
MODULE Util;
	PROCEDURE Twice*(x: SIGNED32): SIGNED32;
	BEGIN RETURN 2 * x END Twice;
END Util.
MOD
cat > "$multi/Deep.Mod" <<'MOD'
MODULE Deep;
IMPORT Util;
	PROCEDURE Quad*(x: SIGNED32): SIGNED32;
	BEGIN RETURN Util.Twice(Util.Twice(x)) END Quad;
END Deep.
MOD
cat > "$multi/App.Mod" <<'MOD'
MODULE App;
IMPORT KernelLog, Deep;
	PROCEDURE Do*;
	BEGIN KernelLog.String("quad 11 = "); KernelLog.Int(Deep.Quad(11), 0); KernelLog.Ln
	END Do;
END App.
MOD
s=0; started=$SECONDS
( cd "$multi" && timeout 600 "$ob" run App.Mod > "$results/multi.log" 2>&1 ) || s=$?
_ELAPSED=$((SECONDS - started))
report "a project of three modules" "$s" "$results/multi.log" 'quad 11 = 44'

# 6. The tier rule over the project's own sources, read from the std manifests in packages/.
#    Without those manifests in the bundle this verb cannot say anything, so it is also the
#    check that they shipped.
s=0; run "$results/lint.log" 120 "$ob" lint || s=$?
report "ob lint" "$s" "$results/lint.log" 'no upward dependencies'

# 7. HTML from the doc comments, through the compiler's own Documentation backend.
s=0; run "$results/doc.log" 300 "$ob" doc -o apidoc || s=$?
if [ -f "$work/apidoc/Hello.html" ]; then
	report "ob doc" "$s" "$results/doc.log" ''
else
	printf '  FAIL  %-30s no apidoc/Hello.html was written\n' "ob doc"
	FAILED+=("ob doc"); fail=$((fail+1))
	tail -12 "$results/doc.log" | tr -d '\r' | sed 's/^/          /'
fi

# 8. The language server, which is the reason a good many people would want this tarball at all
#    and the one verb no editor-less check had ever covered. Spoken to the way an editor speaks
#    to it -- LSP over stdio, Content-Length framing -- and asked the one question whose answer
#    proves the server came up: initialize. Then shutdown/exit, so it leaves of its own accord
#    rather than on a timeout.
#
#    rootUri is the work directory: the server seeds its scratch dir from the project, and a
#    server that resolved nothing would still answer initialize, so the request after it opens a
#    module with a deliberate error and waits for the diagnostic to come back.
lsp_msg() { local body="$1"; printf 'Content-Length: %d\r\n\r\n%s' "${#body}" "$body"; }
lsp_talk() {
	lsp_msg '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":null,"rootUri":"file://'"$work"'","capabilities":{}}}'
	lsp_msg '{"jsonrpc":"2.0","method":"initialized","params":{}}'
	lsp_msg '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file://'"$work"'/Broken.Mod","languageId":"oberon","version":1,"text":"MODULE Broken;\nBEGIN\n\tundefined := 1\nEND Broken.\n"}}}'
	# Written into the pipe as the conversation goes, not into a file beforehand: diagnostics
	# come when the checker has run, and a shutdown that arrives in the same read as the didOpen
	# would be a race over whether anything was checked at all.
	sleep 15
	lsp_msg '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
	lsp_msg '{"jsonrpc":"2.0","method":"exit","params":null}'
	sleep 2
}
s=0; started=$SECONDS
# A SIGPIPE in the producer (the server leaving first) is not a failure of the server, so only
# the timeout and the transcript are read.
( cd "$work" && lsp_talk | timeout 120 "$ob" lsp > "$results/lsp.log" 2>&1 ) || s=$?
_ELAPSED=$((SECONDS - started))
if [ "$s" -eq 124 ]; then
	printf '  FAIL  %-30s the server did not exit on shutdown\n' "ob lsp"
	FAILED+=("ob lsp"); fail=$((fail+1))
elif ! grep -q 'capabilities' "$results/lsp.log"; then
	printf '  FAIL  %-30s no capabilities in the initialize reply\n' "ob lsp"
	FAILED+=("ob lsp"); fail=$((fail+1))
	tail -12 "$results/lsp.log" | tr -d '\r' | sed 's/^/          /'
elif ! grep -q 'publishDiagnostics' "$results/lsp.log"; then
	printf '  FAIL  %-30s it answered initialize but diagnosed nothing\n' "ob lsp"
	FAILED+=("ob lsp"); fail=$((fail+1))
	tail -12 "$results/lsp.log" | tr -d '\r' | sed 's/^/          /'
else
	printf '  ok    %-30s %6s  %s\n' "ob lsp" "${_ELAPSED}s" "${results#"$root"/}/lsp.log"; pass=$((pass+1))
fi

# 9. The interactive shell, which is the one verb that runs the runtime in the user's own
#    directory rather than in a scratch dir -- so it is also the check that oberon.cfg's
#    relative search paths do no harm where none of them exists. `exit` is what leaves the
#    shell: on end of input it spins rather than stopping.
s=0; started=$SECONDS
( cd "$work" && printf 'System.Time\nexit\n' | timeout 120 "$ob" repl > "$results/repl.log" 2>&1 ) || s=$?
_ELAPSED=$((SECONDS - started))
report "ob repl" "$s" "$results/repl.log" '[0-9]{2}\.[0-9]{2}\.[0-9]{4}'

# `ob get` is not checked here and the count says so rather than passing over it: fetching a
# package needs a network and a remote that is up, neither of which a release check may assume.
skipped "ob get" "needs a network -- not something a self-check may assume"

# 10. The cross targets, each only if this bundle carries its objects. What is checked is the file
#    that came out, by its magic number rather than by the linker's own say-so: a PE64 console
#    image begins MZ and carries PE\0\0 at the offset its DOS stub points at, and an AArch64 ELF
#    says b7 in e_machine. Neither can be run here, which is the whole reason to look at the bytes.
if [ -d "$root/lib-win64" ]; then
	s=0; run "$results/build-win64.log" 600 "$ob" build Hello.Mod -t win64 -o hello.exe || s=$?
	if [ "$s" -eq 0 ] && [ "$(od -An -c -N2 -- "$work/hello.exe" 2>/dev/null | tr -d ' \n')" = "MZ" ]; then
		printf '  ok    %-30s %6s  %s\n' "ob build -t win64" "${_ELAPSED}s" "${results#"$root"/}/build-win64.log"
		pass=$((pass+1))
	else
		printf '  FAIL  %-30s no PE64 .exe came out\n' "ob build -t win64"
		FAILED+=("ob build -t win64"); fail=$((fail+1))
		tail -12 "$results/build-win64.log" | tr -d '\r' | sed 's/^/          /'
	fi
else
	skipped "ob build -t win64" "this bundle carries no Win64 objects"
fi

if [ -d "$root/lib-a64" ]; then
	s=0; run "$results/build-a64.log" 600 "$ob" build Hello.Mod -t a64 -o hello-arm64 || s=$?
	arch="$(od -An -tx1 -j18 -N2 -- "$work/hello-arm64" 2>/dev/null | tr -d ' \n')"
	if [ "$s" -eq 0 ] && [ "$arch" = "b700" ]; then
		printf '  ok    %-30s %6s  %s\n' "ob build -t a64" "${_ELAPSED}s" "${results#"$root"/}/build-a64.log"
		pass=$((pass+1))
		# If there is an emulator and an AArch64 C library, the binary is also run. Neither is
		# expected on the machine unpacking a tarball, so its absence is a skip and not a gap.
		#
		# Both names, because the Debian package that CI installs is qemu-user-static and what
		# it puts on the PATH is qemu-aarch64-static -- looking only for qemu-aarch64 skipped
		# this on the one machine that could have run it. And -L, because the binary is
		# dynamically linked: without a directory holding ld-linux-aarch64.so.1 the emulator
		# has nothing to start it with. libc6-arm64-cross puts one at /usr/aarch64-linux-gnu.
		qemu="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
		sysroot="${A64_SYSROOT:-}"
		[ -n "$sysroot" ] || for c in /usr/aarch64-linux-gnu /usr/aarch64-linux-gnu/libc; do
			[ -f "$c/lib/ld-linux-aarch64.so.1" ] && { sysroot="$c"; break; }
		done
		if [ -n "$qemu" ]; then
			qargs=("$qemu"); [ -n "$sysroot" ] && qargs+=(-L "$sysroot"); qargs+=(./hello-arm64)
			s=0; run "$results/run-a64.log" 300 "${qargs[@]}" || s=$?
			if [ "$s" -eq 0 ] && grep -q 'Hello from A2' "$results/run-a64.log"; then
				printf '  ok    %-30s %6s  %s\n' "the AArch64 binary, emulated" "${_ELAPSED}s" \
					"${results#"$root"/}/run-a64.log"
				pass=$((pass+1))
			else
				skipped "the AArch64 binary, emulated" "qemu is here but could not run it (C library?)"
			fi
		else
			skipped "the AArch64 binary, emulated" "no qemu-aarch64 or qemu-aarch64-static here"
		fi
	else
		printf '  FAIL  %-30s no AArch64 ELF came out (e_machine %s)\n' "ob build -t a64" "${arch:-none}"
		FAILED+=("ob build -t a64"); fail=$((fail+1))
		tail -12 "$results/build-a64.log" | tr -d '\r' | sed 's/^/          /'
	fi
else
	skipped "ob build -t a64" "this bundle carries no AArch64 objects"
fi

# 11. The language suites, run out of the bundle's own tests/ against the bundle's own baseline.
#    Thousands of cases, each compiled and executed in a process of its own -- the long check,
#    and the one that says this tarball's compiler is the compiler the tree tests. --quick runs
#    one suite instead, which is enough to prove the harness works and nothing about the release.
if [ "$quick" = 1 ]; then
	s=0; started=$SECONDS
	( cd "$root/tests" && timeout 900 "$ob" test JSON.Test > "$results/suites.log" 2>&1 ) || s=$?
	_ELAPSED=$((SECONDS - started))
	report "one suite (--quick)" "$s" "$results/suites.log" '[0-9]+ passed, 0 failed'
else
	s=0; started=$SECONDS
	( cd "$root/tests" && timeout 10800 "$ob" test --report "$results/suites.json" \
		> "$results/suites.log" 2>&1 ) || s=$?
	_ELAPSED=$((SECONDS - started))
	report "the language suites" "$s" "$results/suites.log" '[0-9]+ passed, 0 failed'
fi

echo
echo "passed $pass, failed $fail, skipped $skip"
if [ "$fail" -gt 0 ]; then
	printf 'failed: %s\n' "${FAILED[*]}"
	echo "logs in ${results#"$root"/}/"
	exit 1
fi
echo "this SDK works: $root"
