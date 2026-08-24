#!/usr/bin/env bash
#
# `ob` written in Active Oberon: built, and made to answer for itself.
#
# The shell `ob` (sdk/ob) drives a separate `oberon` process for every compile. This one IS the
# compiler: sdk/Ob.Mod is linked last into a binary that already holds Fox, so a verb calls
# Compiler.Modules in this process and nothing is started. What that removes, besides the process:
#
#   -  the scratch directory full of symlinks to the standard library. Imports resolve through the
#      Files search path, so a verb names lib/ and is done.
#   -  reading the SDK's own ELF header to learn its architecture. This binary is the architecture.
#
# The checks below are the ones that would have caught every mistake made while writing it: the
# banner against the shell version's, a module that imports a sibling with nothing precompiled,
# the two failure paths (bad source, missing file) and their exit codes, and the scratch directory
# afterwards -- which is where Files' own enumerator, blind to dot files, left one behind.
#
# Usage: tests/ob-check.sh [build directory] [SDK directory]

set -eo pipefail

# The shell version walks a directory by globbing, and a glob is sorted by the locale's collation;
# the native one sorts by character. On an en_US machine those disagree about where CSV.Test goes,
# and two transcripts that differ only in the order of whole files read as a difference in results.
# Fixing the collation here is what makes "the same run" a statement about the drivers.
export LC_ALL=C

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
case "$build" in /*) ;; *) build="$PWD/$build" ;; esac
sdk="${2:-$root/target/bundle}"
case "$sdk" in /*) ;; *) sdk="$PWD/$sdk" ;; esac

oberon="$build/oberon"
if [ ! -x "$oberon" ]; then
	echo "no built runtime in $build; run 'task Linux64' first" >&2
	exit 2
fi
if [ ! -d "$sdk/lib" ]; then
	echo "no SDK layout in $sdk; run 'task bundle' first" >&2
	exit 2
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/ob-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The sources go in under their MODULE names: a platform-prefixed file compiles to the module's
# name whatever the file is called, but the linker is given module names and looks for objects.
cp "$root/sdk/Unix.ObHost.Mod" "$work/ObHost.Mod"
cp "$root/sdk/Ob.Mod"          "$work/Ob.Mod"

echo "=== compiling"
( cd "$work" && "$oberon" do "
	Files.AddSearchPath $work~
	Files.AddSearchPath $build/bin~
	Compiler.Compile -p=Unix64 --objectFileExtension=GofUu --symbolFileExtension=.SymUu ./ObHost.Mod ~
	Compiler.Compile -p=Unix64 --objectFileExtension=GofUu --symbolFileExtension=.SymUu ./Ob.Mod ~
" ) || { echo "FAIL: ob does not compile" >&2; exit 1; }

# The boot set without the interactive shell -- Ob's own body is the program. Everything else it
# needs, Fox included, the linker pulls in as the import closure of Ob.
boot="$(grep -vE '^(StdIOShell|Shell)$' "$sdk/boot-modules.txt" | tr '\n' ' ')"

echo "=== linking"
( cd "$work" && "$oberon" do "
	Files.AddSearchPath $work~
	Files.AddSearchPath $build/bin~
	Linker.Link -p=Linux64 --extension=GofUu --fileName='ob'
	$boot Ob
	~
" ) | grep -vE '^GC mode|^WORK:' || true
[ -f "$work/ob" ] || { echo "FAIL: link produced no binary" >&2; exit 1; }
chmod +x "$work/ob"
ob="$work/ob"

fail=0
check() {  # check <name> <expected exit> <command...>
	local name="$1" want="$2"; shift 2
	local output rc=0
	output="$("$@" 2>&1)" || rc=$?
	if [ "$rc" != "$want" ]; then
		echo "FAIL  $name: exit $rc, expected $want"; echo "$output" | sed 's/^/        /'; fail=1
	else
		echo "ok    $name"
	fi
	LAST_OUTPUT="$output"
}

export A2SDK="$sdk"

# The shell driver is the reference, and it is taken from the tree rather than from the SDK: the
# SDK ships this very binary now, so `$sdk/ob` would compare the native version with itself and
# every check below would pass without proving anything. It reads $A2SDK for its payload.
shellob="$root/sdk/ob"

echo "=== the banner says what the shell version says"
"$shellob" version | grep -v '^  runtime' > "$work/banner-shell.txt"
"$ob"      version | grep -v '^  runtime' > "$work/banner-native.txt"
if diff -u "$work/banner-shell.txt" "$work/banner-native.txt" > "$work/banner.diff"; then
	echo "ok    version banner"
else
	echo "FAIL  version banner differs from the shell version"; sed 's/^/        /' "$work/banner.diff"; fail=1
fi

echo "=== verbs"
project="$work/project"
mkdir -p "$project"
cat > "$project/Greet.Mod" <<'EOF'
MODULE Greet;
IMPORT Strings;
PROCEDURE Text*(VAR s: ARRAY OF CHAR);
BEGIN s := "hello from a sibling"; Strings.Append(s, "!")
END Text;
END Greet.
EOF
cat > "$project/Hello.Mod" <<'EOF'
MODULE Hello;
IMPORT Commands, Greet;
PROCEDURE Do*(context: Commands.Context);
VAR s: ARRAY 64 OF CHAR;
BEGIN Greet.Text(s); context.out.String(s); context.out.Ln; context.out.Update
END Do;
END Hello.
EOF
printf 'MODULE Bad;\nBEGIN nonsense\nEND Bad.\n' > "$project/Bad.Mod"

cd "$project"

# ob names its scratch directory after its process id and puts it under $TMPDIR. Point that at a
# directory of this check's own: a glob over /tmp/ob-* would belong to every ob on the machine, and
# deleting one out from under a running `ob test` makes it report every later case as having no
# MODULE in it -- which is exactly how this check spent an afternoon accusing the wrong code.
export TMPDIR="$work/tmp"
mkdir -p "$TMPDIR"

# Nothing is precompiled: the sibling has to be built on the way, or the import does not resolve.
check "run, sibling compiled on the way" 0 "$ob" run Hello.Mod
case "$LAST_OUTPUT" in
	*"hello from a sibling!"*) echo "ok    run printed what the module prints" ;;
	*) echo "FAIL  run printed: $LAST_OUTPUT"; fail=1 ;;
esac

# A verb that leaves objects in the user's directory is a verb that has broken the project.
leftovers="$(ls "$project" | grep -vE '\.Mod$' || true)"
if [ -z "$leftovers" ]; then echo "ok    run left the project alone"
else echo "FAIL  run left in the project: $leftovers"; fail=1; fi

if [ -z "$(ls -A "$TMPDIR" 2>/dev/null || true)" ]; then echo "ok    run removed its scratch directory"
else echo "FAIL  run left a scratch directory behind: $(ls -A "$TMPDIR")"; fail=1; fi

check "compile" 0 "$ob" compile Hello.Mod -o out
[ -f "$project/out/Hello.GofUu" ] && echo "ok    compile wrote the object file" \
	|| { echo "FAIL  compile wrote no out/Hello.GofUu"; fail=1; }

check "compile reports an error and fails" 1 "$ob" compile Bad.Mod
case "$LAST_OUTPUT" in
	*"Undeclared Identifier"*) echo "ok    compile said what was wrong" ;;
	*) echo "FAIL  compile said: $LAST_OUTPUT"; fail=1 ;;
esac

# A source saved by A2's own editors: the binary Text format -- F0X 01X, the offset of the text,
# then the font table, whose bytes include 0X. Fox reads it (FoxBasic.GetFileReader skips to the
# offset), and until 2026-08-24 ob did not: it opened the file as plain text, found no line
# starting with MODULE, and said "no MODULE header" about a file the compiler compiles. Half of
# a2oberon/ocp is saved this way, so the packages could not be built through ob at all.
{ printf '\360\001\010\000\001\000\002\000'
  printf 'MODULE Textual;\nIMPORT Commands;\n\tPROCEDURE Do* (context: Commands.Context);\n'
  printf '\tBEGIN context.out.String("from a Text"); context.out.Ln\n\tEND Do;\nEND Textual.\n'
} > "$project/Textual.Mod"
check "compile, a source in A2's binary Text format" 0 "$ob" compile Textual.Mod -o out
[ -f "$project/out/Textual.GofUu" ] && echo "ok    the Text-format source produced its object" \
	|| { echo "FAIL  no out/Textual.GofUu from a Text-format source"; fail=1; }

# And a source in the lowercase dialect: the scanner decides a file's case by its first keyword
# (FoxScanner.Mod:987) and needs no option to compile `module M;`, so ob has no business demanding
# capitals -- ocp/YR/SmallPT.mod is written that way.
printf 'module Lower;\n\tprocedure Do*;\n\tbegin\n\tend Do;\nend Lower.\n' > "$project/Lower.Mod"
check "compile, the lowercase dialect" 0 "$ob" compile Lower.Mod -o out
[ -f "$project/out/Lower.GofUu" ] && echo "ok    the lowercase source produced its object" \
	|| { echo "FAIL  no out/Lower.GofUu from a lowercase source"; fail=1; }

# `{TEST}` procedures: the compiler has known about them all along (FoxTestBackend writes one case
# per procedure) and ob had no way to ask. Given a source rather than a test file, ob test harvests
# it -- so an invariant can live in the module it is about. The failing one must fail: a harvest that
# reports everything green would be worse than no harvest at all.
printf 'MODULE SelfOk;\nVAR x: SIGNED32;\n\tPROCEDURE {TEST} Invariant*;\n\tBEGIN ASSERT(x = 0)\n\tEND Invariant;\nBEGIN x := 0\nEND SelfOk.\n' > "$project/SelfOk.Mod"
printf 'MODULE SelfBad;\nVAR x: SIGNED32;\n\tPROCEDURE {TEST} Invariant*;\n\tBEGIN ASSERT(x = 1)\n\tEND Invariant;\nBEGIN x := 0\nEND SelfBad.\n' > "$project/SelfBad.Mod"
check "test harvests {TEST} procedures from a source" 1 "$ob" test SelfOk.Mod SelfBad.Mod
case "$LAST_OUTPUT" in
	*"2 case(s), 1 passed, 1 failed"*) echo "ok    the harvested invariant passed and the broken one failed" ;;
	*) echo "FAIL  harvest said: $(printf '%s' "$LAST_OUTPUT" | tr '\n' ' ' | tail -c 120)"; fail=1 ;;
esac
check "test says so when a source has no {TEST}" 0 "$ob" test Hello.Mod
case "$LAST_OUTPUT" in
	*"no {TEST} procedure"*) echo "ok    a source without invariants is reported, not run" ;;
	*) echo "FAIL  a source without {TEST} said: $LAST_OUTPUT"; fail=1 ;;
esac
rm -f "$project/SelfOk.Mod" "$project/SelfBad.Mod"

check "a missing file fails" 1 "$ob" compile NoSuchModule.Mod
check "an unknown verb fails"  1 "$ob" frobnicate
check "help" 0 "$ob" help

echo "=== build, against the shell version byte for byte"
mkdir -p "$project/shell"
# The dash in hello-arm64 is the check, not decoration: the linker's option parser reads an
# unquoted value up to the first character that cannot be in a name, and this one used to become
# the file `hello` followed by the flags -a -r -m -6 -4.
for spec in "linux64 hello" "win64 hello.exe" "a64 hello-arm64"; do
	set -- $spec
	target="$1" name="$2"
	if [ "$target" != linux64 ] && [ ! -d "$sdk/lib-${target}" ]; then
		echo "skip  build $target: this SDK ships no lib-$target"; continue
	fi
	rm -f "$name" "shell/$name"
	if "$ob" build Hello.Mod -t "$target" -o "$name" >/dev/null 2>&1 \
			&& "$shellob" build Hello.Mod -t "$target" -o "shell/$name" >/dev/null 2>&1; then
		if cmp -s "$name" "shell/$name"; then echo "ok    build $target is byte for byte the shell version's"
		else echo "FAIL  build $target differs from the shell version's binary"; fail=1; fi
	else
		echo "FAIL  build $target did not produce a binary"; fail=1
	fi
done

# The one target whose output can be run here is the one this SDK is.
check "the built binary runs" 0 "$project/hello"
case "$LAST_OUTPUT" in
	*"hello from a sibling!"*) echo "ok    the built binary printed what the module prints" ;;
	*) echo "FAIL  the built binary printed: $LAST_OUTPUT"; fail=1 ;;
esac

echo "=== lint, against the shell version's own words"
lint="$work/lint"
mkdir -p "$lint"
# A module whose name a tier-0 package provides, importing a tier-2 one: the upward edge the
# tier model exists to forbid. Project code sits at the top and can import anything, so a plain
# project module could never produce one.
cat > "$lint/Strings.Mod" <<'EOF'
MODULE Strings;
IMPORT CSV;
PROCEDURE Do*;
BEGIN
END Do;
END Strings.
EOF
( cd "$lint"
  rc=0; "$ob"     lint > "$work/lint-native.txt" 2>&1 || rc=$?; echo "exit $rc" >> "$work/lint-native.txt"
  rc=0; "$shellob" lint > "$work/lint-shell.txt"  2>&1 || rc=$?; echo "exit $rc" >> "$work/lint-shell.txt" )
if diff -u "$work/lint-shell.txt" "$work/lint-native.txt" > "$work/lint.diff"; then
	echo "ok    lint says what the shell version says, and fails the same way"
else
	echo "FAIL  lint differs from the shell version"; sed 's/^/        /' "$work/lint.diff"; fail=1
fi
check "lint passes on a project with no upward edge" 0 "$ob" lint

echo "=== test, against the shell version case by case"
suite="$work/suite"
mkdir -p "$suite"
cp "$root/tests/JSON.Test" "$root/tests/CSV.Test" "$suite/"
( cd "$suite"
  rc=0; "$ob"     test > "$work/test-native.txt" 2>&1 || rc=$?; echo "exit $rc" >> "$work/test-native.txt"
  rc=0; "$shellob" test > "$work/test-shell.txt"  2>&1 || rc=$?; echo "exit $rc" >> "$work/test-shell.txt" )
if diff -u "$work/test-shell.txt" "$work/test-native.txt" > "$work/test.diff"; then
	echo "ok    test reports every case exactly as the shell version does"
else
	echo "FAIL  test differs from the shell version"; sed 's/^/        /' "$work/test.diff" | head -40; fail=1
fi

# A case listed in the baseline must be reported as known and must not break the run; one that
# passes anyway must be reported as FIXED and must break it, or the file quietly goes stale.
printf 'JSON.Test\tpositive: booleans carry their value\n' > "$suite/a2test-expected.txt"
( cd "$suite"; rc=0; "$ob" test JSON.Test > "$work/test-baseline.txt" 2>&1 || rc=$?; echo "exit $rc" >> "$work/test-baseline.txt" )
case "$(cat "$work/test-baseline.txt")" in
	*"FIXED positive: booleans carry their value"*"exit 1"*) echo "ok    a baseline entry that passes is FIXED and fails the run" ;;
	*) echo "FAIL  baseline handling"; sed 's/^/        /' "$work/test-baseline.txt" | tail -8; fail=1 ;;
esac
rm -f "$suite/a2test-expected.txt"

# -j: the same run, in pieces, at the same time. The point of the check is that the transcript is
# the same one -- the verdicts, in the same order, under a header line saying how it was divided.
# Files.Test is in here on purpose: its cases build helper modules and import them from later ones,
# which is what a chunk has to bring with it when it starts in a directory of its own.
cp "$root/tests/Files.Test" "$suite/"
( cd "$suite"
  rc=0; "$ob" test -j 1 > "$work/test-j1.txt" 2>&1 || rc=$?; echo "exit $rc" >> "$work/test-j1.txt"
  rc=0; "$ob" test -j 4 > "$work/test-j4.txt" 2>&1 || rc=$?; echo "exit $rc" >> "$work/test-j4.txt" )
if ! grep -q '^ob test: 4 at a time, in [0-9]* piece' "$work/test-j4.txt"; then
	echo "FAIL  test -j 4 did not divide the run"; sed 's/^/        /' "$work/test-j4.txt" | head -5; fail=1
elif diff -u "$work/test-j1.txt" <(grep -v '^ob test: 4 at a time' "$work/test-j4.txt") > "$work/j.diff"; then
	echo "ok    test -j 4 reads exactly like test -j 1"
else
	echo "FAIL  test -j 4 differs from a sequential run"; sed 's/^/        /' "$work/j.diff" | head -40; fail=1
fi
rm -f "$suite/Files.Test"

# A report is what CI reads; it has to be JSON and it has to have every case in it.
( cd "$suite"; "$ob" test JSON.Test --report report.json >/dev/null 2>&1 || true )
if [ -f "$suite/report.json" ] && grep -q '"cases"' "$suite/report.json" \
		&& grep -q '"status": "ok"' "$suite/report.json"; then
	echo "ok    test wrote a JSON report with its cases in it"
else
	echo "FAIL  test wrote no usable report"; fail=1
fi

# The same suites compiled for another architecture and executed in an emulator -- the last thing
# the shell version could do that this one could not. Both files here execute rather than only
# compile, so a run that quietly compiled and reported success would show up as a transcript of
# its own: the banner naming the emulator is checked separately for exactly that reason.
echo "=== test for another architecture, against the shell version case by case"
emulator="${A2_QEMU:-$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)}"
sysroot="${A2_A64_SYSROOT:-}"
if [ -z "$sysroot" ]; then
	for candidate in "$root/target/A64/sysroot" /usr/aarch64-linux-gnu /usr/local/aarch64-linux-gnu; do
		[ -f "$candidate/lib/ld-linux-aarch64.so.1" ] && sysroot="$candidate" && break
	done
fi
if [ ! -d "$sdk/lib-a64" ]; then
	echo "skip  test -t a64: this SDK ships no lib-a64"
elif [ -z "$emulator" ] || [ ! -f "$sysroot/lib/ld-linux-aarch64.so.1" ]; then
	echo "skip  test -t a64: no qemu-aarch64 or no AArch64 C library"
else
	( cd "$suite" && export A2_QEMU="$emulator" A2_A64_SYSROOT="$sysroot"
	  rc=0; "$ob"     test -t a64 > "$work/a64-native.txt" 2>&1 || rc=$?; echo "exit $rc" >> "$work/a64-native.txt"
	  rc=0; "$shellob" test -t a64 > "$work/a64-shell.txt"  2>&1 || rc=$?; echo "exit $rc" >> "$work/a64-shell.txt" )
	if ! diff -u "$work/a64-shell.txt" "$work/a64-native.txt" > "$work/a64.diff"; then
		echo "FAIL  test -t a64 differs from the shell version"
		sed 's/^/        /' "$work/a64.diff" | head -40; fail=1
	elif ! grep -q 'cases run under' "$work/a64-native.txt"; then
		echo "FAIL  test -t a64 executed nothing -- no image or no emulator"; fail=1
	else
		echo "ok    test -t a64 reports every case as the shell version does, and executed them"
	fi
fi

echo "=== doc, against the shell version page by page"
docs="$work/docs"
mkdir -p "$docs"
cp "$root/source/JSON.Mod" "$root/source/Strings.Mod" "$docs/"
cp "$root/sdk/Unix.ObHost.Mod" "$docs/ObHost.Mod"
( cd "$docs"
  rc=0; "$ob"     doc -o pages       >/dev/null 2>&1 || rc=$?
  rc=0; "$shellob" doc -o pages-shell  >/dev/null 2>&1 || rc=$? )
docfail=0
for page in "$docs"/pages/*.html; do
	name="$(basename "$page")"
	[ "$name" = index.html ] && continue
	if [ ! -f "$docs/pages-shell/$name" ]; then echo "FAIL  doc wrote $name, the shell version did not"; docfail=1; continue; fi
	# The anchor ids are derived from addresses and differ between any two runs of either version.
	if diff -q <(sed -E 's/#_[0-9A-F]+/#_X/g; s/\r$//' "$page") \
	           <(sed -E 's/#_[0-9A-F]+/#_X/g; s/\r$//' "$docs/pages-shell/$name") >/dev/null; then :
	else echo "FAIL  doc page $name differs from the shell version's"; docfail=1; fi
done
[ -f "$docs/pages/index.html" ] || { echo "FAIL  doc wrote no index.html"; docfail=1; }
pages_written="$(ls "$docs"/pages/*.html 2>/dev/null | grep -vc '/index.html$' || true)"
[ "$pages_written" = 3 ] || { echo "FAIL  doc wrote $pages_written pages, expected 3"; docfail=1; }
[ "$docfail" = 0 ] && echo "ok    doc wrote the same pages as the shell version" || fail=1

# The one thing ob still starts a process for, and the reason it does: work that has to be given
# up on. Checked here through ob's own host layer, run by ob.
echo "=== a child process, and a deadline it does not meet"
spawn="$work/spawn"
mkdir -p "$spawn"
cp "$root/sdk/Unix.ObHost.Mod" "$spawn/ObHost.Mod"
cat > "$spawn/SpawnProbe.Mod" <<'EOF'
MODULE SpawnProbe;
IMPORT Commands, Strings, Objects, ObHost;

PROCEDURE Try(context: Commands.Context; CONST what: ARRAY OF CHAR; seconds, limit: SIGNED32);
VAR arguments: Strings.StringArray; process: ADDRESS; exitCode, waited: SIGNED32; text: ARRAY 32 OF CHAR;
BEGIN
	NEW(arguments, 2);
	arguments[0] := Strings.NewString("sleep");
	text := ""; Strings.AppendInt(text, seconds);
	arguments[1] := Strings.NewString(text);
	process := ObHost.Spawn("/bin/sleep", arguments);
	context.out.String(what); context.out.String(": ");
	waited := 0; exitCode := -1;
	WHILE (waited < limit) & ~ObHost.Finished(process, exitCode) DO Objects.Sleep(20); INC(waited, 20) END;
	IF waited < limit THEN context.out.String("finished, exit "); context.out.Int(exitCode, 0)
	ELSE ObHost.Terminate(process); context.out.String("gave up and killed it") END;
	context.out.Ln; context.out.Update
END Try;

PROCEDURE Do*(context: Commands.Context);
BEGIN
	Try(context, "short child", 0, 5000);
	Try(context, "long child", 30, 500)
END Do;

END SpawnProbe.
EOF
spawn_output="$( cd "$spawn" && timeout 120 "$ob" run SpawnProbe.Mod 2>&1 || true )"
case "$spawn_output" in
	*"short child: finished, exit 0"*) echo "ok    a child that finishes is reaped with its exit code" ;;
	*) echo "FAIL  short child: $spawn_output"; fail=1 ;;
esac
case "$spawn_output" in
	*"long child: gave up and killed it"*) echo "ok    a child that overruns is killed" ;;
	*) echo "FAIL  long child: $spawn_output"; fail=1 ;;
esac

echo "=== get, against the shell version tree for tree"
# Only when a registry is at hand: this check fetches nothing over the network on purpose, and a
# registry checkout is not part of the SDK.
registry="${A2_REGISTRY:-$root/../a2-registry}"
if [ -f "$registry/index.json" ]; then
	for who in native shell; do
		rm -rf "$work/get-$who"; mkdir -p "$work/get-$who"
	done
	( cd "$work/get-native" && A2_REGISTRY="$registry" "$ob"     get community/matrix >/dev/null 2>&1 || true )
	( cd "$work/get-shell"  && A2_REGISTRY="$registry" "$shellob" get community/matrix >/dev/null 2>&1 || true )
	if diff -r "$work/get-shell" "$work/get-native" > "$work/get.diff" 2>&1; then
		echo "ok    get vendored the same tree, manifest and lock as the shell version"
	else
		echo "FAIL  get differs from the shell version"; sed 's/^/        /' "$work/get.diff" | head -20; fail=1
	fi
else
	echo "skip  get: no registry at $registry (set A2_REGISTRY)"
fi

echo "=== the language server, over this process's own stdio"
frame() { printf 'Content-Length: %d\r\n\r\n%s' "${#1}" "$1"; }
lsp_input() {
	frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":null,"capabilities":{}}}'
	frame "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://$project/Bad.Mod\",\"languageId\":\"oberon\",\"version\":1,\"text\":\"MODULE Bad;\\nBEGIN nonsense\\nEND Bad.\\n\"}}}"
	frame '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
}
# No `exit` notification on purpose: the input simply ends, which is what an editor that dies
# leaves behind. The server has to notice and go -- it used to read the closed pipe forever at a
# full core, and this check only passed because the timeout killed it, a minute at a time.
lsp_status=0
lsp_output="$(lsp_input | timeout 60 "$ob" lsp 2>&1)" || lsp_status=$?
case "$lsp_status" in
	0) echo "ok    lsp left when its client closed the pipe" ;;
	124) echo "FAIL  lsp kept running after its client closed the pipe"; fail=1 ;;
	*) echo "FAIL  lsp exited with status $lsp_status"; fail=1 ;;
esac
case "$lsp_output" in
	*'"hoverProvider":true'*) echo "ok    lsp answered initialize" ;;
	*) echo "FAIL  lsp did not answer initialize"; echo "$lsp_output" | head -c 400 | sed 's/^/        /'; fail=1 ;;
esac
case "$lsp_output" in
	*publishDiagnostics*'"severity":1'*) echo "ok    lsp reported the error in the file" ;;
	*) echo "FAIL  lsp reported no diagnostics"; fail=1 ;;
esac

echo "=== the interactive shell"
repl_output="$(printf 'System.Show hello from the repl~\nexit\n' | timeout 60 "$ob" repl 2>&1 || true)"
case "$repl_output" in
	*"hello from the repl"*) echo "ok    repl ran a command and left" ;;
	*) echo "FAIL  repl printed: $repl_output"; fail=1 ;;
esac

echo "=== ob.exe: the same driver, native on Windows"
# The point of writing ob in Active Oberon rather than in bash: a Windows SDK that needs no shell.
# Checked here under wine, which runs A2's Win64 binaries as they are. Skipped, not faked, when
# wine or the Win64 objects are absent.
winbin="$(dirname "$build")/Win64/bin"
if ! command -v wine >/dev/null 2>&1; then
	echo "skip  ob.exe: no wine"
elif [ ! -d "$sdk/lib-win64" ] || [ ! -f "$winbin/WinTrace.SymWw" ]; then
	echo "skip  ob.exe: no Win64 objects (run 'task Win64' and 'task bundle' first)"
else
	win="$work/win"; winsdk="$work/winsdk/lib"
	mkdir -p "$win" "$winsdk"
	# Only our two modules are compiled here. Kernel32 (with the bindings ObHost needs), JSON,
	# LSP and WinTrace come out of lib-win64 like any other library module -- they are in the
	# Win64 release definition and in configs/headless-core-win64.txt, so a Win64 build and the
	# bundle made from it carry them. That was not true while the Win64 build in the tree was
	# months old, and the difference read as "the release list is missing them".
	cp "$root/sdk/Windows.ObHost.Mod"  "$win/ObHost.Mod"
	cp "$root/sdk/Ob.Mod" "$win/"
	winboot="$(grep -vE '^(StdIOShell|Shell)$' "$root/configs/moduleListWin.txt" | tr '\n' ' ')"
	( cd "$win" && "$oberon" do "
		Files.AddSearchPath $win~
		Files.AddSearchPath $build/bin~
		Files.AddSearchPath $sdk/lib-win64~
		Compiler.Compile -p=Win64 --objectFileExtension=GofWw --symbolFileExtension=.SymWw ./ObHost.Mod ./Ob.Mod ~
		Linker.Link --fileFormat=PE64CUI --extension=GofWw --displacement=401000H --fileName='ob.exe'
		$winboot Ob
		~
	" ) > "$work/win-build.log" 2>&1 || true
	if [ ! -f "$win/ob.exe" ]; then
		echo "FAIL  ob.exe did not build"; sed 's/^/        /' "$work/win-build.log" | head -12; fail=1
	else
		cp "$sdk/lib-win64"/*.SymWw "$sdk/lib-win64"/*.GofWw "$winsdk/" 2>/dev/null || true
		cp "$win"/*.SymWw "$win"/*.GofWw "$winsdk/" 2>/dev/null || true
		cp "$win/ob.exe" "$work/winsdk/"
		cp "$root/configs/moduleListWin.txt" "$work/winsdk/boot-modules-win64.txt"
		cp "$sdk/VERSION" "$work/winsdk/" 2>/dev/null || true
		cat > "$work/winsdk/Hello.Mod" <<'EOF'
MODULE Hello;
IMPORT Commands;
PROCEDURE Do*(context: Commands.Context);
BEGIN context.out.String("hello from ob.exe"); context.out.Ln; context.out.Update
END Do;
END Hello.
EOF
		# A2SDK is exported above and points at the Linux bundle; ob.exe has to find its own SDK
		# beside itself, which is the property being checked.
		runwine() { ( cd "$work/winsdk" && WINEDEBUG=-all env -u A2SDK timeout 900 wine "$@" 2>&1 | grep -v "Authorization required" ); }
		case "$(runwine ob.exe version)" in
			*"runtime : this binary (win64)"*) echo "ok    ob.exe found its SDK beside itself and knows what it is" ;;
			*) echo "FAIL  ob.exe version: $(runwine ob.exe version | tr '\n' ' ')"; fail=1 ;;
		esac
		wincompile="$(runwine ob.exe compile Hello.Mod || true)"
		[ -f "$work/winsdk/Hello.GofWw" ] && echo "ok    ob.exe compiled a module" \
			|| { echo "FAIL  ob.exe compiled nothing: $(printf '%s' "$wincompile" | tr '\n' ' ')"; fail=1; }
		runwine ob.exe build Hello.Mod >/dev/null 2>&1 || true
		if [ -f "$work/winsdk/Hello.exe" ]; then
			case "$(runwine Hello.exe)" in
				*"hello from ob.exe"*) echo "ok    ob.exe built a Windows binary and it runs" ;;
				*) echo "FAIL  the binary ob.exe built did not run"; fail=1 ;;
			esac
		else
			echo "FAIL  ob.exe built no binary"; fail=1
		fi
	fi
fi

echo "=== the Windows SDK as it ships"
# Not the same check as the one above: that one builds ob.exe from the tree, this one unpacks the
# tarball a user would download and drives it where it lands. The two have disagreed before -- a
# stale Win64 build left the shipped compiler not knowing the AArch64 platform at all.
if ! command -v wine >/dev/null 2>&1; then
	echo "skip  windows bundle: no wine"
elif [ ! -d "$(dirname "$build")/Win64/bin" ]; then
	echo "skip  windows bundle: no Win64 build (run 'task Win64' first)"
else
	winout="$work/win-sdk"
	if "$root/tests/win-bundle.sh" "$build" -o "$winout" --no-tar > "$work/win-bundle.log" 2>&1; then
		runsdk() { ( cd "$winout" && WINEDEBUG=-all env -u A2SDK timeout 900 wine "$@" 2>&1 | grep -v "Authorization required" ); }
		case "$(runsdk ob.exe version)" in
			*"targets : win64"*) echo "ok    the Windows bundle knows what it is and what it targets" ;;
			*) echo "FAIL  windows bundle version: $(runsdk ob.exe version | tr '\n' ' ')"; fail=1 ;;
		esac
		case "$(runsdk ob.exe run examples/Hello.Mod)" in
			*"Hello from A2"*) echo "ok    the Windows bundle compiles and runs a module" ;;
			*) echo "FAIL  windows bundle run: $(runsdk ob.exe run examples/Hello.Mod | tr '\n' ' ')"; fail=1 ;;
		esac
		# The output is kept: this used to be `>/dev/null 2>&1 || true`, and then a wine that was
		# merely slow to start -- which is what the first wine of a session after a rebuild is --
		# read exactly like a compiler that cannot cross-build, with nothing on screen to say which.
		a64out="$(runsdk ob.exe build examples/Hello.Mod -t a64 -o hello-arm64 2>&1 || true)"
		if [ -f "$winout/hello-arm64" ] && head -c 20 "$winout/hello-arm64" | grep -q "$(printf '\177ELF')"; then
			echo "ok    the Windows bundle cross-builds for AArch64"
		else
			echo "FAIL  the Windows bundle did not cross-build for AArch64"
			printf '%s\n' "$a64out" | tail -8 | sed 's/^/        /'; fail=1
		fi
		case "$(runsdk ob.exe build examples/Hello.Mod -t linux64 -o x)" in
			*"ships no objects for target linux64"*) echo "ok    it refuses a target it has no objects for" ;;
			*) echo "FAIL  linux64 from Windows was not refused"; fail=1 ;;
		esac
		# The Windows reader of standard input had the same fault as the Unix one, so the
		# language server has to be seen leaving here too, and not under a timeout.
		win_lsp=0
		lsp_input | ( cd "$winout" && WINEDEBUG=-all env -u A2SDK timeout 120 wine ob.exe lsp ) \
			> "$work/win-lsp.log" 2>&1 || win_lsp=$?
		case "$win_lsp" in
			0) if grep -q '"hoverProvider":true' "$work/win-lsp.log"; then
					echo "ok    ob.exe lsp answered, then left when the pipe closed"
				else
					echo "FAIL  ob.exe lsp left without answering"; tail -c 300 "$work/win-lsp.log" | sed 's/^/        /'; fail=1
				fi ;;
			124) echo "FAIL  ob.exe lsp kept running after its client closed the pipe"; fail=1 ;;
			*) echo "FAIL  ob.exe lsp exited with status $win_lsp"; fail=1 ;;
		esac
	else
		echo "FAIL  the Windows bundle did not build"; sed 's/^/        /' "$work/win-bundle.log" | tail -8; fail=1
	fi
fi

echo
if [ "$fail" = 0 ]; then echo "ob-check: OK"; else echo "ob-check: FAILED"; fi
exit "$fail"
