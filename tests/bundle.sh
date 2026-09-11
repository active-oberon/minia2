#!/usr/bin/env bash
#
# Assemble the SDK as a tarball -- an A2 toolchain that needs no Docker to use. What comes out
# holds what the image holds at /opt/a2sdk, plus `ob`, the examples, the suites and a self-check;
# unpack it anywhere and run ./ob. Same layout as the image and as the AArch64 bundle
# (tests/a64-bundle.sh), because `ob` finds its SDK beside itself and reads the target
# architecture off the runtime's own ELF header -- so one layout serves all three.
#
# Inputs, none of them fetched: target/Linux64 (`task Linux64`, required), target/Win64,
# target/A64/bin, target/Linux32 and target/LinuxARM (the cross targets; without them `ob` says
# the target is unavailable rather than failing mid-link).
#
# With -p the tarball is for another platform than this host: `task Linux32` or `task LinuxARM`
# builds the objects and the runtime, the compiler here writes an `ob` for them, and what comes
# out is a native SDK for that machine -- the old laptop, the Raspberry Pi -- carrying its own
# objects and no cross targets, exactly as the AArch64 bundle does.
#
# With --full lib/ holds the WHOLE build rather than the shipped payload. That is not an SDK to
# give anybody -- it is what the language suites are supposed to run against, here and on a
# board: against the payload a case that imports Raster or JPEGEncoder fails for want of a
# module, which is true of the SDK and says nothing about the compiler. Measured 11.09.2026 on a
# Raspberry Pi: 36 of 81 failures were that and not a defect.
#
# Usage: tests/bundle.sh [-p <platform>] [--full] [-o output-dir] [--no-tar] [build directory]

set -eo pipefail

absolute() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*) printf '%s\n' "$PWD/$1" ;;
	esac
}

root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/tests/platform-env.sh"
out=""
tar=1
full=0
platform=Linux64
args=()
while [ $# -gt 0 ]; do
	case "$1" in
		-o|--output) out="$2"; shift 2 ;;
		-p|--platform) platform="$2"; shift 2 ;;
		--full) full=1; shift ;;
		--no-tar) tar=0; shift ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) args+=("$1"); shift ;;
	esac
done
platform_env "$platform"
obj="$EXTENSION"; sym="${SYMBOLFILEEXCEPTION#.}"
# The host is what runs the compiler; for a cross bundle it is not what the bundle is for.
host="$(absolute "$root/target/Linux64")"
build="$(absolute "${args[0]:-$root/target/$platform}")"

# The override is for the image build: .git is not in the Docker context, so nothing to describe.
version="${A2_SDK_VERSION:-$(git -C "$root" describe --tags --always --dirty 2>/dev/null || echo dev)}"
[ -n "$out" ] || out="$root/target/bundle"
out="$(absolute "$out")"
flavour="$FLAVOUR"                       # from configs/env.yml through tests/platform-env.sh
[ "$full" = 0 ] || flavour="$FLAVOUR-full"
name="minia2-sdk-$version-$flavour"

runtime="$build/oberon"
if [ ! -x "$runtime" ]; then
	echo "no runtime in $build; run 'task $platform' first" >&2
	exit 2
fi
if [ ! -f "$build/bin/Compiler.$sym" ]; then
	echo "no compiler objects in $build/bin; run 'task $platform' first" >&2
	exit 2
fi
if [ ! -x "$host/oberon" ]; then
	echo "no host runtime in $host to build ob with; run 'task Linux64' first" >&2
	exit 2
fi

# A runtime older than its sources is stale in the way that does not announce itself: it runs,
# missing whatever was fixed since. Warned, not refused -- bundling an older build is legitimate.
newest="$(find "$root/source" -name '*.Mod' -newer "$runtime" -print -quit 2>/dev/null || true)"
if [ -n "$newest" ]; then
	echo "warning: $build/oberon is older than $(basename "$newest") and probably others;" >&2
	echo "         'task $platform' first if this bundle is meant to carry the current tree" >&2
fi

rm -rf "$out"
mkdir -p "$out/lib" "$out/lib-sym" "$out/examples" "$out/tests"

