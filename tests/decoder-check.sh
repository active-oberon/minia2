#!/usr/bin/env bash
#
# Differential test of Decoder, AMD64Decoder and I386Decoder against objdump.
#
# tests/amd64-instructions.s and tests/i386-instructions.s are assembled by llvm-mc; the bytes that
# come out are given to our own disassembler and to objdump, and the two readings are compared
# instruction by instruction: the offset each one starts at, how many bytes it took, and its
# mnemonic. Both the decoder and its printer are under test, and they would have to be wrong in the
# same way -- and in a way that agrees with the architecture manual -- to pass.
#
# Two decoders and one driver: Decoder keeps a decoder per object file extension, Abx being the
# AMD64 one and Obx the IA-32 one, and tests/DecoderDrive.Mod asks for either by name.
#
# Why the boundaries matter as much as the names: on x86 nearly any byte sequence decodes as
# something, so "it decoded" is not "it is right". An instruction whose length is read wrong takes
# the bytes after it, and everything that follows decodes as something else again. That is how the
# first run found `48 0F C8` -- BSWAP RAX -- being read as an eleven-byte instruction with an
# immediate it does not have.
#
# The operands are printed side by side under --verbose rather than compared: this decoder writes
# them in A2's own syntax (hexadecimal with an H, brackets for memory) and objdump in Intel's, and
# normalising one into the other would be a second decoder to get wrong.
#
# Usage: tests/decoder-check.sh [build directory] [--verbose]

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
objcopy="$(command -v objcopy || LlvmTool llvm-objcopy)"
objdump="$(command -v objdump || true)"
for tool in "$llvm_mc" "$objcopy" "$objdump"; do
	if [ -z "$tool" ]; then
		echo "this check needs llvm-mc, objcopy and objdump (Debian: apt install llvm binutils)" >&2
		exit 2
	fi
done

oberon="$build/oberon"
[ -x "$oberon" ] || oberon="$build/oberon.exe"
if [ ! -x "$oberon" ]; then
	echo "no built runtime in $build; run 'task Linux64' or 'task oberon' first" >&2
	exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# One line per decoder: the name of the check, the object file extension it is registered for,
# llvm-mc's triple, objdump's machine, and the corpus it reads.
targets=(
	"amd64|Abx|x86_64|i386:x86-64|amd64-instructions.s"
	"i386|Obx|i386|i386|i386-instructions.s"
)

# An object file and not --show-encoding: for an instruction whose target is not a number yet,
# llvm-mc prints a placeholder in place of the bytes, and the placeholder reads as a hex digit.
# Assembling to an object and taking .text out of it gives the bytes that would be executed.
for target in "${targets[@]}"; do
	IFS='|' read -r name extension triple machine corpus <<<"$target"
	"$llvm_mc" --triple="$triple" -filetype=obj "$root/tests/$corpus" -o "$work/$name.o" 2>"$work/$name.err" || {
		echo "llvm-mc could not assemble tests/$corpus:" >&2
		head -10 "$work/$name.err" >&2
		exit 1
	}
	if [ -s "$work/$name.err" ]; then
		echo "llvm-mc had something to say about tests/$corpus:" >&2
		head -10 "$work/$name.err" >&2
		exit 1
	fi
	"$objcopy" -O binary --only-section=.text "$work/$name.o" "$work/$name.bin"
	[ -s "$work/$name.bin" ] || { echo "the assembled $name corpus has no code in it" >&2; exit 1; }
	od -An -v -tx1 "$work/$name.bin" | tr -s ' ' | sed 's/^ //' > "$work/$name.hex"
	"$objdump" -d -M intel -m "$machine" --insn-width=16 "$work/$name.o" |
		tail -n +8 | sed 's/^ *//' > "$work/$name.oracle"
done

# Where the objects this run compiles go, and where they are loaded from. The runtime's search path
# is work, bin, source, data; bin holds an object for every module of the system, so a run that
# compiles a module into the working directory and does not name that directory first would load
# whatever was built the last time somebody ran `task update` -- see tests/wm-check.sh, where the
# same thing came up as a zoom of 1 with the source in front of it saying 4.
objects="$build/work-decoder"
rm -rf "$objects"
mkdir -p "$objects"

