#!/usr/bin/env bash
#
# Fill in the modules a Windows SDK needs and `task Win64` does not build.
#
# The Win64 release list is not the headless core: of the 387 modules in docker/headless-core.txt,
# eleven have no .SymWw after a Win64 build. Six of them should not have one --
#
#     Glue, Unix, UnixFiles, UnixBinary, Sockets, X11   -- Unix by nature
#
# -- and the other five are portable code that simply is not in the Win64 release definition:
#
#     JSON, LSP                                          -- the language server and what it speaks
#     FoxA64InstructionSet, FoxA64Assembler, FoxA64Backend  -- so a Windows SDK can build for AArch64
#
# This compiles those five into the Win64 build directory, in dependency order. It is the Windows
# counterpart of tests/a64-stdlib-check.sh and exists for the same reason: a target's release list
# and the SDK's shipping list are not the same list.
#
# Usage: tests/win-stdlib.sh [build directory]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
case "$build" in /*) ;; *) build="$PWD/$build" ;; esac
targets="$(dirname "$build")"
winbin="$targets/Win64/bin"

oberon="$build/oberon"
[ -x "$oberon" ] || { echo "no built runtime in $build; run 'task Linux64' first" >&2; exit 2; }
[ -d "$winbin" ]  || { echo "no Win64 build in $winbin; run 'task Win64' first" >&2; exit 2; }

# Dependency order, not alphabetical: the A64 backend is three modules deep and LSP imports JSON.
# Kernel32 is here for a different reason -- it exists in the Win64 build already, but ObHost needs
# bindings added to it after that build was made, so it is rebuilt whenever its source is newer.
modules="Kernel32 JSON FoxA64InstructionSet FoxA64Assembler FoxA64Backend LSP"

work="$(mktemp -d "${TMPDIR:-/tmp}/win-stdlib.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# A module is (re)built when it has no object, or when its source is newer than the object it has.
# The second case is not hypothetical: an object built before a binding was added to it compiles
# everything that does not use the binding, and fails only the module that does.
source_of() {
	for candidate in "$root/source/$1.Mod" "$root/source/Windows.$1.Mod"; do
		[ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
	done
	return 1
}
todo=""
for m in $modules; do
	src="$(source_of "$m")" || { echo "no source for $m" >&2; exit 1; }
	if [ -f "$winbin/$m.SymWw" ] && [ -f "$winbin/$m.GofWw" ] && [ ! "$src" -nt "$winbin/$m.SymWw" ]; then
		continue
	fi
	cp "$src" "$work/$m.Mod"
	todo="$todo ./$m.Mod"
done

if [ -z "$todo" ]; then
	echo "win-stdlib: nothing to do, all $(echo $modules | wc -w) modules are already built for Win64"
	exit 0
fi

# Compiled in the scratch directory and installed afterwards, so a failure leaves the build tree
# as it was rather than half-filled.
( cd "$work" && "$oberon" do "
	Files.AddSearchPath $work~
	Files.AddSearchPath $build/bin~
	Files.AddSearchPath $winbin~
	Files.SetWorkPath $work~
	Compiler.Compile -p=Win64 --objectFileExtension=GofWw --symbolFileExtension=.SymWw$todo ~
" ) || { echo "win-stdlib: compilation failed" >&2; exit 1; }

installed=0
for m in $modules; do
	for e in SymWw GofWw; do
		[ -f "$work/$m.$e" ] && { install -m 644 "$work/$m.$e" "$winbin/"; installed=1; }
	done
done
[ "$installed" = 1 ] || { echo "win-stdlib: the compiler produced nothing" >&2; exit 1; }

echo "win-stdlib: $winbin now has $(ls "$winbin"/*.SymWw | wc -l) modules"