# The runtime, its configuration, and the boot module list `ob build` links against.
install -m 755 "$runtime" "$out/oberon"
install -m 644 "$build/oberon.cfg" "$out/oberon.cfg"
install -m 644 "$root/$MODULE_LIST" "$out/boot-modules.txt"

# lib/ is the headless core (configs/headless-core.txt: nothing whose closure reaches the window
# manager, display or raster). lib-sym/ is every symbol file, for the language server, which
# resolves imports to graphical modules it can check but not link.
copied=0
if [ "$full" = 1 ]; then
	install -m 644 "$build"/bin/*."$sym" "$build"/bin/*."$obj" "$out/lib/" && copied=1
else
	while read -r m; do
		case "$m" in ''|\#*) continue ;; esac
		for e in "$sym" "$obj"; do
			[ -f "$build/bin/$m.$e" ] && install -m 644 "$build/bin/$m.$e" "$out/lib/" && copied=1
		done
	done < "$root/$CORELIST"
fi
[ "$copied" = 1 ] || { echo "no $CORELIST objects found in $build/bin" >&2; exit 1; }
install -m 644 "$build"/bin/*."$sym" "$out/lib-sym/"

# lib-gui/ is the display and the events (configs/gui-core.txt), searched only by `ob build --gui`.
# Beside lib/ rather than in it, so that a program that asks for no window still cannot import one
# by accident, and so that the headless payload stays the number the registry says it is.
# Also in --full, and not because lib/ lacks the modules there -- it has all of them. `ob --gui`
# looks for this DIRECTORY and refuses the flag when it is absent, so dropping it from the full
# bundle took the window away from a tarball that carries more, not less. Found on 11.09.2026 by
# the one person using it.
if [ -s "$root/$GUILIST" ]; then
	mkdir -p "$out/lib-gui"
	while read -r m; do
		case "$m" in ''|\#*) continue ;; esac
		for e in "$sym" "$obj"; do
			[ -f "$build/bin/$m.$e" ] && install -m 644 "$build/bin/$m.$e" "$out/lib-gui/"
		done
	done < "$root/$GUILIST"
fi

# The cross targets, each only if its objects are there, looked for beside the build that was
# named -- so a bundle out of another build tree picks up that tree's Win64 and A64. Only the
# x86-64 bundle carries them: a 32-bit or AArch64 SDK is a native one and Ob.Mod refuses a target
# that is not its own, so shipping objects for one would be shipping something unreachable.
targets="$(dirname "$build")"
if [ "$platform" = Linux64 ]; then
if ls "$targets/Win64/bin"/*.SymWw >/dev/null 2>&1; then
	mkdir -p "$out/lib-win64"
	install -m 644 "$root/configs/moduleListWin.txt" "$out/boot-modules-win64.txt"
	# The Win64 core is its own closure (configs/headless-core-win64.txt), not the Linux list with
	# Kernel32 and WinFS added: WinTrace is in no Linux closure and StdIO imports it on Windows,
	# so filtering with the Linux list yields a lib-win64 that compiles everything but printing.
	sort -u "$root/configs/headless-core-win64.txt" "$root/configs/moduleListWin.txt" |
	while read -r m; do
		case "$m" in ''|\#*) continue ;; esac
		for e in SymWw GofWw; do
			[ -f "$targets/Win64/bin/$m.$e" ] && install -m 644 "$targets/Win64/bin/$m.$e" "$out/lib-win64/"
		done
	done
fi
# No filter for A64: that directory is already exactly what a64-stdlib-check.sh compiled.
if ls "$targets/A64/bin"/*.SymU8 >/dev/null 2>&1; then
	mkdir -p "$out/lib-a64"
	install -m 644 "$targets/A64/bin"/*.SymU8 "$targets/A64/bin"/*.GofU8 "$out/lib-a64/"
fi
# The two 32-bit targets, filtered by the same headless core as lib/: their build trees hold the
# whole release, and a cross directory the size of a build tree is not what a tarball is for.
for cross in Linux32:lib-linux32 LinuxARM:lib-arm32; do
	crossPlatform="${cross%%:*}"; crossDir="${cross##*:}"
	( platform_env "$crossPlatform"
	  crossSym="${SYMBOLFILEEXCEPTION#.}"
	  ls "$targets/$crossPlatform/bin"/*."$crossSym" >/dev/null 2>&1 || exit 0
	  mkdir -p "$out/$crossDir"
	  while read -r m; do
		case "$m" in ''|\#*) continue ;; esac
		for e in "$crossSym" "$EXTENSION"; do
			[ -f "$targets/$crossPlatform/bin/$m.$e" ] &&
				install -m 644 "$targets/$crossPlatform/bin/$m.$e" "$out/$crossDir/"
		done
	  done < "$root/$CORELIST" )   # each target's own list: armhf carries FPE64 and the others do not
done
fi

# `ob` itself, built here rather than copied out of sdk/, because it is a binary now (see
# tests/ob-binary.sh). The shell version stays in the tree as the reference tests/ob-check.sh
# measures this one against; it is not shipped, because shipping it would say the shell is still
# needed to use this SDK.
work="$(mktemp -d "${TMPDIR:-/tmp}/bundle-ob.XXXXXX")"
trap 'rm -rf "$work"' EXIT
"$root/tests/ob-binary.sh" -p "$platform" -r "$host" "$build" "$work" || exit 1
install -m 755 "$work/ob" "$out/ob"
# Ob and ObHost belong in the library too: a project that imports them, and the language server,
# resolve them from there like any other module.
install -m 644 "$work"/Ob."$sym" "$work"/ObHost."$sym" "$out/lib/"
install -m 644 "$work"/Ob."$sym" "$work"/ObHost."$sym" "$out/lib-sym/"

# The BSD-3-Clause notice binary redistribution has to carry, the std manifests lint and get
# read, something to compile in the first minute, and the suites -- because a tarball nobody
# can check is a tarball nobody should trust.
install -m 755 "$root/tests/bundle-selfcheck.sh" "$out/run.sh"
install -m 644 "$root/license.txt" "$out/LICENSE.txt"
cp -r "$root/packages" "$out/packages"
install -m 644 "$root"/examples/*.Mod "$out/examples/"
install -m 644 "$root"/tests/*.Test "$out/tests/"
install -m 644 "$root/tests/a2test-expected.txt" "$out/tests/"
printf '%s\n' "$version" > "$out/VERSION"

case "$platform" in
	Linux64)  needs="64-bit x86 Linux with a glibc C library" ;;
	Linux32)  needs="32-bit x86 Linux with a glibc C library (an i686 machine, or a 64-bit
one with the 32-bit libraries installed)" ;;
	LinuxARM) needs="32-bit ARM Linux with a hard-float glibc C library -- Raspberry Pi OS
on a Pi 1, 2 or Zero" ;;
	*)        needs="a Linux with a glibc C library" ;;
esac
[ "$full" = 0 ] || needs="$needs. This one carries the WHOLE build in lib/, not the shipped
payload: it is for running the language suites, not for giving anybody"

# Three pieces, and each heredoc that carries prose is quoted: the prose is full of backticks
# and of $PWD, and an unquoted one runs them.
{
	printf '%s\n' \
		"A2 / Active Oberon SDK -- the compiler, the standard library and the language server, in one" \
		"directory. No Docker, no installer, no daemon, nothing written outside this directory." \
		"" \
		"Needs: $needs."
	cat <<'EOF'
That is the whole list -- `ob` is a binary with the compiler and
the linker inside it, not a script. `ob get` additionally wants git, and run.sh below is
bash; every verb works without either.

    ./ob version                      what this SDK is and which targets it has
    ./ob run examples/Hello.Mod       compile and run, in one step
    ./ob build examples/Hello.Mod     a standalone ELF with the runtime baked in
    ./ob repl                         the interactive A2 shell
    ./ob test                         the language suites (thousands of cases)
    ./run.sh                          check this SDK works: every verb, then the suites
    ./run.sh --quick                  the same without the suites

To have `ob` on the PATH without moving anything, link it -- `ob` follows the link back to
this directory and finds its runtime there:

    mkdir -p ~/.local/bin && ln -sf "$PWD/ob" ~/.local/bin/ob

That is all install.sh does, if you would rather it did the downloading too:

    curl -fsSL https://raw.githubusercontent.com/active-oberon/minia2/main/sdk/install.sh | sh

Editors: `ob lsp` speaks LSP over stdio (diagnostics, hover, go-to-definition, completion,
signature help, references, outline, semantic tokens, rename, formatting, code actions).
Point your editor's Active Oberon client at the absolute path of `ob` with the argument `lsp`
-- for Neovim, `cmd = { "/path/to/ob", "lsp" }`.

EOF
	if [ "$platform" = Linux64 ]; then
		cat <<'EOF'
Cross targets, if this bundle carries their objects (`ob version` says which):

    ./ob build examples/Hello.Mod -t win64 -o hello.exe    a Windows PE64 console .exe
    ./ob build examples/Hello.Mod -t a64 -o hello-arm64    an AArch64 ELF (Pi 4/5, ARM server)
    ./ob build examples/Hello.Mod -t linux32 -o hello32    a 32-bit x86 ELF
    ./ob build examples/Hello.Mod -t arm32 -o hello-armhf  an armhf ELF (Pi 1/2/Zero)

For a machine that is itself one of those -- a board, a phone under Termux, the old laptop --
take that machine's own bundle instead: there the architecture is not a cross target but the
native one, and the compiler runs on the device.

EOF
	else
		cat <<'EOF'
This is a native SDK: the compiler runs on the machine it compiles for, and there are no
cross targets in it. `ob build` writes a binary for this machine and nothing else, and
`ob version` says so.

EOF
	fi
	cat <<'EOF'
Sources, issues and the Docker image: https://github.com/active-oberon/minia2
A2 is BSD-3-Clause, ETH Zurich -- see LICENSE.txt.
EOF
} > "$out/README"

echo "bundle: $out ($(du -sh "$out" | cut -f1))"
echo "  version : $version"
echo "  stdlib  : $(ls "$out/lib"/*."$sym" | wc -l) modules ($OBTARGET), $(ls "$out/lib-sym"/*."$sym" | wc -l) symbols for the language server"
[ -d "$out/lib-gui" ] && echo "  gui     : $(ls "$out/lib-gui"/*."$sym" | wc -l) modules for ob build --gui"
[ -d "$out/lib-win64" ] && echo "  win64   : $(ls "$out/lib-win64"/*.SymWw | wc -l) modules"
[ -d "$out/lib-a64" ] && echo "  a64     : $(ls "$out/lib-a64"/*.SymU8 | wc -l) modules"
[ -d "$out/lib-linux32" ] && echo "  linux32 : $(ls "$out/lib-linux32"/*.SymU | wc -l) modules"
[ -d "$out/lib-arm32" ] && echo "  arm32   : $(ls "$out/lib-arm32"/*.SymA | wc -l) modules"

if [ "$tar" = 1 ]; then
	tarball="$(dirname "$out")/$name.tar.gz"
	# --transform: unpack into a named directory rather than over the cwd
	tar czf "$tarball" -C "$(dirname "$out")" --transform "s|^$(basename "$out")|$name|" \
		"$(basename "$out")"
	# The ones from before. A tarball is twenty-three megabytes and one is made per build, so a
	# fortnight of work leaves a third of a gigabyte of tarballs nobody will ever unpack again.
	# Only this flavour's are touched -- the Windows and AArch64 tarballs are made elsewhere and
	# are not this run's to remove. KEEP_TARBALLS=1 keeps them all, for comparing two builds.
	if [ -z "$KEEP_TARBALLS" ]; then
		removed=0
		for old in "$(dirname "$out")"/minia2-sdk-*-"$flavour".tar.gz; do
			[ -f "$old" ] || continue
			[ "$old" = "$tarball" ] && continue
			rm -f "$old"; removed=$((removed + 1))
		done
		[ "$removed" = 0 ] || echo "removed $removed earlier $flavour tarball(s); KEEP_TARBALLS=1 keeps them"
	fi
	echo "tarball: $tarball ($(du -sh "$tarball" | cut -f1))"
	echo
	echo "to use:  tar xzf $(basename "$tarball") && cd $name && ./run.sh --quick"
fi
