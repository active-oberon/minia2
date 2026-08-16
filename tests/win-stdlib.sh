#!/usr/bin/env bash
#
# Make a Win64 build carry everything the Windows SDK ships -- and say so when it did not.
#
# The list of what it should carry is docker/headless-core-win64.txt plus the Win boot list;
# what it does carry is the .SymWw/.GofWw in target/Win64/bin. On a build made from the current
# tree the two agree and this script does nothing. It exists for the two cases where they don't:
#
#   -  a Win64 build older than the sources. An object compiled before a binding was added to
#      its module compiles everything that does not use the binding and fails only what does --
#      which is how Kernel32 without ObHost's two bindings reads: not as a stale build, but as
#      a bug in Ob. Anything whose source is newer than its object is rebuilt.
#   -  a build that never had the module at all, whatever the reason.
#
# Both are stale-tree cases, so this is a repair, not a step: the honest fix is `task Win64`.
# Whatever it had to fill in is printed, because a build that silently completes itself is how
# the tree drifts from the release definition without anybody noticing. (It was believed for a
# while that JSON, LSP and the A64 backend were missing from the Win64 release definition. They
# are not -- data/Release.Tool has had them since they were written, and a clean `task Win64`
# builds all 727 modules. The tree they were "missing" from was simply months old.)
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

core="$root/docker/headless-core-win64.txt"
[ -f "$core" ] || { echo "no $core; regenerate it with docker/gen-headless-core.sh win64" >&2; exit 2; }

# Where a module's source is, given its module name. The platform prefix is a file-name
# convention, not part of the name: Windows.Kernel32.Mod defines MODULE Kernel32.
source_of() {
	for candidate in "$root/source/$1.Mod" "$root/source/Windows.$1.Mod"; do
		[ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
	done
	return 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/win-stdlib.XXXXXX")"
trap 'rm -rf "$work"' EXIT

missing=""; stale=""
while read -r m; do
	case "$m" in ''|\#*) continue ;; esac
	src="$(source_of "$m")" || continue          # no source here: not ours to build
	# Presence is the symbol file, not the object: a parametric module (GenericCollections,
	# `MODULE M(TYPE T)`) has no code of its own until something instantiates it, so a correct
	# build of it produces a .SymWw and no .GofWw at all.
	if [ ! -f "$winbin/$m.SymWw" ]; then
		missing="$missing $m"
	elif [ "$src" -nt "$winbin/$m.SymWw" ]; then
		stale="$stale $m"
	else
		continue
	fi
	cp "$src" "$work/$m.Mod"
done < <(sort -u "$core" "$root/configs/moduleListWin.txt")

todo="$missing$stale"
if [ -z "$todo" ]; then
	echo "win-stdlib: the Win64 build carries every module the Windows SDK ships"
	exit 0
fi
[ -z "$missing" ] || echo "win-stdlib: not in the Win64 build:$missing"
[ -z "$stale" ]   || echo "win-stdlib: source newer than the object:$stale"
echo "win-stdlib: filling these in -- 'task Win64' is the real fix"

# Order matters and alphabetical is not it. The compiler takes the files in the order it is given
# them and reads a symbol file it has already written, not a source file it has not reached yet, so
# one list in the wrong order stops at the first module that imports a later one -- which is what a
# set of new modules that import each other looks like (Frames imports TerminalCodes, and the two
# arrive together). Rather than order the set, compile it in passes: each pass tries every module
# still left, on its own, and a module whose imports are not built yet simply fails and waits for
# the next one. A pass that builds nothing means the rest cannot be built at all, and says so.
Attempt() {
	( cd "$work" && "$oberon" do "
		Files.AddSearchPath $work~
		Files.AddSearchPath $build/bin~
		Files.AddSearchPath $winbin~
		Files.SetWorkPath $work~
		Compiler.Compile -p=Win64 --objectFileExtension=GofWw --symbolFileExtension=.SymWw ./$1.Mod ~
	" ) > "$work/$1.log" 2>&1
}

left="$todo"
while [ -n "$left" ]; do
	again="" built=0
	for m in $left; do
		if Attempt "$m" && [ -f "$work/$m.SymWw" ]; then built=1; else again="$again $m"; fi
	done
	if [ "$built" = 0 ]; then
		echo "win-stdlib: nothing in this pass compiled, and these are left:$again" >&2
		for m in $again; do grep -E 'error' "$work/$m.log" | head -3 | sed 's/^/    /' >&2; done
		echo "win-stdlib: compilation failed" >&2
		exit 1
	fi
	left="$again"
done

installed=0
for m in $todo; do
	for e in SymWw GofWw; do
		[ -f "$work/$m.$e" ] && { install -m 644 "$work/$m.$e" "$winbin/"; installed=1; }
	done
done
[ "$installed" = 1 ] || { echo "win-stdlib: the compiler produced nothing" >&2; exit 1; }

echo "win-stdlib: $winbin now has $(ls "$winbin"/*.SymWw | wc -l) modules"
