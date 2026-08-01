#!/usr/bin/env bash
#
# Link the AArch64 runtime into an executable and run the system inside it.
#
# The modules come from tests/a64-runtime-check.sh, which has to have run first; this links the
# kernel list of configs/moduleListLinux.txt into an ELF that Glue writes itself, and then, if there
# is an AArch64 C library to run against, drives the shell through qemu and checks what it answers.
#
# Running needs a sysroot with ld-linux-aarch64.so.1 and libc.so.6 in it, because the image is
# dynamically linked against libdl and reaches the rest of libc through dlopen. On Debian and Ubuntu
# that is the libc6-arm64-cross package, which installs into /usr/aarch64-linux-gnu; `task
# a64-sysroot` unpacks one into target/A64/sysroot where the package is not to be had, and
# A64_SYSROOT names any other. Without it the link is still checked and the run is skipped.
#
# Usage: tests/a64-system-check.sh [build directory] [object directory]

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

modules=$(sed 's/#.*//' "$root/configs/moduleListLinux.txt" | tr -d '\r' | tr '\n' ' ')

# The runtime reads its working directory from $PWD rather than from getcwd().
output=$( (cd "$build" && PWD="$build" "$oberon" do "
	System.DoFile oberon.cfg ~
	Files.SetWorkPath $work ~
	Linker.Link -p=LinuxA64 --path=$objects/ --fileName=oberonA64 $modules ~
") 2>&1 | tr -d '\r' )

if ! printf '%s\n' "$output" | grep -q 'Link successful'; then
	echo "the AArch64 runtime did not link:" >&2
	printf '%s\n' "$output" | grep -E 'error' | head -10 >&2
	exit 1
fi
chmod +x "$work/oberonA64"
echo "AArch64 runtime linked: $(wc -c < "$work/oberonA64") bytes"

qemu="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
sysroot="${A64_SYSROOT:-}"
if [ -z "$sysroot" ]; then
	for candidate in "$root/target/A64/sysroot" /usr/aarch64-linux-gnu /usr/local/aarch64-linux-gnu; do
		[ -f "$candidate/lib/ld-linux-aarch64.so.1" ] && sysroot="$candidate" && break
	done
fi
if [ -z "$qemu" ] || [ -z "$sysroot" ] || [ ! -f "$sysroot/lib/ld-linux-aarch64.so.1" ]; then
	echo "[SKIP] running the AArch64 system needs qemu-user and an AArch64 C library" >&2
	exit 2
fi

# `exit` is what leaves the shell: on end of input it spins rather than stopping, because the loop
# of StdIO.ReceiveStdin only ends when errno says something, and end of file sets nothing.
answer=$(printf 'System.Show the system answers\nSystem.Time\nexit\n' \
	| timeout 120 "$qemu" -L "$sysroot" "$work/oberonA64" 2>&1 | tr -d '\r')

if ! printf '%s\n' "$answer" | grep -q 'Shell v'; then
	echo "the AArch64 system did not reach its shell:" >&2
	printf '%s\n' "$answer" | head -20 >&2
	exit 1
fi
if ! printf '%s\n' "$answer" | grep -q 'the system answers'; then
	echo "the AArch64 system did not run the command it was given:" >&2
	printf '%s\n' "$answer" | head -20 >&2
	exit 1
fi
# System.Time writes the date the C library reports, which is the day this runs
if ! printf '%s\n' "$answer" | grep -qE '[0-9]{2}\.[0-9]{2}\.[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}'; then
	echo "the AArch64 system did not report a time:" >&2
	printf '%s\n' "$answer" | head -20 >&2
	exit 1
fi

echo "AArch64 system booted under qemu: the shell answered both commands"
