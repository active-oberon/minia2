#!/usr/bin/env bash
#
# Load a module into the AArch64 system at runtime, under qemu.
#
# tests/A64Loader.Mod and tests/A64LoaderAux.Mod are compiled for UnixA64 and deliberately left
# out of the image: the shell of the running system is asked for `A64Loader.Run`, which is what
# makes the loader read the object file, allocate its sections and patch its fixups. The second
# module is loaded because the first imports it, so the run covers a call from a loaded module
# into another loaded module as well as calls into the linked image.
#
# The objects come from tests/a64-runtime-check.sh, which has to have run first. Running needs the
# same things tests/a64-system-check.sh needs -- qemu-user and an AArch64 C library, `task
# a64-sysroot` or A64_SYSROOT providing the latter where the distribution does not -- and is
# skipped, not failed, without them.
#
# Usage: tests/a64-loader-check.sh [build directory] [object directory]

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

# What went wrong, as far as the compiler said so. A failure with no line mentioning an error --
# a directory that is not there, say -- would otherwise be reported as nothing at all, because a
# `grep` that matches nothing ends the script under `set -e`.
Reason() {
	printf '%s\n' "$1" | grep -E 'error' | head -"$2" || printf '%s\n' "$1" | tail -"$2"
}

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
build="$(absolute "$build")"
objects="${2:-$root/target/A64/bin}"
objects="$(absolute "$objects")"

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
# Both modules go to the object directory beside the runtime they will be loaded into: the aux
# module has to be compiled first, because the other imports it and needs its symbol file.
compile=$( (cd "$build" && PWD="$build" "$oberon" do "
	System.DoFile oberon.cfg ~
	Files.AddSearchPath $objects ~
	Compiler.Compile -p=UnixA64 --destPath='$objects/' '$root/tests/A64LoaderAux.Mod' '$root/tests/A64Loader.Mod' ~
") 2>&1 | tr -d '\r' ) || true
if ! printf '%s\n' "$compile" | grep -q ' done\.'; then
	echo "the loader test modules did not compile for UnixA64:" >&2
	Reason "$compile" 10 >&2
	exit 1
fi
# `done.` once for each module: the first can compile and the second fail, and one `done.` in the
# transcript would then read as a pass.
if [ "$(printf '%s\n' "$compile" | grep -c ' done\.')" -ne 2 ]; then
	echo "only one of the two loader test modules compiled for UnixA64:" >&2
	Reason "$compile" 10 >&2
	exit 1
fi

# The image is the plain runtime -- the modules under test are not in it, which is the point.
modules=$(sed 's/#.*//' "$root/configs/moduleListLinux.txt" | tr -d '\r' | tr '\n' ' ')
output=$( (cd "$build" && PWD="$build" "$oberon" do "
	System.DoFile oberon.cfg ~
	Files.SetWorkPath $work ~
	Linker.Link -p=LinuxA64 --path='$objects/' --fileName=oberonA64 $modules ~
") 2>&1 | tr -d '\r' ) || true

if ! printf '%s\n' "$output" | grep -q 'Link successful'; then
	echo "the AArch64 runtime did not link:" >&2
	Reason "$output" 10 >&2
	exit 1
fi
chmod +x "$work/oberonA64"

# Beside the image rather than on a search path: the working directory is where the runtime looks
# without being told anything, which is one fewer thing between the check and what it checks.
cp "$objects/A64Loader.GofU8" "$objects/A64LoaderAux.GofU8" "$work/"

qemu="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
sysroot="${A64_SYSROOT:-}"
if [ -z "$sysroot" ]; then
	for candidate in "$root/target/A64/sysroot" /usr/aarch64-linux-gnu /usr/local/aarch64-linux-gnu; do
		[ -f "$candidate/lib/ld-linux-aarch64.so.1" ] && sysroot="$candidate" && break
	done
fi
if [ -z "$qemu" ] || [ -z "$sysroot" ] || [ ! -f "$sysroot/lib/ld-linux-aarch64.so.1" ]; then
	echo "[SKIP] loading a module on AArch64 needs qemu-user and an AArch64 C library" >&2
	exit 2
fi

# The transcript goes to a file as well: the module names the phase it is entering, and under an
# emulator that is the only way to tell a slow run from a hung one while it is still going.
log="${A64_LOADER_LOG:-$(dirname "$objects")/a64-loader-check.log}"

# `exit` is what leaves the shell: on end of input it spins rather than stopping.
status=0
(cd "$work" && PWD="$work" printf 'A64Loader.Run\nexit\n' \
	| timeout "${A64_LOADER_TIMEOUT:-600}" "$qemu" -L "$sysroot" "$work/oberonA64" > "$log" 2>&1) || status=$?

if [ "$status" -eq 0 ] && grep -q 'A64Loader: passed' "$log"; then
	echo "AArch64 module loading: passed under qemu"
	exit 0
fi

if [ "$status" -eq 124 ]; then
	echo "the AArch64 loader check did not finish in ${A64_LOADER_TIMEOUT:-600} seconds;" >&2
elif [ "$status" -ne 0 ]; then
	echo "the AArch64 loader check left with $status;" >&2
else
	echo "the AArch64 loader check did not pass;" >&2
fi
echo "  the whole of it is in $log:" >&2
tail -40 "$log" | tr -d '\r' >&2
exit 1
