#!/usr/bin/env bash
#
# The Windows SDK: ob.exe, the standard library it compiles against, and nothing else needed.
#
# This is the third host, beside tests/bundle.sh (x86-64 Linux) and tests/a64-bundle.sh (AArch64).
# What makes it possible at all is that `ob` is no longer a shell script: the driver is Ob.Mod,
# linked into a Win64 binary together with the compiler and the linker, so a Windows machine needs
# neither bash nor WSL nor Docker.
#
# Two things this bundle does NOT carry, on purpose:
#
#   -  the bash `ob`. Shipping it would say the shell is still needed, and it is not.
#   -  run.sh, the in-bundle self-check, which is bash. What answers for this SDK is
#      `tests/ob-check.sh` in the source tree, which builds ob.exe and drives it under wine.
#
# Built on Linux by cross-compilation -- which is why it is a script here rather than in the
# bundle -- and, since 07.09.2026, on Windows itself with the Win64 runtime as the driver: that is
# the only way to measure the Windows side of anything, and Git's bash is enough to run this.
#
# Usage: tests/win-bundle.sh [build directory] [-o out] [--no-tar]

set -eo pipefail

# A drive letter is absolute too, which matters when this runs in Git's bash on Windows.
absolute() { case "$1" in /*|[A-Za-z]:*) printf '%s\n' "$1" ;; *) printf '%s\n' "$PWD/$1" ;; esac }

root="$(cd "$(dirname "$0")/.." && pwd)"
out=""; tar=1; args=()
while [ $# -gt 0 ]; do
	case "$1" in
		-o|--output) out="$2"; shift 2 ;;
		--no-tar) tar=0; shift ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) args+=("$1"); shift ;;
	esac
done
build="$(absolute "${args[0]:-$root/target/Linux64}")"
targets="$(dirname "$build")"
winbin="$targets/Win64/bin"

version="${A2_SDK_VERSION:-$(git -C "$root" describe --tags --always --dirty 2>/dev/null || echo dev)}"
[ -n "$out" ] || out="$root/target/bundle-win64"
out="$(absolute "$out")"
name="minia2-sdk-$version-windows-amd64"

# The driver: the Linux runtime when there is one, and the Win64 one when this is running ON
# Windows -- which is the only way to measure the Windows side of anything (Git's bash is enough
# for the script itself; there is no WSL in it). The two differ in one thing that matters, and it
# is not the compiler: an A2 process on Windows moves to its own image's directory before anything
# runs (WinFS.Init ends in SetCurrentDirectory), so a relative output name lands beside the runtime
# rather than in the shell's directory, and the outputs are collected from there. An absolute
# --destPath is no way round it either: with one given, the compiler looks for the imports' symbol
# files in that directory and nowhere else.
# Which host this is, asked of the shell and not of the file system: a `test -x` for the Linux
# runtime answers TRUE under Git's bash whenever the Windows one is beside it, because MSYS adds
# the .exe itself.
case "$(uname -s)" in
	MINGW*|MSYS*|CYGWIN*)
		native=1; oberon="$targets/Win64/oberon.exe"
		# Every path handed to the A2 runtime has to be a Windows path: the shell's own are
		# /i/Projects/..., which nothing inside the image can resolve.
		winpath() { cygpath -m "$1"; }
		# GNU tar's --transform is not in every tar a Windows machine has; there the tarball is
		# made only when it is asked for.
		[ -z "$A2_WIN_TAR" ] && tar=0
		;;
	*)
		native=0; oberon="$build/oberon"
		winpath() { printf '%s
' "$1"; }
		;;
esac
[ -x "$oberon" ] || { echo "no built runtime in $build; run 'task Linux64' -- or 'task Win64' on Windows -- first" >&2; exit 2; }
[ -d "$winbin" ] || { echo "no Win64 build in $winbin; run 'task Win64' first" >&2; exit 2; }

# A Win64 build that is older than the sources ships whatever was fixed since as it was; this
# says so, and compiles the modules the SDK ships that the build has no object for.
if [ "$native" = 0 ]; then "$root/tests/win-stdlib.sh" "$build" >/dev/null; fi

rm -rf "$out"
mkdir -p "$out/lib" "$out/examples" "$out/tests"

# lib/ is this SDK's own platform: the Win64 headless core (configs/headless-core-win64.txt --
# its own closure, not a translation of the Linux one, which is how WinTrace gets in: StdIO
# imports it on Windows and no Linux closure has ever heard of it).
copied=0
sort -u "$root/configs/headless-core-win64.txt" "$root/configs/moduleListWin.txt" |
while read -r m; do
	case "$m" in ''|\#*) continue ;; esac
	for e in SymWw GofWw; do
		[ -f "$winbin/$m.$e" ] && install -m 644 "$winbin/$m.$e" "$out/lib/"
	done
done
ls "$out/lib"/*.SymWw >/dev/null 2>&1 || { echo "no Win64 objects found in $winbin" >&2; exit 1; }

# lib-gui/ is the display and the events (configs/gui-core-win64.txt), searched only by
# `ob build --gui`, which is host-only -- so on this SDK it is the Win64 half. NOT YET RUN on
# Windows: the list is derived the same way as the Linux one and the objects are copied the same
# way, but no windowed binary has been built there.
if [ -s "$root/configs/gui-core-win64.txt" ]; then
	mkdir -p "$out/lib-gui"
	while read -r m; do
		case "$m" in ''|\#*) continue ;; esac
		for e in SymWw GofWw; do
			[ -f "$winbin/$m.$e" ] && install -m 644 "$winbin/$m.$e" "$out/lib-gui/"
		done
	done < "$root/configs/gui-core-win64.txt"
fi
install -m 644 "$root/configs/moduleListWin.txt" "$out/boot-modules-win64.txt"

# The AArch64 objects come along so that a teacher on Windows can build for a Raspberry Pi. The
# linux64 target deliberately does not: lib/ here is Win64, and Ob refuses a target whose objects
# are absent rather than linking the wrong ones.
if ls "$targets/A64/bin"/*.SymU8 >/dev/null 2>&1; then
	mkdir -p "$out/lib-a64"
	install -m 644 "$targets/A64/bin"/*.SymU8 "$targets/A64/bin"/*.GofU8 "$out/lib-a64/"
	install -m 644 "$root/configs/moduleListLinux.txt" "$out/boot-modules.txt"
fi

# ob.exe itself: Ob and its Windows host layer, compiled for Win64 and linked last into the boot
# set without the interactive shell -- Ob's own body is the program.
work="$(mktemp -d "${TMPDIR:-/tmp}/win-bundle.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp "$root/sdk/Windows.ObHost.Mod" "$work/ObHost.Mod"
cp "$root/sdk/Ob.Mod" "$work/"
winboot="$(grep -vE '^(StdIOShell|Shell)$' "$root/configs/moduleListWin.txt" | tr '\n' ' ')"
if [ "$native" = 1 ]; then
	made="$targets/Win64"
	obsources="$(winpath "$work")/ObHost.Mod $(winpath "$work")/Ob.Mod"
else
	made="$work"
	obsources="./ObHost.Mod ./Ob.Mod"
fi
rm -f "$made"/ob.exe "$made"/ob.log "$made"/Ob.SymWw "$made"/Ob.GofWw "$made"/ObHost.SymWw "$made"/ObHost.GofWw
( cd "$work" && "$oberon" do "
	Files.AddSearchPath $(winpath "$work")~
	Files.AddSearchPath $(winpath "$build")/bin~
	Files.AddSearchPath $(winpath "$winbin")~
	Compiler.Compile -p=Win64 --objectFileExtension=GofWw --symbolFileExtension=.SymWw $obsources ~
	Linker.Link --fileFormat=PE64CUI --extension=GofWw --displacement=401000H --fileName='ob.exe'
	$winboot Ob
	~
" ) > "$work/link.log" 2>&1 || { sed 's/^/    /' "$work/link.log" >&2; echo "ob.exe did not link" >&2; exit 1; }
[ -f "$made/ob.exe" ] || { sed 's/^/    /' "$work/link.log" >&2; echo "ob.exe did not link" >&2; exit 1; }
# A linked ob.exe over a module that did not compile is the shape that cost a cycle in `task Win64`
# once, and the log is where it says so on both hosts.
grep -qE 'error:' "$work/link.log" && { sed 's/^/    /' "$work/link.log" >&2; echo "the compiler reported errors" >&2; exit 1; }
install -m 755 "$made/ob.exe" "$out/ob.exe"
# Ob and ObHost belong in lib/ too: a project that imports them, and the language server, resolve
# them from there like any other module.
install -m 644 "$made"/Ob.SymWw "$made"/ObHost.SymWw "$out/lib/"
if [ "$native" = 1 ]; then
	rm -f "$made"/ob.exe "$made"/ob.log "$made"/Ob.SymWw "$made"/Ob.GofWw "$made"/ObHost.SymWw "$made"/ObHost.GofWw
fi

install -m 644 "$root/license.txt" "$out/LICENSE.txt"
cp -r "$root/packages" "$out/packages"
install -m 644 "$root"/examples/*.Mod "$out/examples/"
install -m 644 "$root"/tests/*.Test "$out/tests/"
# Both baselines: `ob test` on this SDK looks for the one named after its own target
# (a2test-expected-win64.txt), and the plain one is what a run with -t linux64 would want.
install -m 644 "$root/tests/a2test-expected.txt" "$root/tests/a2test-expected-win64.txt" "$out/tests/"
printf '%s\n' "$version" > "$out/VERSION"

cat > "$out/README.txt" <<'EOF'
A2 / Active Oberon SDK for Windows -- the compiler, the standard library and the language
server, in one directory. No WSL, no bash, no Docker, no installer, nothing written outside
this directory.

Needs: 64-bit Windows. That is the whole list.

    ob.exe version                  what this SDK is and which targets it has
    ob.exe run examples\Hello.Mod   compile and run, in one step
    ob.exe build examples\Hello.Mod a standalone .exe with the runtime baked in
    ob.exe repl                     the interactive A2 shell
    ob.exe test                     the language suites (thousands of cases)
    ob.exe help                     every verb

ob.exe finds this directory by looking beside itself, so it can be put on the PATH or called
by its full path; nothing has to be set.

Editors: `ob.exe lsp` speaks LSP over stdio (diagnostics, hover, go-to-definition, completion,
signature help, references, outline, semantic tokens, rename, formatting, code actions). Point
your editor's Active Oberon client at the full path of ob.exe with the argument `lsp`.

Cross target, if this bundle carries its objects (`ob.exe version` says so):

    ob.exe build examples\Hello.Mod -t a64 -o hello-arm64    an AArch64 ELF (Pi 4/5, ARM server)

Linux is not a target from here: this SDK ships Windows objects, and ob.exe refuses a target
whose objects it does not have rather than linking the wrong ones. Take the Linux bundle for that.

Sources, issues and the Docker image: https://github.com/active-oberon/minia2
A2 is BSD-3-Clause, ETH Zurich -- see LICENSE.txt.
EOF

echo "win-bundle: $out ($(du -sh "$out" | cut -f1))"
echo "  version : $version"
echo "  stdlib  : $(ls "$out/lib"/*.SymWw | wc -l) modules (win64)"
[ -d "$out/lib-a64" ] && echo "  a64     : $(ls "$out/lib-a64"/*.SymU8 | wc -l) modules"

if [ "$tar" = 1 ]; then
	tarball="$(dirname "$out")/$name.tar.gz"
	tar czf "$tarball" -C "$(dirname "$out")" --transform "s|^$(basename "$out")|$name|" \
		"$(basename "$out")"
	echo "tarball: $tarball ($(du -sh "$tarball" | cut -f1))"
fi
