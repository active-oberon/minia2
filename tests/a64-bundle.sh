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

# CompileForA64 <what it is, for the message> <module> ... -- each from source/<module>.Mod, and every
# one of them has to have produced an object: a set of modules where the first compiles and the second
# does not would otherwise pass for compiled.
#
# A module whose source file is not named after it is written <file>:<module> -- there is one, and it
# is AMD64.WMRasterScale, which carries that prefix for the x86 assembler inside it that no longer
# compiles anywhere (it is commented out in the vanilla tree) and is portable Oberon otherwise.
#
# The modules are compiled in one command and therefore in the order given, which has to be the order
# they import each other in: the compiler reads a symbol file it has just written, not a source file
# it has not reached yet.
CompileForA64() {
	local what="$1"; shift
	local sources="" module file entry said
	for entry in "$@"; do
		file="${entry%%:*}"
		sources="$sources '$root/source/$file.Mod'"
	done
	said=$( (cd "$build" && PWD="$build" "$oberon" do "
		System.DoFile oberon.cfg ~
		Compiler.Compile -p=UnixA64 --destPath='$link/'$sources ~
	") 2>&1 | tr -d '\r' ) || true
	for entry in "$@"; do
		module="${entry##*:}"
		if [ ! -f "$link/$module.GofU8" ]; then
			echo "$what did not compile for AArch64:" >&2
			printf '%s\n' "$said" | grep -E 'error' | head -10 >&2
			exit 1
		fi
	done
}

# Inputs is what A2 calls input: two broadcasters and the messages that go through them. It is not in
# the headless standard library -- a headless SDK has nothing to feed it -- and both bundles want it,
# because DisplayDemo reacts to a mouse whether or not the machine it lands on has one. Into the tree's
# objects, before the Android branch points $link at a directory of links to them, so there is one copy
# and it is there either way.
CompileForA64 Inputs Inputs

# The graphics stack, for the same reason and one more.
#
# The same reason: none of it is in the headless standard library -- docker/headless-core.txt keeps
# Displays out on purpose, and a headless SDK has no screen to give it -- and both bundles want it,
# because both run the picture checks. Displays first of all: the drivers below and the demos above it
# all import it, and until now the only copy of its object anywhere was one left in target/A64/bin by a
# hand-run compile months ago, which is not a thing a bundle should be built out of.
#
# The one more: this is what makes the window on the phone A2's window manager rather than a demo that
# owns the frame buffer. Twelve modules, in the order they import each other.
CompileForA64 "the display registry" Displays

# Two modules from under the graphics stack rather than in it: Codecs imports Texts, Texts imports
# WMEvents, and neither is in the headless standard library -- the SDK image has no text system in it
# either. They compiled here for months without being named, because the objects directory this script
# reads had copies left in it by hand; on a machine where that directory holds only what
# tests/a64-stdlib-check.sh put there -- CI, and anyone else's clone -- Codecs stopped at "could not
# import Texts". Which is the hazard the comment above warns about, arriving one module to the left.
CompileForA64 "the text system Codecs reads through" WMEvents Texts

CompileForA64 "the window manager and what it draws with" \
	WMRectangles Raster AMD64.WMRasterScale:WMRasterScale Codecs WMGraphics WMMessages \
	WMWindowManager WMGraphicUtilities WMDefaultWindows WMDefaultFont WMFontManager WindowManager
CompileForA64 "the window in it" WMDemo

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

	# The display over the window of an application, and the touches of one. Only here, and not in the
	# standard library: neither is of any use anywhere else, and both are loaded at run time rather than
	# linked -- the application unpacks them beside the image.
	CompileForA64 "the display and input drivers for the application" AndroidDisplay AndroidInput
fi

# What draws through a display, whichever one it is, and reacts to whatever mouse there is: in both
# bundles, because it is the check run.sh makes of the picture -- which needs no screen and no window,
# and is therefore the part of a graphics backend that a machine with no display can still answer for.
CompileForA64 DisplayDemo DisplayDemo

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
chmod 755 "$image"

# On Android the image cannot be started by name. Bionic refuses an ET_EXEC outright, and an A2
# image cannot be position independent, so android/a2boot.c maps and enters it instead -- see the
# long comment at the head of that file. It goes in as `oberon` with the image beside it as
# `oberon.img`, which is the arrangement a2boot looks for, and which is what lets `ob`, run.sh and
# everything else go on starting `oberon` and know nothing about any of it.
#
# Built here rather than by hand on the side, because a bundle that needs a step nobody wrote down
# is a bundle that works once.
if [ "$android" = 1 ]; then
	ndk="${ANDROID_NDK:-${NDK:-}}"
	if [ -z "$ndk" ]; then
		# Newest first: the directories sort by version and the last one is the highest.
		for candidate in "$HOME/Android/Sdk/ndk" /data/Android/Sdk/ndk /opt/android-sdk/ndk; do
			[ -d "$candidate" ] || continue
			ndk="$(ls -d "$candidate"/* 2>/dev/null | sort -V | tail -1)"
			[ -n "$ndk" ] && break
		done
	fi
	clang="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android28-clang"
	if [ ! -x "$clang" ]; then
		echo "no NDK compiler for the Android loader: looked for $clang" >&2
		echo "set ANDROID_NDK to an NDK directory (an Android bundle cannot be started without it)" >&2
		exit 2
	fi
	mv "$image" "$out/oberon.img"
	"$clang" -O2 -o "$out/oberon" "$root/android/a2boot.c" || {
		echo "the Android loader did not compile" >&2
		exit 1
	}
	chmod 755 "$out/oberon"
	image="$out/oberon.img"

	# The one check that is about Bionic rather than about AArch64: a process A2 shares with another
	# runtime, and a fault on a thread that is not A2's. It matters here and not at home because on
	# Android the other runtime is always there -- ART catches SIGSEGV for its own nil checks -- and
	# because Bionic is where a wrong struct sigaction goes unreported (see Sigact in Linux.Unix.Mod).
	"$clang" -O2 -Wall -DA2BOOT_NO_MAIN -o "$out/sigchain" \
			"$root/tests/sigchain.c" "$root/android/a2boot.c" || {
		echo "the signal chaining harness did not compile" >&2
		exit 1
	}
	chmod 755 "$out/sigchain"
fi

# Copied, not linked: this leaves the tree on a cable or over adb, where a symlink points at
# nothing. It is some 200 MB of objects before compression and a good deal less after.
cp -L "$link"/*.SymU8 "$link"/*.GofU8 "$out/lib/"
cp "$root/configs/moduleListLinux.txt" "$out/boot-modules.txt"
install -m 755 "$root/docker/ob" "$out/ob"
install -m 755 "$root/tests/a64-device-suite.sh" "$out/run.sh"
cp "$root"/tests/*.Test "$out/tests/"
cp "$root/tests/a2test-expected-a64.txt" "$root/tests/display-expected.txt" "$root/tests/wm-expected.txt" "$out/tests/"
cp "$root"/tests/A64*.Mod "$out/tests/"

# The suites read their baseline as a2test-expected-a64.txt and their cases as *.Test; both are
# in tests/. The .Mod files are there for the checks that compile something on the device.

if [ "$android" = 1 ]; then
	cat > "$out/README" <<'EOF'
A2 for AArch64 on Android -- a self-contained SDK and its tests, against Bionic itself.

Needs: an arm64 Android device and a shell with bash and coreutils. No glibc, no Docker, no
emulator, no root. Two ways to have one:

  - Termux, natively (NOT proot-distro): bash and coreutils are already there.
  - `adb shell` plus a bash of your own. Android ships mksh as /system/bin/sh and no bash, but
    everything else run.sh wants -- timeout, awk, sed, grep, od, realpath -- is in toybox. A bash
    cross-built with the NDK does the rest:

        ./configure --host=aarch64-linux-android --without-bash-malloc --enable-static-link \
            CC=$NDK/.../aarch64-linux-android28-clang ac_cv_func_faccessat=no

    That last one is not optional and the reason is worth knowing: Bionic's faccessat rejects
    AT_EACCESS with EINVAL, and bash 5.2 tests -r, -w and -x through it -- so a bash built without
    it answers "no" to every one of them, for every file, and run.sh reports no runtime beside it.
    Then: adb push bash, and run with PATH and TMPDIR set (Android has no /tmp):

        adb shell "cd <here> && PATH=<here>:\$PATH TMPDIR=<here>/tmp ./bash ./run.sh"

    ./run.sh            everything: boot, collector, module loading, compiling on the device,
                        signal chaining, the picture a display driver is handed, and the language
                        suites (the long one -- thousands of cases)
    ./run.sh --quick    all of it except the suites
    ./ob repl           the interactive shell
    ./ob run Hello.Mod  compile and run, in this process

Getting it onto the phone, from a machine with adb:

    adb push <the tarball> /sdcard/Download/

and then, in Termux (the copy matters -- /sdcard is mounted without execute permission):

    cp /sdcard/Download/<the tarball> ~ && cd ~ && tar xzf <the tarball>
    cd a2-a64 && ./run.sh

`oberon` here is not the image: it is the small loader from android/a2boot.c, and `oberon.img`
beside it is the image it maps and enters. Bionic refuses to start an ET_EXEC and an A2 image
cannot be position independent, so this is the way in; everything above it is unaware of it.
For the same reason `ob build`, which writes a standalone ELF, produces a file that this system
runs but that Android will not start by name -- use `ob run` on the device.

Logs land in results/. `ob` sees that this SDK's runtime is AArch64 and compiles for it
natively; there is no cross target here and no qemu anywhere in the picture.
EOF
else
	cat > "$out/README" <<'EOF'
A2 for AArch64 -- a self-contained SDK and its tests.

Needs: a 64-bit ARM machine with a glibc C library and coreutils. Nothing else -- no Docker, no
emulator. On Android this is the proot-distro debian route; for Bionic itself, build the bundle
with --android, which brings its own way into the image.

    ./run.sh            everything: boot, collector, module loading, compiling on the device,
                        the picture a display driver is handed, and the language suites (the long
                        one -- thousands of cases)
    ./run.sh --quick    all of it except the suites
    ./ob build Hello.Mod && ./Hello       build a standalone AArch64 binary, on the machine
    ./ob repl                             the interactive shell

Logs land in results/. `ob` sees that this SDK's runtime is AArch64 and compiles for it
natively; there is no cross target here and no qemu anywhere in the picture.
EOF
fi

echo "bundle: $out ($(du -sh "$out" | cut -f1))"

if [ "$tar" = 1 ]; then
	tarball="$out.tar.gz"
	# --transform so the tarball unpacks into a named directory rather than over the cwd
	tar czf "$tarball" -C "$(dirname "$out")" --transform "s|^$(basename "$out")|a2-a64|" \
		"$(basename "$out")"
	echo "tarball: $tarball ($(du -sh "$tarball" | cut -f1))"
	echo
	if [ "$android" = 1 ]; then
		# Through /sdcard because Termux cannot read /data/local/tmp, and out of it again because
		# /sdcard is mounted without execute permission.
		echo "to the phone:   adb push $tarball /sdcard/Download/"
		echo "in Termux:      cp /sdcard/Download/$(basename "$tarball") ~ && cd ~ &&" \
			"tar xzf $(basename "$tarball") && cd a2-a64 && ./run.sh"
	else
		echo "on the device:  tar xzf $(basename "$tarball") && cd a2-a64 && ./run.sh"
	fi
fi
