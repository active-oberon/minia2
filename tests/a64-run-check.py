#!/usr/bin/env python3
"""Run the code the A64 generator produced, under qemu, and check what it computes.

The machine code of the leaf procedures of tests/A64Codegen.Mod is lifted out of the compiler's
listing and pasted into an assembly file next to a test driver that calls each one with fixed
arguments and compares the answer against the one the language report requires.  The driver builds
the frame an A2 procedure expects -- parameters pushed left to right, eight bytes each, removed by
the caller -- because that is the whole calling convention as far as a leaf procedure can see it.

There is no linker for AArch64 on this machine and no C library either, so the result is not linked:
llvm-mc assembles the file, llvm-objcopy lifts out the text, and the ELF around it is written here.
The driver talks to the kernel directly, which is two system calls, and reports by writing one
character per test and exiting with the number of failures.

Only leaf procedures are used: a call to another section leaves a fixup that nothing resolves.
For the same reason the module is not compiled for UnixA64 as such but for the backend underneath
it, without the four flags that platform carries: --trackLeave alone has every procedure name its
own descriptor section, and a fixup to that is one more thing there is no linker here to resolve.
What the generated arithmetic computes does not depend on them, and what does -- that the collector
and the barriers work on AArch64 -- is what tests/a64-gc-check.sh runs instead.

Usage: tests/a64-run-check.py [build directory]
"""

import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = 0x400000                     # where the one loadable segment lands
# UnixA64 without --trackLeave, --preciseGC, --writeBarriers and --cellsAreObjects: see above.
# It is registered as a platform of its own rather than passed as bare options, because options
# outside a platform are read on top of the default one -- Unix64 here -- and would inherit the
# four flags from it.
PLATFORM = "A64Bare"
PLATFORM_OPTIONS = ("-b=A64 --mergeSections --traceModule=Trace --objectFileExtension=.GofU8"
                    " --symbolFileExtension=.SymU8 --platformCC=C --define=UNIX,ARM64")
EHDR_SIZE, PHDR_SIZE = 64, 56


def tool(*names):
    for name in names:
        found = shutil.which(name)
        if found:
            return found
    return None


def llvm_tool(name):
    """llvm-mc and llvm-objcopy are versioned on Debian and Ubuntu -- llvm-mc-18, llvm-mc-19 --
    and which of them is installed depends on the machine. The plain name first, the newest
    versioned one after it, so a runner whose image moved to another release still finds it."""
    found = shutil.which(name)
    if found:
        return found
    versioned = []
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        try:
            entries = os.listdir(directory)
        except OSError:
            continue
        for entry in entries:
            suffix = entry[len(name) + 1:]
            if entry.startswith(name + "-") and suffix.isdigit():
                versioned.append((int(suffix), os.path.join(directory, entry)))
    return max(versioned)[1] if versioned else None


def die_skip(message):
    print(message, file=sys.stderr)
    sys.exit(2)


