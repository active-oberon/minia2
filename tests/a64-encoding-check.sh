#!/usr/bin/env bash
#
# Differential test of FoxA64InstructionSet against llvm-mc.
#
# FoxA64InstructionSet.Test writes one line per instruction: the encoding it produced, a tab, and
# the instruction in Arm assembly syntax. This script feeds that second column to llvm-mc, which is
# an assembler that is known to be right, and compares the word it produces with the word the
# compiler produced. Both the encoder and the printer are under test: they would have to be wrong
# in the same way, and in a way that agrees with the architecture manual, to pass.
#
# Usage: tests/a64-encoding-check.sh [path to the built runtime directory]
#        default is target/$(uname -m mapped to a platform)/, i.e. target/Linux64

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"

llvm_mc="$(command -v llvm-mc || command -v llvm-mc-18 || true)"
if [ -z "$llvm_mc" ]; then
	echo "llvm-mc not found; install llvm (Debian: apt install llvm-18)" >&2
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

# The runtime prints two lines of its own before the test output, and reads its working directory
# from $PWD rather than from getcwd().
(cd "$build" && PWD="$build" "$oberon" do "
	System.DoFile oberon.cfg ~
	FoxA64InstructionSet.Test ~
") | tr -d '\r' | grep -P '^[0-9a-f-]{8}\t' > "$work/ours.txt"

if [ ! -s "$work/ours.txt" ]; then
	echo "the self test produced no instructions" >&2
	exit 1
fi

# field 1 is the encoding; everything after it is the instruction, which itself contains the tab
# that separates the mnemonic from its operands
cut -f1 "$work/ours.txt" > "$work/words.txt"
cut -f2- "$work/ours.txt" > "$work/asm.s"

# llvm-mc exits non-zero when it rejects a line, so its failure is inspected rather than inherited.
if ! "$llvm_mc" --triple=aarch64 --show-encoding "$work/asm.s" \
		>"$work/mc.txt" 2>"$work/mc-errors.txt"; then
	echo "llvm-mc rejected instructions the printer produced:" >&2
	grep -A1 'error:' "$work/mc-errors.txt" >&2
	exit 1
fi

# llvm-mc prints one "// encoding: [b0,b1,b2,b3]" per instruction, little endian.
grep -oP 'encoding: \[\K[^]]+' "$work/mc.txt" \
	| awk -F', *' '{ printf "%s%s%s%s\n", substr($4,3), substr($3,3), substr($2,3), substr($1,3) }' \
	> "$work/theirs.txt"

ours=$(wc -l < "$work/words.txt")
theirs=$(wc -l < "$work/theirs.txt")
if [ "$ours" -ne "$theirs" ]; then
	echo "llvm-mc returned $theirs encodings for $ours instructions" >&2
	exit 1
fi

paste "$work/words.txt" "$work/theirs.txt" "$work/asm.s" \
	| awk -F'\t' '
		$1 != $2 { printf "%-44s ours %s  llvm-mc %s\n", $3 " " $4, $1, $2; bad++ }
		END { if (bad) { printf "\n%d of %d mismatched\n", bad, NR; exit 1 } }'

echo "$ours instructions, every encoding agrees with llvm-mc"

# Second half: read the same text back through FoxA64Assembler and check that the parser reaches
# the same instructions the encoder was asked for. The parser has no other caller until there is a
# code generator, so this is what exercises it.
(cd "$build" && PWD="$build" "$oberon" do "
	System.DoFile oberon.cfg ~
	FoxA64Assembler.Test
$(cat "$work/asm.s")
~
") 2>&1 | tr -d '\r' | grep -P '^[0-9a-f]{8}$' > "$work/parsed.txt" || true

parsed=$(wc -l < "$work/parsed.txt")
if [ "$parsed" -ne "$ours" ]; then
	echo "the assembler produced $parsed words for $ours instructions; it rejected something" >&2
	(cd "$build" && PWD="$build" "$oberon" do "
		System.DoFile oberon.cfg ~
		FoxA64Assembler.Test
$(cat "$work/asm.s")
~
	") 2>&1 | grep -i 'error' >&2 || true
	exit 1
fi

paste "$work/words.txt" "$work/parsed.txt" "$work/asm.s" \
	| awk -F'\t' '
		$1 != $2 { printf "%-44s encoded %s  parsed %s\n", $3 " " $4, $1, $2; bad++ }
		END { if (bad) { printf "\n%d of %d mismatched\n", bad, NR; exit 1 } }'

echo "$ours instructions, the assembler reads back every one of them"
