#!/usr/bin/env bash
#
# Compile a module on the AArch64 system itself, under qemu, and run what came out.
#
# The image is the plain runtime; the compiler is not in it. Asking its shell for
# `Compiler.Compile` loads the compiler -- some sixty modules, the whole Fox front end and the A64
# backend -- from the object directory, which is the thing that did not work before: without
# loading there is no compiling on the machine, and without that there is no `ob run`, no REPL and
# no language server there. The module it compiles is then loaded and run in the same session, so
# the check ends on code that this system both built and executed.
#
# The objects come from tests/a64-stdlib-check.sh, which has to have run first: the runtime alone
# does not carry the compiler. Running needs the same things tests/a64-system-check.sh needs --
# qemu-user and an AArch64 C library, `task a64-sysroot` or A64_SYSROOT providing the latter where
# the distribution does not -- and is skipped, not failed, without them.
#
# Usage: tests/a64-selfhost-check.sh [build directory] [object directory]

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

# What went wrong, as far as the linker or the compiler said so. A failure with no line mentioning
# an error -- a directory that is not there, say -- would otherwise be reported as nothing at all,
# because a `grep` that matches nothing ends the script under `set -e`.
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
if [ ! -f "$objects/Compiler.GofU8" ] || [ ! -f "$objects/FoxA64Backend.GofU8" ]; then
	echo "no A64 compiler in $objects; run tests/a64-stdlib-check.sh first" >&2
	exit 2
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The image is the plain runtime: the compiler is loaded into it, not linked into it.
modules=$(sed 's/#.*//' "$root/configs/moduleListLinux.txt" | tr -d '\r' | tr '\n' ' ')

# The runtime reads its working directory from $PWD rather than from getcwd().
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

cp "$root/tests/A64OnDevice.Mod" "$work/"

qemu="$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)"
sysroot="${A64_SYSROOT:-}"
if [ -z "$sysroot" ]; then
	for candidate in "$root/target/A64/sysroot" /usr/aarch64-linux-gnu /usr/local/aarch64-linux-gnu; do
		[ -f "$candidate/lib/ld-linux-aarch64.so.1" ] && sysroot="$candidate" && break
	done
fi
if [ -z "$qemu" ] || [ -z "$sysroot" ] || [ ! -f "$sysroot/lib/ld-linux-aarch64.so.1" ]; then
	echo "[SKIP] compiling on the AArch64 system needs qemu-user and an AArch64 C library" >&2
	exit 2
fi

# The transcript goes to a file as well: a compiler running under an emulator takes minutes, and
# what it last printed is the only way to tell that from a hang while it is still going.
log="${A64_SELFHOST_LOG:-$(dirname "$objects")/a64-selfhost-check.log}"

# Four commands, and the order of them is the recipe:
#
#	-	the object directory goes on the search path, which is where the compiler is loaded from and
#		where it finds the symbol files of what the module imports;
#	-	the module is named by an absolute path, because a relative one is resolved against the work
#		path of the system rather than the directory the image was started in; and no --destPath,
#		because giving one is what makes the compiler look for symbol files there and nowhere else;
#	-	the working directory, where the compiler has just written the object, goes on the search
#		path as well: what the system is started in is not on it by itself;
#	-	and then the module that this machine built is loaded and run on it.
#
# `exit` is what leaves the shell: on end of input it spins rather than stopping.
status=0
(cd "$work" && PWD="$work" printf 'Files.AddSearchPath %s\nCompiler.Compile -p=UnixA64 %s\nFiles.AddSearchPath %s\nA64OnDevice.Run\nexit\n' \
	"$objects" "'$work/A64OnDevice.Mod'" "$work" \
	| timeout "${A64_SELFHOST_TIMEOUT:-1800}" "$qemu" -L "$sysroot" "$work/oberonA64" > "$log" 2>&1) || status=$?

if [ "$status" -eq 0 ] \
	&& grep -q 'A64OnDevice done\.' "$log" \
	&& grep -q 'A64OnDevice: passed' "$log" \
	&& [ -f "$work/A64OnDevice.GofU8" ]; then
	echo "AArch64 compiled a module on itself under qemu and ran what it built"
	exit 0
fi

if [ "$status" -eq 124 ]; then
	echo "the AArch64 self hosting check did not finish in ${A64_SELFHOST_TIMEOUT:-1800} seconds;" >&2
elif [ "$status" -ne 0 ]; then
	echo "the AArch64 self hosting check left with $status;" >&2
elif [ ! -f "$work/A64OnDevice.GofU8" ]; then
	echo "the AArch64 compiler wrote no object file;" >&2
else
	echo "the AArch64 self hosting check did not pass;" >&2
fi
echo "  the whole of it is in $log:" >&2
tail -40 "$log" | tr -d '\r' >&2
exit 1
