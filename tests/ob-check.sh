#!/usr/bin/env bash
#
# `ob` written in Active Oberon: built, and made to answer for itself.
#
# The shell `ob` (docker/ob) drives a separate `oberon` process for every compile. This one IS the
# compiler: source/Ob.Mod is linked last into a binary that already holds Fox, so a verb calls
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
cp "$root/source/Unix.ObHost.Mod" "$work/ObHost.Mod"
cp "$root/source/Ob.Mod"          "$work/Ob.Mod"

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

echo "=== the banner says what the shell version says"
"$sdk/ob" version | grep -v '^  runtime' > "$work/banner-shell.txt"
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

# Nothing is precompiled: the sibling has to be built on the way, or the import does not resolve.
rm -rf /tmp/ob-[0-9]* 2>/dev/null || true
check "run, sibling compiled on the way" 0 "$ob" run Hello.Mod
case "$LAST_OUTPUT" in
	*"hello from a sibling!"*) echo "ok    run printed what the module prints" ;;
	*) echo "FAIL  run printed: $LAST_OUTPUT"; fail=1 ;;
esac

# A verb that leaves objects in the user's directory is a verb that has broken the project.
leftovers="$(ls "$project" | grep -vE '\.Mod$' || true)"
if [ -z "$leftovers" ]; then echo "ok    run left the project alone"
else echo "FAIL  run left in the project: $leftovers"; fail=1; fi

if [ -z "$(ls -d /tmp/ob-[0-9]* 2>/dev/null || true)" ]; then echo "ok    run removed its scratch directory"
else echo "FAIL  run left a scratch directory behind: $(ls -d /tmp/ob-[0-9]*)"; fail=1; fi

check "compile" 0 "$ob" compile Hello.Mod -o out
[ -f "$project/out/Hello.GofUu" ] && echo "ok    compile wrote the object file" \
	|| { echo "FAIL  compile wrote no out/Hello.GofUu"; fail=1; }

check "compile reports an error and fails" 1 "$ob" compile Bad.Mod
case "$LAST_OUTPUT" in
	*"Undeclared Identifier"*) echo "ok    compile said what was wrong" ;;
	*) echo "FAIL  compile said: $LAST_OUTPUT"; fail=1 ;;
esac

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
			&& "$sdk/ob" build Hello.Mod -t "$target" -o "shell/$name" >/dev/null 2>&1; then
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
  rc=0; "$sdk/ob" lint > "$work/lint-shell.txt"  2>&1 || rc=$?; echo "exit $rc" >> "$work/lint-shell.txt" )
if diff -u "$work/lint-shell.txt" "$work/lint-native.txt" > "$work/lint.diff"; then
	echo "ok    lint says what the shell version says, and fails the same way"
else
	echo "FAIL  lint differs from the shell version"; sed 's/^/        /' "$work/lint.diff"; fail=1
fi
check "lint passes on a project with no upward edge" 0 "$ob" lint

echo "=== the language server, over this process's own stdio"
frame() { printf 'Content-Length: %d\r\n\r\n%s' "${#1}" "$1"; }
lsp_input() {
	frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"rootUri":null,"capabilities":{}}}'
	frame "{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":\"file://$project/Bad.Mod\",\"languageId\":\"oberon\",\"version\":1,\"text\":\"MODULE Bad;\\nBEGIN nonsense\\nEND Bad.\\n\"}}}"
	frame '{"jsonrpc":"2.0","id":2,"method":"shutdown","params":null}'
}
lsp_output="$(lsp_input | timeout 60 "$ob" lsp 2>&1 || true)"
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

echo
if [ "$fail" = 0 ]; then echo "ob-check: OK"; else echo "ob-check: FAILED"; fi
exit "$fail"
