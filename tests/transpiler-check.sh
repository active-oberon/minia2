#!/usr/bin/env bash
#
# Transpile tests/TranspilerCases.Mod to C and read the C back.
#
# Two halves. First one grep per construct the backend used to refuse or to write wrongly, so a
# regression shows up as a missing shape here rather than as a trap somewhere in the middle of the
# standard library. Then the C is handed to clang, linked against transpiler/oberon.c and run, with
# tests/transpiler-driver.c calling what the module exports and checking the answers.
#
# That second half needs no garbage collector because the fixture allocates a handful of objects and
# exits. A program that stays up does, and that is the rest of the work.
#
# It also transpiles three real modules -- Streams, Strings, JSON -- because a fixture only proves
# the shapes somebody thought of, and those three were the ones that fell over first.
#
# Usage: tests/transpiler-check.sh [build directory]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
case "$build" in /*) ;; *) build="$PWD/$build" ;; esac

oberon="$build/oberon"
[ -x "$oberon" ] || oberon="$build/oberon.exe"
if [ ! -x "$oberon" ]; then
	echo "no built runtime in $build; run 'task Linux64' first" >&2
	exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The backend writes X.c and X.h beside the source it was given, so the sources are copied out of
# the tree first -- otherwise the check litters source/ with generated C.
cp "$root/tests/TranspilerCases.Mod" "$work/"
for module in Streams Strings JSON; do cp "$root/source/$module.Mod" "$work/"; done

transpile() { # module file -> its C, or a failure with the trap that caused it
	local file="$1" name="${1%.Mod}"
	(cd "$build" && PWD="$build" "$oberon" do "
		System.DoFile oberon.cfg ~
		Compiler.Compile -b=Transpiler '$work/$file' ~
	") 2>&1 | tr -d '\r' > "$work/$name.log" || true
}

failed=0
fail() { echo "[FAIL] $1"; failed=1; }

for module in TranspilerCases Streams Strings JSON; do
	transpile "$module.Mod"
	if [ ! -f "$work/$module.c" ]; then
		fail "$module did not transpile"
		grep -E '^Trap|error:' "$work/$module.log" | head -3 >&2 || true
	fi
done

c="$work/TranspilerCases.c"
h="$work/TranspilerCases.h"
if [ -f "$c" ]; then
	# The shape on the left is what the C must contain; the words on the right name the defect.
	check() { grep -qF "$2" "$1" || fail "$3"; }

	check "$h" "Set8 a, Set16 b"                  "a set narrower than the address is not printed"
	check "$h" "Set64 d"                          "a set wider than the address is not printed"
	check "$h" "Unsigned8 a, Unsigned16 b, Unsigned32 c, Unsigned64 d" \
	                                              "an unsigned integer is printed as a signed C type"
	check "$c" "(*c) = '\\\\';"                   "a backslash character literal is not escaped"
	check "$c" "(*c) = '\012';"                  "an unprintable character is not an octal escape"
	check "$c" "\"a\\\\b\\\"c\""             "a string is not escaped"
	check "$c" "local = 41;"                      "VAR among the statements writes no initializer"
	check "$c" "_result = (TranspilerCases_Box)"  "RESULT has no variable behind it"
	check "$c" "return _result;"                  "RESULT is not returned"
	check "$c" "sizeof (size_t) * 8"              "SIZE OF is not a sizeof"
	check "$c" "sizeof (Unsigned32) * 8 - 1"      "a rotate does not mask its count"
	check "$c" "(a > b ? a : b)"                  "MAX of two arguments is not a ternary"
	check "$c" "(a < b ? a : b)"                  "MIN of two arguments is not a ternary"
	check "$c" "((LongInt) x)"                    "x(SIGNED32) is not a cast"
fi

# And then the part that a grep cannot do: give the generated C to a C compiler, link it against
# transpiler/oberon.h + oberon.c, run it, and see the answers come back. Without this the check
# proves the backend wrote something, not that what it wrote means anything.
if [ -f "$c" ] && command -v clang >/dev/null; then
	if clang -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Werror \
		-I "$root/transpiler" -I "$work" \
		-o "$work/cases" "$root/tests/transpiler-driver.c" "$c" "$root/transpiler/oberon.c" \
		-pthread -lm 2> "$work/cc.log"; then
		if output="$("$work/cases" 2>&1)"; then
			# what TRACE printed: the module name, the source position, the expression and its value
			case "$output" in
				*"TranspilerCases@"*"answer = 42"*) ;;
				*) fail "the running binary printed '$output', not the traced answer" ;;
			esac
		else
			fail "the transpiled C compiled but did not run"
			printf '%s\n' "$output" >&2
		fi
	else
		fail "the transpiled C does not compile against transpiler/oberon.h"
		head -20 "$work/cc.log" >&2
	fi
	ran="compiled, linked and ran"
else
	ran="not compiled -- no clang here"
fi

if [ "$failed" -ne 0 ]; then
	echo "the C transpiler backend lost ground -- see source/FoxTranspilerBackend.Mod" >&2
	exit 1
fi

echo "the C backend wrote all fourteen shapes; Streams, Strings and JSON went through it; the C $ran"
