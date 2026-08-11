#!/usr/bin/env bash
#
# Regenerate the headless core lists — the standard-library modules the SDK ships in lib/,
# one list per target platform:
#
#     docker/headless-core.txt         Linux64  (the image's /opt/a2sdk/lib, and the tarball's)
#     docker/headless-core-win64.txt   Win64    (lib-win64/ in the tarball, lib/ in the Windows SDK)
#
# A module is kept iff its transitive import closure never reaches a GUI root
# (Displays / WindowManager / Raster / Inputs / KbdMouse / WM*). NB: the generic
# `Plugins` driver registry is deliberately NOT a root — network drivers, file
# systems and disks register through it too, so tainting it would wrongly drop
# the whole networking stack (IP/TCP/UDP/DNS/HTTP/...). That
# set is closed under imports, so it is self-consistent for both compilation
# (needs .SymUu of the closure) and dynamic loading (needs .GofUu of the closure).
#
# The two lists are NOT each other's translation. Each platform has modules the other has
# no counterpart for, and one of them cost half a day to find: WinTrace is what StdIO
# imports on Windows, it exists in no Linux closure, and a Win64 lib assembled by filtering
# with the Linux list is missing it — that lib compiles everything that does not print.
#
# Run from the repository root, after the stdlib for that platform has been built:
#     bash docker/gen-headless-core.sh              # both, whichever builds are present
#     bash docker/gen-headless-core.sh linux64      # just one
#
# Requires: the bootstrap compiler (compilers/Linux64/oberon) and python3.
set -euo pipefail
cd "$(dirname "$0")/.."

BOOT=compilers/Linux64/oberon
[ -x "$BOOT" ] || { echo "missing bootstrap compiler $BOOT" >&2; exit 1; }

# platform -> the four things that differ: build directory, compiler defines, object and
# symbol extension, output list. The defines are what DependencyWalker resolves the
# conditional imports with, and they are why the same source yields two different graphs.
generate() {
	local platform="$1" bin defines objext symext out graph
	case "$platform" in
		linux64) bin=target/Linux64/bin; defines=UNIX,AMD64; objext=GofUu; symext=SymUu
		         out=docker/headless-core.txt ;;
		win64)   bin=target/Win64/bin;   defines=WIN,AMD64;  objext=GofWw; symext=SymWw
		         out=docker/headless-core-win64.txt ;;
		*) echo "unknown platform: $platform (linux64, win64)" >&2; return 2 ;;
	esac
	if [ ! -d "$bin" ]; then
		echo "no build in $bin — skipping $platform (build it with: task ${platform/linux64/Linux64})" >&2
		return 0
	fi

	graph="$(mktemp)"
	# 1. Full module dependency graph, via A2's own DependencyWalker.
	AOSPATH=data "$BOOT" DependencyWalker.Walk --define="$defines" --fileExtension=".$objext" \
	    source/*.Mod 2>/dev/null | tr -d '\r' | grep "\.$objext:" > "$graph"

	# 2. Taint-propagate GUI roots; emit the complement (headless-safe) set.
	python3 - "$graph" "$bin" "$out" "$objext" "$symext" <<'PY'
import sys, os, glob
graph, binp, out, objext, symext = sys.argv[1:6]
deps = {}
for line in open(graph):
    lhs, _, rhs = line.strip().partition(":")
    m = lhs[:-len(objext)-1] if lhs.endswith("."+objext) else lhs
    deps[m] = {t[:-len(objext)-1] for t in rhs.split() if t.endswith("."+objext)}
have = {os.path.basename(p)[:-len(symext)-1] for p in glob.glob(binp+"/*."+symext)}
ROOTS = {"Displays","Display","Inputs","KbdMouse","Raster",
         "WindowManager","WMGraphics","WMWindowManager","XDisplay"}
gui = lambda m: m.startswith("WM") or m in ROOTS
sys.setrecursionlimit(10000)
def closure(m, seen):
    for d in deps.get(m, ()):
        if d not in seen:
            seen.add(d); closure(d, seen)
    return seen
keep = sorted(m for m in deps
              if m in have and not any(gui(x) for x in closure(m, {m})))
open(out, "w").write("\n".join(keep) + "\n")
print(f"{os.path.basename(out)}: {len(keep)} modules")
PY
	rm -f "$graph"
}

if [ $# -gt 0 ]; then
	for p in "$@"; do generate "$p"; done
else
	generate linux64
	generate win64
fi
