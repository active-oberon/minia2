#!/usr/bin/env bash
#
# Assemble the SDK as a tarball -- an A2 toolchain that needs no Docker to use. What comes out
# holds what the image holds at /opt/a2sdk, plus `ob`, the examples, the suites and a self-check;
# unpack it anywhere and run ./ob. Same layout as the image and as the AArch64 bundle
# (tests/a64-bundle.sh), because `ob` finds its SDK beside itself and reads the target
# architecture off the runtime's own ELF header -- so one layout serves all three.
#
# Inputs, none of them fetched: target/Linux64 (`task Linux64`, required), target/Win64 and
# target/A64/bin (the cross targets; without them `ob` says the target is unavailable rather
# than failing mid-link).
#
# Usage: tests/bundle.sh [-o output-dir] [--no-tar] [build directory]

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
args=()
while [ $# -gt 0 ]; do
	case "$1" in
		-o|--output) out="$2"; shift 2 ;;
		--no-tar) tar=0; shift ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) args+=("$1"); shift ;;
	esac
done
build="$(absolute "${args[0]:-$root/target/Linux64}")"

# The override is for the image build: .git is not in the Docker context, so nothing to describe.
version="${A2_SDK_VERSION:-$(git -C "$root" describe --tags --always --dirty 2>/dev/null || echo dev)}"
[ -n "$out" ] || out="$root/target/bundle"
out="$(absolute "$out")"
name="minia2-sdk-$version-linux-amd64"

runtime="$build/oberon"
if [ ! -x "$runtime" ]; then
	echo "no runtime in $build; run 'task Linux64' first" >&2
	exit 2
fi
if [ ! -f "$build/bin/Compiler.SymUu" ]; then
	echo "no compiler objects in $build/bin; run 'task Linux64' first" >&2
	exit 2
fi

# A runtime older than its sources is stale in the way that does not announce itself: it runs,
# missing whatever was fixed since. Warned, not refused -- bundling an older build is legitimate.
newest="$(find "$root/source" -name '*.Mod' -newer "$runtime" -print -quit 2>/dev/null || true)"
if [ -n "$newest" ]; then
	echo "warning: $build/oberon is older than $(basename "$newest") and probably others;" >&2
	echo "         'task Linux64' first if this bundle is meant to carry the current tree" >&2
fi

rm -rf "$out"
mkdir -p "$out/lib" "$out/lib-sym" "$out/examples" "$out/tests"

# The runtime, its configuration, and the boot module list `ob build` links against.
install -m 755 "$runtime" "$out/oberon"
install -m 644 "$build/oberon.cfg" "$out/oberon.cfg"
install -m 644 "$root/configs/moduleListLinux.txt" "$out/boot-modules.txt"

# lib/ is the headless core (docker/headless-core.txt: nothing whose closure reaches the window
# manager, display or raster). lib-sym/ is every symbol file, for the language server, which
# resolves imports to graphical modules it can check but not link.
copied=0
while read -r m; do
	case "$m" in ''|\#*) continue ;; esac
	for e in SymUu GofUu; do
		[ -f "$build/bin/$m.$e" ] && install -m 644 "$build/bin/$m.$e" "$out/lib/" && copied=1
	done
