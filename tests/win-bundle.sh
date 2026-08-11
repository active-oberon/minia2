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
# Built on Linux by cross-compilation, which is why it is a script here rather than there.
#
# Usage: tests/win-bundle.sh [build directory] [-o out] [--no-tar]

set -eo pipefail

absolute() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$PWD/$1" ;; esac }

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

oberon="$build/oberon"
[ -x "$oberon" ] || { echo "no built runtime in $build; run 'task Linux64' first" >&2; exit 2; }
[ -d "$winbin" ] || { echo "no Win64 build in $winbin; run 'task Win64' first" >&2; exit 2; }

# JSON, LSP and the A64 backend are not in the Win64 release definition; without them ob.exe does
# not link and a Windows SDK could not run the language server.
"$root/tests/win-stdlib.sh" "$build" >/dev/null

rm -rf "$out"
mkdir -p "$out/lib" "$out/examples" "$out/tests"

# lib/ is this SDK's own platform: the headless core, plus the Windows-only runtime modules, which
# are in the Win boot list rather than in headless-core.txt (that list is the Linux closure).
# WinTrace is in neither and is imported by StdIO, which is why it is named here: without it a
# Windows SDK cannot compile anything that reaches standard output.
copied=0
{ cat "$root/docker/headless-core.txt" "$root/configs/moduleListWin.txt"; echo WinTrace; } | sort -u |
while read -r m; do
	case "$m" in ''|\#*) continue ;; esac
	for e in SymWw GofWw; do
		[ -f "$winbin/$m.$e" ] && install -m 644 "$winbin/$m.$e" "$out/lib/"
	done
done
ls "$out/lib"/*.SymWw >/dev/null 2>&1 || { echo "no Win64 objects found in $winbin" >&2; exit 1; }
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
cp "$root/source/Windows.ObHost.Mod" "$work/ObHost.Mod"
cp "$root/source/Ob.Mod" "$work/"
winboot="$(grep -vE '^(StdIOShell|Shell)$' "$root/configs/moduleListWin.txt" | tr '\n' ' ')"
( cd "$work" && "$oberon" do "
	Files.AddSearchPath $work~
	Files.AddSearchPath $build/bin~
	Files.AddSearchPath $winbin~
	Compiler.Compile -p=Win64 --objectFileExtension=GofWw --symbolFileExtension=.SymWw ./ObHost.Mod ./Ob.Mod ~
	Linker.Link --fileFormat=PE64CUI --extension=GofWw --displacement=401000H --fileName='ob.exe'
	$winboot Ob
	~
" ) > "$work/link.log" 2>&1 || { sed 's/^/    /' "$work/link.log" >&2; echo "ob.exe did not link" >&2; exit 1; }
[ -f "$work/ob.exe" ] || { sed 's/^/    /' "$work/link.log" >&2; echo "ob.exe did not link" >&2; exit 1; }
install -m 755 "$work/ob.exe" "$out/ob.exe"
# Ob and ObHost belong in lib/ too: a project that imports them, and the language server, resolve
# them from there like any other module.
install -m 644 "$work"/Ob.SymWw "$work"/ObHost.SymWw "$out/lib/"

install -m 644 "$root/license.txt" "$out/LICENSE.txt"
cp -r "$root/packages" "$out/packages"
install -m 644 "$root"/docker/examples/*.Mod "$out/examples/"
install -m 644 "$root"/tests/*.Test "$out/tests/"
install -m 644 "$root/tests/a2test-expected.txt" "$out/tests/"
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

Sources, issues and the Docker image: https://github.com/AndriiPuhachenko/minia2
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
