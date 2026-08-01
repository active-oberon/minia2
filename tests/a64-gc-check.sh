#!/usr/bin/env bash
#
# Run the garbage collector, the write barriers and the leave tracking on AArch64, under qemu.
#
# tests/A64GCStress.Mod is compiled for UnixA64 and linked into the image beside the kernel, and
# then driven from the shell. It is linked in rather than loaded because loading a module on
# AArch64 does not work yet: the section lands on the heap, too far from the kernel for the 26 bit
# displacement of BL to reach.
#
# The objects come from tests/a64-runtime-check.sh, which has to have run first. Running needs the
# same things tests/a64-system-check.sh needs -- qemu-user and an AArch64 C library, `task
# a64-sysroot` or A64_SYSROOT providing the latter where the distribution does not -- and is
# skipped, not failed, without them.
#
# Usage: tests/a64-gc-check.sh [build directory] [object directory]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
objects="${2:-$root/target/A64/bin}"

oberon="$build/oberon"
[ -x "$oberon" ] || oberon="$build/oberon.exe"
if [ ! -x "$oberon" ]; then
	echo "no built runtime in $build; run 'task Linux64' or 'task oberon' first" >&2
	exit 2
fi
if [ ! -f "$objects/Glue.GofU8" ]; then
	echo "no A64 objects in $objects; run tests/a64-runtime-check.sh first" >&2
	exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The runtime reads its working directory from $PWD rather than from getcwd().
compile=$( (cd "$build" && PWD="$build" "$oberon" do "
	System.DoFile oberon.cfg ~
	Files.AddSearchPath $objects ~
	Compiler.Compile -p=UnixA64 --destPath=$objects/ $root/tests/A64GCStress.Mod ~
") 2>&1 | tr -d '\r' )
if ! printf '%s\n' "$compile" | grep -q ' done\.'; then
	echo "A64GCStress did not compile for UnixA64:" >&2
	printf '%s\n' "$compile" | grep -E 'error' | head -10 >&2
	exit 1
fi

modules=$(sed 's/#.*//' "$root/configs/moduleListLinux.txt" | tr -d '\r' | tr '\n' ' ')
output=$( (cd "$build" && PWD="$build" "$oberon" do "
	System.DoFile oberon.cfg ~
	Files.SetWorkPath $work ~
	Linker.Link -p=LinuxA64 --path=$objects/ --fileName=oberonA64 $modules A64GCStress ~
") 2>&1 | tr -d '\r' )

if ! printf '%s\n' "$output" | grep -q 'Link successful'; then
	echo "the AArch64 image with A64GCStress did not link:" >&2
	printf '%s\n' "$output" | grep -E 'error' | head -10 >&2
	exit 1
fi
chmod +x "$work/oberonA64"

qemu="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
sysroot="${A64_SYSROOT:-}"
if [ -z "$sysroot" ]; then
	for candidate in "$root/target/A64/sysroot" /usr/aarch64-linux-gnu /usr/local/aarch64-linux-gnu; do
		[ -f "$candidate/lib/ld-linux-aarch64.so.1" ] && sysroot="$candidate" && break
	done
fi
if [ -z "$qemu" ] || [ -z "$sysroot" ] || [ ! -f "$sysroot/lib/ld-linux-aarch64.so.1" ]; then
	echo "[SKIP] running the AArch64 collector check needs qemu-user and an AArch64 C library" >&2
	exit 2
fi

# The transcript goes to a file rather than only into a variable: the run takes minutes under an
# emulator, and the phase the module last announced is the only way to tell a slow one from a
# hung one while it is still going. It outlives the run, which the temporary directory does not.
log="${A64_GC_LOG:-$(dirname "$objects")/a64-gc-check.log}"

# `exit` is what leaves the shell: on end of input it spins rather than stopping.
# Nothing filters the transcript on the way in -- a `tr` in front of the file would hold the
# phases in its buffer until the run ended, which is the one thing this is not for. The carriage
# returns come off on the way out instead.
(cd "$work" && PWD="$work" printf 'A64GCStress.Run\nexit\n' \
	| timeout "${A64_GC_TIMEOUT:-900}" "$qemu" -L "$sysroot" "$work/oberonA64" > "$log" 2>&1) || true

if grep -q 'A64GCStress: passed' "$log"; then
	echo "AArch64 collector, write barriers and leave tracking: passed under qemu"
	exit 0
fi

echo "the AArch64 collector check did not pass; the whole of it is in $log:" >&2
tail -40 "$log" | tr -d '\r' >&2
exit 1