done < "$root/docker/headless-core.txt"
[ "$copied" = 1 ] || { echo "no headless-core objects found in $build/bin" >&2; exit 1; }
install -m 644 "$build"/bin/*.SymUu "$out/lib-sym/"

# The cross targets, each only if its objects are there, looked for beside the build that was
# named -- so a bundle out of another build tree picks up that tree's Win64 and A64.
targets="$(dirname "$build")"
if ls "$targets/Win64/bin"/*.SymWw >/dev/null 2>&1; then
	mkdir -p "$out/lib-win64"
	install -m 644 "$root/configs/moduleListWin.txt" "$out/boot-modules-win64.txt"
	# The Win64 core is its own closure (docker/headless-core-win64.txt), not the Linux list with
	# Kernel32 and WinFS added: WinTrace is in no Linux closure and StdIO imports it on Windows,
	# so filtering with the Linux list yields a lib-win64 that compiles everything but printing.
	sort -u "$root/docker/headless-core-win64.txt" "$root/configs/moduleListWin.txt" |
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

# `ob` itself, built here rather than copied out of sdk/, because it is a binary now: Ob.Mod and
# its Unix host layer, compiled and linked last into the boot set without the interactive shell --
# Ob's own body is the program, and the compiler and the linker are inside it. The shell version
# stays in the tree as the reference tests/ob-check.sh measures this one against; it is not
# shipped, because shipping it would say the shell is still needed to use this SDK.
work="$(mktemp -d "${TMPDIR:-/tmp}/bundle-ob.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp "$root/sdk/Unix.ObHost.Mod" "$work/ObHost.Mod"
cp "$root/sdk/Ob.Mod" "$work/"
boot="$(grep -vE '^(StdIOShell|Shell)$' "$root/configs/moduleListLinux.txt" | tr -d '\r' | tr '\n' ' ')"
( cd "$work" && "$runtime" do "
	Files.AddSearchPath $work~
	Files.AddSearchPath $build/bin~
	Compiler.Compile -p=Unix64 --objectFileExtension=GofUu --symbolFileExtension=.SymUu ./ObHost.Mod ./Ob.Mod ~
	Linker.Link -p=Linux64 --extension=GofUu --fileName='ob'
	$boot Ob
	~
" ) > "$work/ob.log" 2>&1 || true
[ -f "$work/ob" ] || { sed 's/^/    /' "$work/ob.log" >&2; echo "ob did not link" >&2; exit 1; }
install -m 755 "$work/ob" "$out/ob"
# Ob and ObHost belong in the library too: a project that imports them, and the language server,
# resolve them from there like any other module.
install -m 644 "$work"/Ob.SymUu "$work"/ObHost.SymUu "$out/lib/"
install -m 644 "$work"/Ob.SymUu "$work"/ObHost.SymUu "$out/lib-sym/"

# The BSD-3-Clause notice binary redistribution has to carry, the std manifests lint and get
# read, something to compile in the first minute, and the suites -- because a tarball nobody
# can check is a tarball nobody should trust.
install -m 755 "$root/tests/bundle-selfcheck.sh" "$out/run.sh"
install -m 644 "$root/license.txt" "$out/LICENSE.txt"
cp -r "$root/packages" "$out/packages"
install -m 644 "$root"/docker/examples/*.Mod "$out/examples/"
install -m 644 "$root"/tests/*.Test "$out/tests/"
install -m 644 "$root/tests/a2test-expected.txt" "$out/tests/"
printf '%s\n' "$version" > "$out/VERSION"

cat > "$out/README" <<'EOF'
A2 / Active Oberon SDK -- the compiler, the standard library and the language server, in one
directory. No Docker, no installer, no daemon, nothing written outside this directory.

Needs: 64-bit x86 Linux with a glibc C library. That is the whole list -- `ob` is a binary
with the compiler and the linker inside it, not a script. `ob get` additionally wants git,
and run.sh below is bash; every verb works without either.

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

Cross targets, if this bundle carries their objects (`ob version` says which):

    ./ob build examples/Hello.Mod -t win64 -o hello.exe    a Windows PE64 console .exe
    ./ob build examples/Hello.Mod -t a64 -o hello-arm64    an AArch64 ELF (Pi 4/5, ARM server)

For a machine that is itself AArch64 -- a board, a phone under Termux -- take the AArch64
bundle instead (tests/a64-bundle.sh in the source tree): there a64 is not a cross target but
the native one, and the compiler runs on the device.

Sources, issues and the Docker image: https://github.com/active-oberon/minia2
A2 is BSD-3-Clause, ETH Zurich -- see LICENSE.txt.
EOF

echo "bundle: $out ($(du -sh "$out" | cut -f1))"
echo "  version : $version"
echo "  stdlib  : $(ls "$out/lib"/*.SymUu | wc -l) modules (linux64), $(ls "$out/lib-sym"/*.SymUu | wc -l) symbols for the language server"
[ -d "$out/lib-win64" ] && echo "  win64   : $(ls "$out/lib-win64"/*.SymWw | wc -l) modules"
[ -d "$out/lib-a64" ] && echo "  a64     : $(ls "$out/lib-a64"/*.SymU8 | wc -l) modules"

if [ "$tar" = 1 ]; then
	tarball="$(dirname "$out")/$name.tar.gz"
	# --transform: unpack into a named directory rather than over the cwd
	tar czf "$tarball" -C "$(dirname "$out")" --transform "s|^$(basename "$out")|$name|" \
		"$(basename "$out")"
	echo "tarball: $tarball ($(du -sh "$tarball" | cut -f1))"
	echo
	echo "to use:  tar xzf $(basename "$tarball") && cd $name && ./run.sh --quick"
fi
