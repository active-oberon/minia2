#!/usr/bin/env bash
#
# Compile tests/A64Codegen.Mod for UnixA64 and read the machine code back.
#
# There is no way to run A64 code here yet, so the check is that the generator reaches the end of
# every procedure and that llvm-mc can decode every word it produced. A word the code generator
# could not encode stops the compile; a word it encoded wrongly usually fails to decode, and the
# rest is read by a person looking at the listing this prints with --verbose.
#
# Usage: tests/a64-codegen-check.sh [build directory] [--verbose]

set -eo pipefail

# Directories given on the command line are made absolute: every one of them is used after a `cd`
# into the build directory, and a relative one would be read from there rather than from where it
# was given. The output directory need not exist yet, so this does not go through `cd`.
absolute() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*) printf '%s\n' "$PWD/$1" ;;
	esac
}

# llvm-mc is versioned on Debian and Ubuntu -- llvm-mc-18, llvm-mc-19 -- and which of them is
# installed depends on the machine. The plain name is tried first and the newest versioned one
# after it, so a runner whose image moved to another release still finds it.
LlvmTool() {
	local found newest
	found="$(command -v "$1" || true)"
	if [ -z "$found" ]; then
		newest="$(compgen -c "$1-" 2>/dev/null | sort -uV | tail -1 || true)"
		[ -n "$newest" ] && found="$(command -v "$newest" || true)"
	fi
	printf '%s\n' "$found"
}

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
build="$(absolute "$build")"
verbose="${2:-}"

llvm_mc="$(LlvmTool llvm-mc)"
if [ -z "$llvm_mc" ]; then
	echo "llvm-mc not found; install llvm (Debian: apt install llvm)" >&2
	exit 2
fi

oberon="$build/oberon"
[ -x "$oberon" ] || oberon="$build/oberon.exe"
if [ ! -x "$oberon" ]; then
	echo "no built runtime in $build; run 'task Linux64' or 'task oberon' first" >&2
	exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$root/tests/A64Codegen.Mod" "$work/"

# The runtime reads its working directory from $PWD rather than from getcwd(), and resolves the
# module by name off the search path rather than by the path given on the command line.
output=$( (cd "$build" && PWD="$build" "$oberon" do "
	System.DoFile oberon.cfg ~
	Files.AddSearchPath $work ~
	Compiler.Compile -p=UnixA64 --destPath='$work/' --trace=* A64Codegen.Mod ~
") 2>&1 | tr -d '\r' ) || true

if ! printf '%s\n' "$output" | grep -q 'A64Codegen done\.'; then
	echo "the A64 code generator did not get through A64Codegen.Mod:" >&2
	printf '%s\n' "$output" | grep -E 'error|Error' >&2 || printf '%s\n' "$output" | tail -20 >&2
	exit 1
fi

# Everything after the binary code banner is the emitted machine code, printed as hexadecimal
# bytes; the code sections are the ones worth decoding.
printf '%s\n' "$output" | sed -n '/binary code/,$p' \
	| grep -oP '^\t\[.*' | sed 's/^\t\[[ 0-9A-F]*\] //' \
	| tr -s ' ' '\n' | grep -E '^[0-9A-F]{2}$' | sed 's/^/0x/' | paste -sd' ' - > "$work/code.hex"

words=$(( $(wc -w < "$work/code.hex") / 4 ))
if [ "$words" -eq 0 ]; then
	echo "no machine code was emitted" >&2
	exit 1
fi

if ! "$llvm_mc" --triple=aarch64 --disassemble "$work/code.hex" > "$work/disassembly.txt" 2>"$work/errors.txt"; then
	echo "llvm-mc could not decode the emitted code:" >&2
	head -20 "$work/errors.txt" >&2
	exit 1
fi

# A word llvm-mc cannot place reads as <unknown>; the data words of an inline literal read as udf,
# which is expected, because they are data and the branch in front of them says so.
if grep -q 'unknown' "$work/disassembly.txt"; then
	echo "the emitted code contains words llvm-mc does not recognise:" >&2
	grep -n 'unknown' "$work/disassembly.txt" | head >&2
	exit 1
fi

if [ "$verbose" = "--verbose" ]; then
	grep -v '\.text' "$work/disassembly.txt" | cat -n
fi

echo "A64Codegen.Mod compiled for UnixA64: $words instructions, all of them decodable"
