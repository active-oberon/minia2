#!/usr/bin/env bash
#
# Build `ob` for this machine: sdk/Ob.Mod and its Unix host layer, compiled and linked last into
# the boot set without the interactive shell -- Ob's own body is the program, and the compiler and
# the linker are inside it, which is why a verb is a procedure call and not a process.
#
# Two callers want exactly this binary and would otherwise each carry a copy of the recipe: the
# tarball (tests/bundle.sh), which ships it, and the AArch64 suites (tests/a64-suites-check.sh),
# which drive it as the harness. tests/ob-check.sh keeps its own build on purpose -- it is the
# check that interrogates the compile and the link themselves.
#
# What lands in the output directory: ob, Ob.SymUu and ObHost.SymUu. The symbol files are the
# caller's business; a bundle puts them in lib/ so that a project and the language server can
# resolve them like any other module.
#
# Usage: tests/ob-binary.sh <build directory> <output directory>

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:?usage: ob-binary.sh <build directory> <output directory>}"
out="${2:?usage: ob-binary.sh <build directory> <output directory>}"
case "$build" in /*) ;; *) build="$PWD/$build" ;; esac
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac

oberon="$build/oberon"
[ -x "$oberon" ] || oberon="$build/oberon.exe"
[ -x "$oberon" ] || { echo "no runtime in $build to build ob with" >&2; exit 2; }
[ -d "$out" ] || { echo "no such directory: $out" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/obbin.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The sources go in under their MODULE names: a platform-prefixed file compiles to the module's
# name whatever the file is called, but the linker is given module names and looks for objects.
cp "$root/sdk/Unix.ObHost.Mod" "$work/ObHost.Mod"
cp "$root/sdk/Ob.Mod"          "$work/Ob.Mod"

boot="$(grep -vE '^(StdIOShell|Shell)$' "$root/configs/moduleListLinux.txt" | tr -d '\r' | tr '\n' ' ')"
( cd "$work" && "$oberon" do "
	Files.AddSearchPath $work~
	Files.AddSearchPath $build/bin~
	Compiler.Compile -p=Unix64 --objectFileExtension=GofUu --symbolFileExtension=.SymUu ./ObHost.Mod ./Ob.Mod ~
	Linker.Link -p=Linux64 --extension=GofUu --fileName='ob'
	$boot Ob
	~
" ) > "$work/ob.log" 2>&1 || true
[ -f "$work/ob" ] || { sed 's/^/    /' "$work/ob.log" >&2; echo "ob did not link" >&2; exit 1; }

install -m 755 "$work/ob" "$out/ob"
install -m 644 "$work/Ob.SymUu" "$work/ObHost.SymUu" "$out/"
