#!/usr/bin/env bash
#
# Compile tests/AMD64Codegen.Mod for Unix64 and read the machine code back.
#
# The AMD64 twin of a64-codegen-check.sh, and it differs from it in two ways worth knowing.
#
# It decodes section by section rather than as one stream. On AArch64 every word is four bytes, so a
# flat stream of everything the compiler printed still lines up; x86-64 instructions are of varying
# length, so a data section fed to the disassembler desynchronises everything after it. Only
# .code/.bodycode/.initcode sections are decoded here, and each on its own.
#
# And it proves less than the A64 check does, which is worth saying rather than glossing. On AArch64
# a wrong encoding usually fails to decode at all. On x86-64 nearly any byte sequence decodes as
# *something*, so "it decoded" is not "it is right": what this catches is bytes llvm-mc rejects
# outright, and the listing --verbose prints is for reading the rest by eye. The immediate defect
# this module was written around -- a 64-bit constant above MAX(SIGNED32) written as a sign-extended
# 32-bit one -- shows up in that listing as the wrong operand, not as a refusal.
#
# Usage: tests/amd64-codegen-check.sh [build directory] [--verbose]

set -eo pipefail

# Directories given on the command line are made absolute: every one of them is used after a `cd`
# into the build directory, and a relative one would be read from there rather than from where it
# was given.
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
cp "$root/tests/AMD64Codegen.Mod" "$work/"

# The runtime reads its working directory from $PWD rather than from getcwd(), and resolves the
# module by name off the search path rather than by the path given on the command line.
(cd "$build" && PWD="$build" "$oberon" do "
	System.DoFile oberon.cfg ~
	Files.AddSearchPath $work ~
	Compiler.Compile -p=Unix64 --destPath='$work/' --trace=* AMD64Codegen.Mod ~
") 2>&1 | tr -d '\r' > "$work/trace.txt" || true

if ! grep -q 'AMD64Codegen done\.' "$work/trace.txt"; then
	echo "the AMD64 code generator did not get through AMD64Codegen.Mod:" >&2
	grep -E 'error|Error' "$work/trace.txt" >&2 || tail -20 "$work/trace.txt" >&2
	exit 1
fi

# Split the listing into one file per code section. A section starts at a line beginning with a dot
# and its bytes are the "[ nn] xx xx ..." lines under it; fixup lines in between are the linker's
# business and carry no bytes.
python3 - "$work/trace.txt" "$work/sections" 2>/dev/null <<'PY'
import os, re, sys

trace, outdir = sys.argv[1], sys.argv[2]
os.makedirs(outdir, exist_ok=True)

lines = open(trace, encoding="latin-1").read().splitlines()
start = next((i for i, l in enumerate(lines) if "binary code" in l), None)
if start is None:
    sys.exit("the listing has no binary code section -- was --trace=* dropped?")

CODE = (".code", ".bodycode", ".initcode")
name, keep, count = None, [], 0
byte = re.compile(r"^\t\[\s*[0-9A-F]+\]\s+((?:[0-9A-F]{2}\s+)+)$")

def flush():
    global count
    if name and keep:
        with open(os.path.join(outdir, "%03d-%s.hex" % (count, name)), "w") as f:
            f.write(" ".join("0x" + b for b in keep) + "\n")
        count += 1

for line in lines[start + 1:]:
    if line.startswith("."):
        flush()
        parts = line.split()
        kind = parts[0]
        name = parts[1].replace(".", "_") if kind in CODE and len(parts) > 1 else None
        keep = []
        continue
    if name is None:
        continue
    m = byte.match(line)
    if m:
        keep.extend(m.group(1).split())
flush()
print(count, file=sys.stderr)
PY

sections=$(ls "$work/sections" 2>/dev/null | wc -l)
if [ "$sections" -eq 0 ]; then
	echo "no machine code was emitted" >&2
	exit 1
fi

total=0
bad=0
for hex in "$work"/sections/*.hex; do
	section="$(basename "$hex" .hex)"
	if ! "$llvm_mc" --triple=x86_64 --disassemble "$hex" > "$hex.asm" 2>"$hex.err"; then
		echo "llvm-mc could not decode $section:" >&2
		head -10 "$hex.err" >&2
		bad=$((bad + 1))
		continue
	fi
	# llvm-mc writes a byte it cannot place as an error on stderr and prints <unknown> or (bad) in
	# the listing; either one is a wrong encoding, not a disassembler limitation.
	if grep -qE 'unknown|\(bad\)' "$hex.asm" || [ -s "$hex.err" ]; then
		echo "$section contains bytes llvm-mc does not recognise:" >&2
		grep -nE 'unknown|\(bad\)' "$hex.asm" | head -5 >&2
		head -5 "$hex.err" >&2
		bad=$((bad + 1))
		continue
	fi
	n=$(grep -cE '^\s+[a-z]' "$hex.asm" || true)
	total=$((total + n))
	if [ "$verbose" = "--verbose" ]; then
		echo "== $section ($n instructions)"
		grep -v '\.text' "$hex.asm"
	fi
done

if [ "$bad" -ne 0 ]; then
	echo "[FAIL] $bad of $sections code section(s) did not decode" >&2
	exit 1
fi

echo "AMD64Codegen.Mod compiled for Unix64: $sections code sections, $total instructions, all of them decodable"