# The display first and the window manager over it, then the decoders: several modules of the
# component framework Decoder imports wait during their own initialisation for both, and block for
# ever on a machine that has neither. WMDemo.Screen registers a display of nothing but memory.
#
# The runtime reads its working directory from $PWD rather than from getcwd().
output=$( (cd "$build" && PWD="$build" AOSPATH="$objects:$build" "$oberon" do "
	System.DoFile oberon.cfg ~
	Files.SetWorkPath '$objects' ~
	Compiler.Compile '$root/source/WMDemo.Mod' '$root/tests/DecoderDrive.Mod' ~
	WMDemo.Screen ~
	WindowManager.Install ~
	DecoderDrive.Decode Abx '$work/amd64.hex' '$work/amd64.ours' ~
	DecoderDrive.Decode Obx '$work/i386.hex' '$work/i386.ours' ~
") 2>&1 | tr -d '\r' ) || true

for module in WMDemo DecoderDrive; do
	printf '%s\n' "$output" | grep -q "$module.Mod => $module done\." && continue
	echo "$module.Mod did not compile:" >&2
	printf '%s\n' "$output" | grep -E 'error' | head -10 >&2 || printf '%s\n' "$output" | tail -10 >&2
	exit 1
done
if [ "$(printf '%s\n' "$output" | grep -c '^DecoderDrive: ')" -ne "${#targets[@]}" ]; then
	echo "a decoder did not run -- they are loaded over a memory display, so this is where a block shows:" >&2
	printf '%s\n' "$output" | tail -15 >&2
	exit 1
fi
# A decode error goes to KernelLog. An opcode the decoder does not know is not one of these -- it is
# printed as Invalid and the sweep goes on -- so this is the decoder saying it lost its footing.
if printf '%s\n' "$output" | grep -q 'decode error'; then
	echo "the decoder reported an error on a byte it was given:" >&2
	printf '%s\n' "$output" | grep -A2 'decode error' | head -10 >&2
	exit 1
fi

failed=0
for target in "${targets[@]}"; do
	IFS='|' read -r name extension triple machine corpus <<<"$target"
	[ -s "$work/$name.ours" ] || { echo "the $name decoder wrote no listing" >&2; exit 1; }
	tr -d '\r' < "$work/$name.ours" > "$work/$name.clean"
	NAME="$name" VERBOSE="$verbose" python3 - "$work/$name.clean" "$work/$name.oracle" <<'PY' || failed=1
import os, re, sys

ours_file, oracle_file = sys.argv[1], sys.argv[2]
verbose = os.environ.get("VERBOSE") == "--verbose"
target = os.environ.get("NAME", "?")

# The same instruction under two names. objdump picks one synonym of a condition and this decoder
# picks another; a size that objdump writes into the operand ("movs BYTE PTR") this decoder writes
# into the mnemonic (MOVSB); and where objdump folds a comparison predicate into the name
# (cmpeqsd), this decoder prints the predicate as the immediate it is encoded as. None of these is
# a disagreement about what the bytes mean, so they are named here rather than counted.
SAME = {
    "SETNB": "SETAE", "SETAE": "SETAE", "SETNBE": "SETA", "SETA": "SETA",
    "SETNL": "SETGE", "SETNLE": "SETG", "SETNZ": "SETNE", "SETZ": "SETE",
    # the zero flag and equality are the same flag, and the two decoders name it differently
    "JZ": "JE", "JNZ": "JNE", "CMOVZ": "CMOVE", "CMOVNZ": "CMOVNE",
    "CMOVNB": "CMOVAE", "CMOVAE": "CMOVAE", "CMOVNBE": "CMOVA", "CMOVA": "CMOVA",
    "CMOVNL": "CMOVGE", "CMOVNLE": "CMOVG",
    "JNB": "JAE", "JAE": "JAE", "JNBE": "JA", "JA": "JA", "JNL": "JGE", "JNLE": "JG",
    "CQTO": "CQO", "CLTQ": "CDQE", "CBTW": "CBW", "CWTD": "CWD", "CWTL": "CWDE",
    "CLTD": "CDQ", "CDQ": "CDQ",
    "RETQ": "RET", "JMPQ": "JMP", "CALLQ": "CALL", "PUSHQ": "PUSH", "POPQ": "POP",
    "MOVABS": "MOV", "SAL": "SHL", "NOPW": "NOP", "NOPL": "NOP",
    "REPZ": "REP", "REPE": "REP", "REPNZ": "REPN", "REPNE": "REPN",
    "INT3": "INT", "INT": "INT",
    "PUSHA": "PUSHAD", "POPA": "POPAD", "PUSHF": "PUSHFD", "POPF": "POPFD",
    # the width of a string operation: in the mnemonic here, in the operand there
    "MOVSB": "MOVS", "MOVSW": "MOVS", "MOVSD": "MOVS", "MOVSQ": "MOVS",
    "STOSB": "STOS", "STOSW": "STOS", "STOSD": "STOS", "STOSQ": "STOS",
    "SCASB": "SCAS", "SCASW": "SCAS", "SCASD": "SCAS", "SCASQ": "SCAS",
    "LODSB": "LODS", "LODSQ": "LODS", "CMPSB": "CMPS", "CMPSQ": "CMPS",
    # the predicate of a packed comparison: an immediate here, part of the name there
    "CMPEQSD": "CMPSD", "CMPLTSD": "CMPSD", "CMPEQSS": "CMPSS", "CMPEQPS": "CMPPS",
}

def name(mnemonic):
    mnemonic = mnemonic.upper()
    return SAME.get(mnemonic, mnemonic)

def mnemonic(text):
    words = text.replace(",", " ").split()
    if not words:
        return ""
    first = name(words[0])
    # a repeat or a lock is a prefix of the instruction, not the instruction
    if first in ("REP", "REPN", "LOCK") and len(words) > 1:
        return first + " " + name(words[1])
    return first

ours = []
for line in open(ours_file, encoding="latin-1"):
    if not line.strip():
        continue
    offset, length, byts, text = line.rstrip("\n").split("\t")
    ours.append((int(offset), int(length), byts, text))

theirs = []
for line in open(oracle_file, encoding="latin-1"):
    m = re.match(r"^([0-9a-f]+):\t([0-9a-f ]+?)\t+(.*)$", line.rstrip("\n"))
    if not m:
        continue
    byts = m.group(2).replace(" ", "")
    theirs.append((int(m.group(1), 16), len(byts) // 2, byts, m.group(3).split("#")[0].strip()))

if not ours or not theirs:
    sys.exit("one of the two %s listings is empty: %d ours, %d objdump" % (target, len(ours), len(theirs)))

i = j = bad = 0
while i < len(ours) and j < len(theirs):
    o, t = ours[i], theirs[j]
    if o[0] != t[0]:
        # A length read wrong takes the bytes after it, so the listings are walked back together
        # rather than abandoned: one wrong instruction is one finding and not the rest of the file.
        print("[FAIL] %s %#06x: ours [%s] is not where objdump has %#06x [%s]" %
              (target, o[0], o[3], t[0], t[3]))
        bad += 1
        if o[0] < t[0]:
            i += 1
        else:
            j += 1
        continue
    if o[1] != t[1] or mnemonic(o[3]) != mnemonic(t[3]):
        print("[FAIL] %s %#06x: %d byte(s) [%s] against objdump's %d [%s]" %
              (target, o[0], o[1], o[3], t[1], t[3]))
        bad += 1
    elif verbose:
        print("  %#06x  %-28s  %s" % (o[0], o[3], t[3]))
    i += 1
    j += 1

if len(ours) != len(theirs):
    print("[FAIL] %s: %d instructions decoded, objdump reads %d" % (target, len(ours), len(theirs)))
    bad += 1

if bad:
    print("[FAIL] %s: %d of %d instructions disagree" % (target, bad, len(theirs)))
    sys.exit(1)
print("%s disassembler: %d instructions, %d bytes, every one read as objdump reads it" %
      (target, len(theirs), theirs[-1][0] + theirs[-1][1]))
PY
done
exit "$failed"
