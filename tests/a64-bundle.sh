#!/usr/bin/env bash
#
# Assemble a self-contained AArch64 SDK to carry to a real machine.
#
# What comes out is a directory (and, unless told otherwise, a tarball of it) that needs
# nothing on the far side but a C library and coreutils: the runtime, the standard library and
# compiler as AArch64 objects, `ob`, the test suites, and one script that runs the lot. No
# Docker, no build tree, no emulator. Copy it to a phone under Termux+proot, to a Pi 4/5, to an
# ARM server; unpack; run ./run.sh.
#
# It is deliberately the same shape as an SDK installation -- oberon, lib/, boot-modules.txt,
# ob -- because `ob` reads the architecture off the runtime's own ELF header and, finding
# AArch64, treats a64 as the native target rather than a cross target. So this doubles as the
# first honest answer to "what would a tarball release look like", which is the other thing
# that wants doing.
#
# The objects come from tests/a64-stdlib-check.sh and the image from any of the A64 checks that
# link one; both have to have run first (`task a64-stdlib`).
#
# With --android the image is built for Bionic instead of glibc. Two strings differ and neither can
# be tried at run time, because the loader reads them before any of our code runs: the interpreter
# (/system/bin/linker64 rather than /lib/ld-linux-aarch64.so.1) and the one library this image asks
# for (libdl.so rather than libdl.so.2). Both are in Glue, so only that module is compiled again,
# with --define=ANDROID, and the image is linked over the result. The library names that Unix
# resolves for itself need no build of their own: it tries the glibc name and then the Bionic one.
#
# Usage: tests/a64-bundle.sh [-o output-dir] [--no-tar] [--android] [build directory] [object directory]

set -eo pipefail

absolute() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*) printf '%s\n' "$PWD/$1" ;;
	esac
}

root="$(cd "$(dirname "$0")/.." && pwd)"
out=""
tar=1
android=0
args=()
while [ $# -gt 0 ]; do
	case "$1" in
		-o|--output) out="$2"; shift 2 ;;
		--no-tar) tar=0; shift ;;
		--android) android=1; shift ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) args+=("$1"); shift ;;
	esac
done
build="$(absolute "${args[0]:-$root/target/Linux64}")"
objects="$(absolute "${args[1]:-$root/target/A64/bin}")"
[ -n "$out" ] || out="$root/target/A64/bundle"
out="$(absolute "$out")"

if [ ! -f "$objects/Compiler.GofU8" ] || [ ! -f "$objects/FoxA64Backend.GofU8" ]; then
	echo "no A64 compiler in $objects; run 'task a64-stdlib' first" >&2
	exit 2
fi

# The runtime image, linked here and now rather than picked up from target/A64/img. Images
# lying about in the tree are as old as whenever a check last wanted one, and an image older
# than the objects beside it is the worst kind of stale: it runs, it prints its build date, and
# it fails at whatever was fixed in between. This one cost a run to find out -- an image from
# before module loading was fixed, carrying a loader that traps on the first 26-bit fixup.
#
# The image is the plain runtime: the compiler is not in it, it is loaded from lib/ on the far
# side, which is the thing that only started working when module loading did.
oberon="$build/oberon"
[ -x "$oberon" ] || oberon="$build/oberon.exe"
if [ ! -x "$oberon" ]; then
	echo "no host runtime in $build to link the image with; run 'task oberon' first" >&2
	exit 2
fi

rm -rf "$out"
mkdir -p "$out/lib" "$out/tests"

# For Bionic, Glue is compiled again with --define=ANDROID and the image linked over a directory
# where that object replaces the ordinary one. The objects are linked rather than copied into it,
# except Glue's, which are removed first: the compiler writes through a symbolic link, and writing
# through this one would replace the glibc object in the tree.
link="$objects"
if [ "$android" = 1 ]; then
	link="$(mktemp -d)"
	trap 'rm -rf "$link"' EXIT
	ln -s "$objects"/*.SymU8 "$objects"/*.GofU8 "$link"/
	rm -f "$link/Glue.SymU8" "$link/Glue.GofU8"
	glue=$( (cd "$build" && PWD="$build" "$oberon" do "
		System.DoFile oberon.cfg ~
		Compiler.Compile -p=UnixA64 --define=UNIX,ARM64,ANDROID --destPath='$link/' '$root/source/Linux.Glue.Mod' ~
	") 2>&1 | tr -d '\r' ) || true
	if [ ! -f "$link/Glue.GofU8" ]; then
		echo "Glue did not compile for Android:" >&2
		printf '%s\n' "$glue" | grep -E 'error' | head -10 >&2
		exit 1
	fi
fi

modules=$(sed 's/#.*//' "$root/configs/moduleListLinux.txt" | tr -d '\r' | tr '\n' ' ')
linked=$( (cd "$build" && PWD="$build" "$oberon" do "
	System.DoFile oberon.cfg ~
	Files.SetWorkPath $out ~
	Linker.Link -p=LinuxA64 --path='$link/' --fileName=oberon $modules ~
") 2>&1 | tr -d '\r' ) || true
printf '%s\n' "$linked" | grep -q 'Link successful' || {
	echo "the AArch64 image did not link:" >&2
	printf '%s\n' "$linked" | grep -E 'error' | head -10 >&2 || printf '%s\n' "$linked" | tail -10 >&2
	exit 1
}
image="$out/oberon"

# Copied, not linked: this leaves the tree on a cable or over adb, where a symlink points at
# nothing. It is some 200 MB of objects before compression and a good deal less after.
chmod 755 "$image"
cp -L "$link"/*.SymU8 "$link"/*.GofU8 "$out/lib/"
cp "$root/configs/moduleListLinux.txt" "$out/boot-modules.txt"
install -m 755 "$root/docker/ob" "$out/ob"
install -m 755 "$root/tests/a64-device-suite.sh" "$out/run.sh"
cp "$root"/tests/*.Test "$out/tests/"
cp "$root/tests/a2test-expected-a64.txt" "$out/tests/"
cp "$root"/tests/A64*.Mod "$out/tests/"

# The suites read their baseline as a2test-expected-a64.txt and their cases as *.Test; both are
# in tests/. The .Mod files are there for the checks that compile something on the device.

cat > "$out/README" <<'EOF'
A2 for AArch64 -- a self-contained SDK and its tests.

Needs: a 64-bit ARM machine with a C library (glibc; on Android that means Termux with
proot-distro debian, not Bionic yet) and coreutils. Nothing else -- no Docker, no emulator.

    ./run.sh            everything: boot, collector, module loading, compiling on the device,
                        and the language suites (the long one -- thousands of cases)
    ./run.sh --quick    all of it except the suites
    ./ob build Hello.Mod && ./Hello       build a standalone AArch64 binary, on the machine
    ./ob repl                             the interactive shell

Logs land in results/. `ob` sees that this SDK's runtime is AArch64 and compiles for it
natively; there is no cross target here and no qemu anywhere in the picture.
EOF

echo "bundle: $out ($(du -sh "$out" | cut -f1))"

if [ "$tar" = 1 ]; then
	tarball="$out.tar.gz"
	# --transform so the tarball unpacks into a named directory rather than over the cwd
	tar czf "$tarball" -C "$(dirname "$out")" --transform "s|^$(basename "$out")|a2-a64|" \
		"$(basename "$out")"
	echo "tarball: $tarball ($(du -sh "$tarball" | cut -f1))"
	echo
	echo "on the device:  tar xzf $(basename "$tarball") && cd a2-a64 && ./run.sh"
fi
