#!/usr/bin/env bash
#
# Regenerate docker/headless-core.txt — the list of standard-library modules the
# headless SDK image ships in /opt/a2sdk/lib.
#
# A module is kept iff its transitive import closure never reaches a GUI root
# (Displays / WindowManager / Raster / Inputs / KbdMouse / WM*). NB: the generic
# `Plugins` driver registry is deliberately NOT a root — network drivers, file
# systems and disks register through it too, so tainting it would wrongly drop
# the whole networking stack (IP/TCP/UDP/DNS/HTTP/...). That
# set is closed under imports, so it is self-consistent for both compilation
# (needs .SymUu of the closure) and dynamic loading (needs .GofUu of the closure).
#
# Run from the repository root, after the stdlib has been built (target/Linux64/bin):
#     bash docker/gen-headless-core.sh
#
# Requires: the bootstrap compiler (compilers/Linux64/oberon) and python3.
set -euo pipefail
cd "$(dirname "$0")/.."

BOOT=compilers/Linux64/oberon
BIN=target/Linux64/bin
OUT=docker/headless-core.txt
GRAPH="$(mktemp)"

[ -x "$BOOT" ] || { echo "missing bootstrap compiler $BOOT" >&2; exit 1; }
[ -d "$BIN" ]  || { echo "missing built stdlib $BIN (run: task Linux64)" >&2; exit 1; }

# 1. Full module dependency graph, via A2's own DependencyWalker.
AOSPATH=data "$BOOT" DependencyWalker.Walk --define=UNIX,AMD64 --fileExtension=.GofUu \
    source/*.Mod 2>/dev/null | tr -d '\r' | grep '\.GofUu:' > "$GRAPH"

# 2. Taint-propagate GUI roots; emit the complement (headless-safe) set.
python3 - "$GRAPH" "$BIN" "$OUT" <<'PY'
import sys, os, glob
graph, binp, out = sys.argv[1], sys.argv[2], sys.argv[3]
deps = {}
for line in open(graph):
    lhs, _, rhs = line.strip().partition(":")
    m = lhs[:-6] if lhs.endswith(".GofUu") else lhs
    deps[m] = {t[:-6] for t in rhs.split() if t.endswith(".GofUu")}
have = {os.path.basename(p)[:-6] for p in glob.glob(binp+"/*.SymUu")}
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
print(f"headless-core: {len(keep)} modules -> {out}")
PY
rm -f "$GRAPH"