def die(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def compile_for_a64(build, work):
    """Compile the test module for bare A64 and return the binary listing."""
    oberon = os.path.join(build, "oberon")
    if not os.access(oberon, os.X_OK):
        oberon = os.path.join(build, "oberon.exe")
    if not os.access(oberon, os.X_OK):
        die_skip("no built runtime in %s; run 'task Linux64' or 'task oberon' first" % build)

    shutil.copy(os.path.join(ROOT, "tests", "A64Codegen.Mod"), work)
    script = (
        "System.DoFile oberon.cfg ~\n"
        "Files.AddSearchPath %s ~\n"
        "Compiler.AddPlatform %s \"%s\" ~\n"
        "Compiler.Compile -p=%s --destPath=%s/ --trace=* A64Codegen.Mod ~\n"
        % (work, PLATFORM, PLATFORM_OPTIONS, PLATFORM, work)
    )
    # A2 reads its working directory from $PWD rather than from getcwd().
    environment = dict(os.environ, PWD=build)
    result = subprocess.run([oberon, "do", script], cwd=build, env=environment,
                            capture_output=True, text=True)
    listing = (result.stdout + result.stderr).replace("\r", "")
    if "A64Codegen done." not in listing:
        die("A64Codegen.Mod did not compile for UnixA64:\n"
            + "\n".join(line for line in listing.splitlines() if "error" in line))
    return listing[listing.index("binary code"):]


def section_bytes(listing, name):
    """The machine code of one section, as it appears in the listing."""
    wanted = ".code A64Codegen.%s " % name
    collecting, code = False, bytearray()
    for line in listing.splitlines():
        if line.startswith(wanted):
            collecting = True
            continue
        if collecting:
            match = re.match(r"^\t\[[ 0-9A-F]*\] (.*)$", line)
            if not match:
                break
            code += bytes(int(b, 16) for b in match.group(1).split())
    if not code:
        die("no code found for A64Codegen.%s" % name)
    return bytes(code)


def constant(register, value):
    """MOVZ and MOVK enough to put a 64 bit value in a register."""
    value &= (1 << 64) - 1
    lines = ["\tmovz\t%s, #%d" % (register, value & 0xFFFF)]
    for shift in (16, 32, 48):
        halfword = (value >> shift) & 0xFFFF
        if halfword:
            lines.append("\tmovk\t%s, #%d, lsl #%d" % (register, halfword, shift))
    return lines


def bits(value, width):
    return value & ((1 << width) - 1)


def float_bits(value, width):
    packed = struct.pack("<f" if width == 32 else "<d", value)
    return int.from_bytes(packed, "little")


class Tests:
    """The cases, and the assembly that runs them."""

    def __init__(self):
        self.lines = []
        self.names = []

    def add(self, name, procedure, args, expected, mask=0xFFFFFFFFFFFFFFFF, floating=False):
        index = len(self.names)
        self.names.append(name)
        out = self.lines
        out.append("\t// %s" % name)
        out.append("\tadr\tx0, a2_%s" % procedure)
        for i, slot in enumerate(args):
            out += constant("x%d" % (i + 1), slot)
        out.append("\tbl\ta2call%d" % len(args))
        if floating:
            out.append("\tfmov\tx0, d0")
        out += constant("x4", mask)
        out.append("\tand\tx0, x0, x4")
        out += constant("x3", expected & mask)
        out.append("\tcmp\tx0, x3")
        out.append("\tb.eq\tpass%d" % index)
        out.append("\tadd\tx20, x20, #1")
        out.append("\tmov\tw0, #70")            # 'F'
        out.append("\tb\treport%d" % index)
        out.append("pass%d:" % index)
        out.append("\tmov\tw0, #46")            # '.'
        out.append("report%d:" % index)
        out.append("\tbl\tputc")
        out.append("")


def build_tests():
    t = Tests()

    # Add(a, b: SIGNED32): SIGNED32
    t.add("Add", "Add", [bits(3, 32), bits(4, 32)], 7, mask=0xFFFFFFFF)
    t.add("Add.negative", "Add", [bits(-9, 32), bits(4, 32)], bits(-5, 32), mask=0xFFFFFFFF)

    # Arith(a, b: SIGNED64): a*b + a DIV b - a MOD b, with Oberon's flooring DIV and MOD
    t.add("Arith", "Arith", [bits(100, 64), bits(7, 64)], bits(100 * 7 + 14 - 2, 64))
    t.add("Arith.negative", "Arith", [bits(-100, 64), bits(7, 64)],
          bits(-100 * 7 + (-100 // 7) - (-100 % 7), 64))

    # Unsigned(a, b: UNSIGNED32): a DIV b + a MOD b
    t.add("Unsigned", "Unsigned", [bits(100, 32), bits(7, 32)], 14 + 2, mask=0xFFFFFFFF)

    # Floats(x, y: FLOAT64): x*y + x/y - ABS(x)
    t.add("Floats", "Floats", [float_bits(2.0, 64), float_bits(4.0, 64)],
          float_bits(2.0 * 4.0 + 0.5 - 2.0, 64), floating=True)
    t.add("Floats.negative", "Floats", [float_bits(-3.0, 64), float_bits(2.0, 64)],
          float_bits(-6.0 + -1.5 - 3.0, 64), floating=True)

    # Mixed(n: SIGNED32; x: FLOAT32): LONG(x) * n
    t.add("Mixed", "Mixed", [bits(3, 32), float_bits(1.5, 32)], float_bits(4.5, 64), floating=True)

    # Truncate(x: FLOAT64): ENTIER(x), which rounds towards minus infinity
    t.add("Truncate", "Truncate", [float_bits(2.75, 64)], 2, mask=0xFFFFFFFF)
    t.add("Truncate.negative", "Truncate", [float_bits(-2.75, 64)], bits(-3, 32), mask=0xFFFFFFFF)

    # Bits(a, b: SET): a*b + a/b - a
    a, b = (1 << 0) | (1 << 2), (1 << 1) | (1 << 2)
    t.add("Bits", "Bits", [bits(a, 32), bits(b, 32)],
          ((a & b) | (a ^ b)) & ~a & 0xFFFFFFFF, mask=0xFFFFFFFF)

    # Shifts(a, n): LSH(a, n) + ASH(a, -n) + ROT(a, n)
    value, amount = 0x12345678, 4
    shifted = (value << amount) & 0xFFFFFFFF
    rotated = ((value << amount) | (value >> (32 - amount))) & 0xFFFFFFFF
    t.add("Shifts", "Shifts", [bits(value, 32), bits(amount, 32)],
          (shifted + (value >> amount) + rotated) & 0xFFFFFFFF, mask=0xFFFFFFFF)

    # Narrow(v: SIGNED8): SIGNED64 -- sign extension all the way up
    t.add("Narrow", "Narrow", [bits(-3, 32)], bits(-3, 64))

    # Compare(a, b): (a < b) OR (a = b) & (a >= 0)
    t.add("Compare.less", "Compare", [bits(1, 32), bits(2, 32)], 1, mask=0xFF)
    t.add("Compare.equal", "Compare", [bits(5, 32), bits(5, 32)], 1, mask=0xFF)
    t.add("Compare.greater", "Compare", [bits(9, 32), bits(2, 32)], 0, mask=0xFF)
    return t


PROCEDURES = ["Add", "Arith", "Unsigned", "Floats", "Mixed", "Truncate",
              "Bits", "Shifts", "Narrow", "Compare"]

DRIVER_TAIL = r"""
	// exit(failures)
	mov	x0, x20
	mov	x8, #93
	svc	#0

// write the character in w0 to standard output
putc:
	sub	sp, sp, #16
	strb	w0, [sp]
	mov	x0, #1
	mov	x1, sp
	mov	x2, #1
	mov	x8, #64
	svc	#0
	add	sp, sp, #16
	ret

// The A2 convention as a leaf procedure sees it: each parameter gets its own eight byte slot, the
// first parameter at the highest address, and the caller takes them off again.
a2call2:
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
	sub	sp, sp, #16
	str	x1, [sp, #8]
	str	x2, [sp]
	mov	x3, x0
	blr	x3
	add	sp, sp, #16
	mov	sp, x29
	ldp	x29, x30, [sp], #16
	ret

a2call1:
	stp	x29, x30, [sp, #-16]!
	mov	x29, sp
	sub	sp, sp, #16
	str	x1, [sp]
	mov	x3, x0
	blr	x3
	add	sp, sp, #16
	mov	sp, x29
	ldp	x29, x30, [sp], #16
	ret
"""


def assembly(listing, tests):
    out = ["\t.text", "\t.globl _start", "_start:", "\tmov\tx20, #0", ""]
    out += tests.lines
    out.append(DRIVER_TAIL)
    for name in PROCEDURES:
        code = section_bytes(listing, name)
        out.append("\t.p2align 2")
        out.append("a2_%s:" % name)
        out.append("\t.byte " + ",".join("0x%02x" % b for b in code))
    return "\n".join(out) + "\n"


def write_elf(path, code):
    """A static ELF64 for AArch64 with one loadable segment: headers, then the code."""
    entry = BASE + EHDR_SIZE + PHDR_SIZE
    size = EHDR_SIZE + PHDR_SIZE + len(code)
    ehdr = struct.pack(
        "<4sBBBBB7sHHIQQQIHHHHHH",
        b"\x7fELF", 2, 1, 1, 0, 0, b"\0" * 7,
        2,          # ET_EXEC
        183,        # EM_AARCH64
        1, entry,
        EHDR_SIZE,  # program header table offset
        0, 0,
        EHDR_SIZE, PHDR_SIZE, 1, 0, 0, 0)
    phdr = struct.pack(
        "<IIQQQQQQ",
        1,          # PT_LOAD
        5,          # read and execute
        0, BASE, BASE, size, size, 0x1000)
    with open(path, "wb") as f:
        f.write(ehdr + phdr + code)
    os.chmod(path, 0o755)


def main():
    # Absolute, because the compiler is run with the build directory as its working directory and
    # a relative path would then be read from there rather than from where it was given.
    build = os.path.abspath(sys.argv[1] if len(sys.argv) > 1
                            else os.path.join(ROOT, "target", "Linux64"))

    qemu = tool("qemu-aarch64-static", "qemu-aarch64")
    llvm_mc = llvm_tool("llvm-mc")
    objcopy = llvm_tool("llvm-objcopy")
    if not qemu or not llvm_mc or not objcopy:
        die_skip("need qemu-aarch64-static, llvm-mc and llvm-objcopy "
                 "(Debian: apt install qemu-user-static llvm-18)")

    with tempfile.TemporaryDirectory() as work:
        listing = compile_for_a64(build, work)
        tests = build_tests()

        source = os.path.join(work, "driver.s")
        with open(source, "w") as f:
            f.write(assembly(listing, tests))

        obj, raw, elf = (os.path.join(work, n) for n in ("driver.o", "driver.bin", "driver"))
        run = subprocess.run([llvm_mc, "--triple=aarch64", "--filetype=obj", "-o", obj, source],
                             capture_output=True, text=True)
        if run.returncode != 0:
            die("the driver did not assemble:\n" + run.stderr)
        subprocess.run([objcopy, "-O", "binary", "--only-section=.text", obj, raw], check=True)
        with open(raw, "rb") as f:
            code = f.read()
        write_elf(elf, code)

        run = subprocess.run([qemu, elf], capture_output=True, text=True)

    marks = run.stdout.strip()
    if len(marks) != len(tests.names):
        die("the driver reported %d results for %d tests (exit %d)\n%s"
            % (len(marks), len(tests.names), run.returncode, run.stderr))

    failures = [name for name, mark in zip(tests.names, marks) if mark != "."]
    for name in failures:
        print("FAIL %s" % name)
    if failures:
        die("%d of %d generated procedures computed the wrong answer" % (len(failures), len(marks)))
    print("%d generated procedures ran under qemu and computed the right answer" % len(marks))


if __name__ == "__main__":
    main()
