#!/usr/bin/env bash
#
# The Win64 bootstrap: compilers/Win64/oberon.exe, cross-linked on Linux.
#
# Why this is a script here and not `task oberon` there. `task oberon` builds the bootstrap for the
# HOST -- it compiles with the committed bootstrap and links with it -- so it can make a Windows one
# only on a Windows machine, and only if there already is a working Windows one. This does the same
# job from Linux with what a Linux host already has: the Win64 objects `task Win64` compiled, and
# the freshly built runtime in target/Linux64, whose linker is the one in this tree rather than the
# one the committed bootstrap was built from.
#
# The freshly built runtime is not a detail. `task Win64` links target/Win64/oberon.exe with the
# HOST bootstrap, so a change to Linker.Mod does not reach any Windows binary until a bootstrap is
# refreshed -- and the bootstrap this writes is what a Windows machine then links everything else
# with.
#
# What makes a bootstrap different from the runtime `task Win64` produces: configs/moduleListWin.txt
# is 27 modules and loads the rest from bin/*.GofWw, while configs/oberon_modules_win.txt is 111 and
# carries Configuration, the compiler and the Fox front and back ends inside the image. It has to:
# it compiles the tree where no object file exists yet, and a fresh checkout is exactly that place.
#
# Usage: tests/win-bootstrap.sh [build directory] [-o out]   (default out: compilers/Win64)

set -eo pipefail

absolute() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$PWD/$1" ;; esac }

root="$(cd "$(dirname "$0")/.." && pwd)"
out=""; args=()
while [ $# -gt 0 ]; do
	case "$1" in
		-o|--output) out="$2"; shift 2 ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) args+=("$1"); shift ;;
	esac
done
build="$(absolute "${args[0]:-$root/target/Linux64}")"
targets="$(dirname "$build")"
winbin="$targets/Win64/bin"
[ -n "$out" ] || out="$root/compilers/Win64"
out="$(absolute "$out")"

oberon="$build/oberon"
[ -x "$oberon" ] || { echo "no built runtime in $build; run 'task Linux64' first" >&2; exit 2; }
[ -d "$winbin" ] || { echo "no Win64 build in $winbin; run 'task Win64' first" >&2; exit 2; }
[ -d "$out" ] || { echo "no such directory: $out" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/winboot.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# DependencyWalker is a build tool and no package ships it, so a platform build has no object for
# it -- but `task oberon` on a Windows host runs it, so the bootstrap has to carry it.
if [ ! -f "$winbin/DependencyWalker.GofWw" ]; then
	"$oberon" do "
		Files.AddSearchPath $build/bin~
		Files.AddSearchPath $winbin~
		Compiler.Compile -p=Win64 --define=WINDOWS,AMD64 --destPath=$winbin/ --objectFileExtension=GofWw --symbolFileExtension=.SymWw $root/source/DependencyWalker.Mod ~
	" > "$work/compile.log" 2>&1 || true
	[ -f "$winbin/DependencyWalker.GofWw" ] || {
		sed 's/^/    /' "$work/compile.log" >&2
		echo "DependencyWalker did not compile for Win64" >&2; exit 1
	}
fi

roots="$(tr -d '\r' < "$root/configs/oberon_modules_win.txt" | grep -v '^[[:space:]]*$' | tr '\n' ' ')"

# Linked in a directory of its own, under the name it will be installed as: the file name is what
# the version resource reports as OriginalFilename, so linking it as oberon.exe.new would say so.
( cd "$work" && "$oberon" do "
	Files.AddSearchPath $build/bin~
	Files.AddSearchPath $winbin~
	Linker.Link --fileFormat=PE64CUI --fileName=oberon.exe --extension=GofWw --displacement=401000H --icon=$root/data/A2.ico
	$roots
	~
" ) > "$work/link.log" 2>&1 || true

[ -f "$work/oberon.exe" ] || {
	sed 's/^/    /' "$work/link.log" >&2
	echo "the Win64 bootstrap did not link" >&2; exit 1
}

install -m 755 "$work/oberon.exe" "$out/oberon.exe"
echo "wrote $out/oberon.exe ($(stat -c %s "$out/oberon.exe") bytes)"
