#!/usr/bin/env bash
#
# Regenerate the headless core lists — the standard-library modules the SDK ships in lib/,
# one list per target platform:
#
#     docker/headless-core.txt         Linux64  (the image's /opt/a2sdk/lib, and the tarball's)
#     docker/headless-core-win64.txt   Win64    (lib-win64/ in the tarball, lib/ in the Windows SDK)
#
# WHAT DECIDES MEMBERSHIP
#
# The registry does: packages/*/*/a2pkg.json. A module is shipped iff some package whose
# `headless` is true names it in `provides` and does not name it in `graphical`, or iff the
# import closure of such a module needs it. packages/attic/* is where the tree's other languages
# and other machines are declared -- `headless` false, `status` unsupported, in source/ but not
# ours: the Oberon-2 compiler, the ActiveCells# front end, the TRM and interpreter back ends,
# the 32-bit ARM back end. Nothing else. The list is therefore a decision
# that somebody wrote down, package by package, and this script only works it out.
#
# It did not used to be. The rule was the other way round -- keep every module whose import
# closure never reaches the window system -- and that is a filter for "not graphics", not for
# "ours". It let through everything headless that happens to sit in the tree: a Samba server, a
# TV tuner driver, a Fidonet client, an OGG player, the C# front end of a language nobody here
# compiles. 393 modules of which 144 were nobody's.
#
# Two things the negative rule could not see, and this one can:
#
#   -  A module loaded BY NAME at run time is imported by nothing, so an import graph cannot tell
#      FoxOberonFrontend from FoxCSharpFrontend: both are roots, both are reachable from nothing.
#      A package saying "I provide this" can.
#   -  A module that belongs to a package we ship but cannot go in a headless payload, because its
#      own closure reaches the window system -- SSH, the decoders. That is the `graphical` list in
#      the manifest, and it is CHECKED here: a module named there that turns out to be
#      headless-clean, or one not named there that reaches the window system, is an error. The
#      annotation cannot rot quietly.
#   -  Two packages importing each other. `requires` is derived from the import graph, so a cycle
#      between packages is visible, and it means the boundary is in the wrong place. A pair that
#      genuinely cannot be split declares itself in `cycle` on both sides; an undeclared one is an
#      error.
#
# The window system is Displays / WindowManager / Raster / Inputs / KbdMouse / XDisplay / WM*.
# NB: the generic `Plugins` driver registry is deliberately NOT one of those -- network drivers,
# file systems and disks register through it too, so tainting it would wrongly drop the whole
# networking stack (IP/TCP/UDP/DNS/HTTP/...).
#
# The closure is what makes the list self-consistent for both compilation (needs the .SymUu of
# everything imported) and dynamic loading (needs the .GofUu).
#
# The two lists are NOT each other's translation. Each platform has modules the other has
# no counterpart for, and one of them cost half a day to find: WinTrace is what StdIO
# imports on Windows, it exists in no Linux closure, and a Win64 lib assembled by filtering
# with the Linux list is missing it — that lib compiles everything that does not print.
#
# Run from the repository root, after the stdlib for that platform has been built:
#     bash docker/gen-headless-core.sh              # both, whichever builds are present
#     bash docker/gen-headless-core.sh linux64      # just one
#     bash docker/gen-headless-core.sh --check      # verify the lists match the registry, write nothing
#
# Requires: the bootstrap compiler (compilers/Linux64/oberon) and python3.
set -euo pipefail
cd "$(dirname "$0")/.."

CHECK=0
args=()
for a in "$@"; do
	case "$a" in
		--check) CHECK=1 ;;
		*) args+=("$a") ;;
	esac
done
set -- ${args+"${args[@]}"}

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

	# 2. Seed from the registry, close under imports, check the annotations, emit.
	python3 - "$graph" "$bin" "$out" "$objext" "$symext" "$CHECK" <<'PY'
import sys, os, glob, json
graph, binp, out, objext, symext, check = sys.argv[1:7]
check = check == "1"

# A module can have a line per platform file -- Unix.Beep.Mod and Windows.Beep.Mod are both
# `Beep.GofUu:` here -- so the sets are merged, not replaced. Assigning let the last line win, and
# the last line for Beep is the Windows one (Kernel32, Kernel) while the Unix one imports X11,
# Displays and XDisplay: Beep looked headless and rode into the payload. A module counts as
# reaching the window system if any of its platform variants does, which is the safe side to err
# on for a list that decides what an image carries.
deps = {}
for line in open(graph):
    lhs, _, rhs = line.strip().partition(":")
    m = lhs[:-len(objext)-1] if lhs.endswith("."+objext) else lhs
    deps.setdefault(m, set()).update(
        t[:-len(objext)-1] for t in rhs.split() if t.endswith("."+objext))
have = {os.path.basename(p)[:-len(symext)-1] for p in glob.glob(binp+"/*."+symext)}

ROOTS = {"Displays","Display","Inputs","KbdMouse","Raster",
         "WindowManager","WMGraphics","WMWindowManager","XDisplay"}
# The WM prefix is a naming convention, not a fact, and one module wears it without earning it:
# WMEvents is a generic broadcaster over Kernel/Objects/Strings with nothing graphical in it. It
# cost the whole text stack -- Texts imports it, so Texts, TextUtilities, Codecs, Repositories,
# Models and Types were all tainted through one edge to a module that draws nothing. An exception
# is only allowed if the module's own closure reaches no real root, and that is asserted below.
NOTGUI = {"WMEvents"}
gui = lambda m: m not in NOTGUI and (m.startswith("WM") or m in ROOTS)

sys.setrecursionlimit(10000)
def closure(seed):
    seen, stack = set(seed), list(seed)
    while stack:
        m = stack.pop()
        for d in deps.get(m, ()):
            if d not in seen:
                seen.add(d); stack.append(d)
    return seen

packages, owner, seed = {}, {}, set()
problems = []
for m in sorted(NOTGUI):
    if m in deps and any(gui(x) for x in closure(deps[m])):
        problems.append(f"{m}: exempted from the window system, but its own imports reach it")
for f in sorted(glob.glob("packages/*/*/a2pkg.json")):
    d = json.load(open(f))
    name = d["name"]
    if "headless" not in d:
        problems.append(f"{name}: no `headless` field -- say whether the SDK carries this package")
        continue
    packages[name] = d
    graphical = set(d.get("graphical", []))
    # `graphical` only says something about a package that ships: it is the reason a member of it
    # does NOT. On a package that stays home the whole list would be noise, so it is not allowed
    # there and not checked.
    if not d["headless"] and graphical:
        problems.append(f"{name}: `headless` is false, so `graphical` says nothing -- drop it")
    for m in d.get("provides", []):
        if m in owner:
            problems.append(f"{m}: provided by both {owner[m]} and {name}")
        owner[m] = name
        if m not in deps:
            continue                        # no source on this target: Shortreal on AArch64, and so on
        if not d["headless"]:
            continue
        reaches = any(gui(x) for x in closure({m}))
        if reaches and m not in graphical:
            problems.append(f"{name}: {m} reaches the window system and is not in `graphical`")
        if not reaches and m in graphical:
            problems.append(f"{name}: {m} is in `graphical` but reaches no window system module")
        if not reaches:
            seed.add(m)

# No undeclared cycle between packages. One inside a package is normal -- the graphics stack is
# one -- but two packages importing each other means the boundary is drawn in the wrong place, and
# the tier numbers stop meaning anything there. A pair that genuinely cannot be split says so in
# `cycle`, on both sides, with the reason in `residual`.
# std/runtime is meant to be closed: the kernel cannot import the library it sits under. The
# manifest says so in words; this says so in arithmetic, because a module added later would break
# it silently otherwise.
runtime = {m for n, d in packages.items() if n == "std/runtime" for m in d.get("provides", [])}
for m in sorted(runtime):
    outside = sorted(x for x in deps.get(m, ()) if x not in runtime and x in owner)
    if outside:
        problems.append(f"std/runtime is not closed: {m} imports "
                        + ", ".join(f"{x} ({owner[x]})" for x in outside))

requires = {n: set(d.get("requires", {})) for n, d in packages.items()}
declared = {n: set(d.get("cycle", [])) for n, d in packages.items()}
for a in sorted(requires):
    for b in sorted(requires[a]):
        if a < b and a in requires.get(b, ()):
            if b not in declared.get(a, ()) or a not in declared.get(b, ()):
                problems.append(f"{a} and {b} import each other and neither declares it in `cycle`")

keep = sorted(closure(seed) & have)

# Everything the closure needs must belong to some package: that is the whole point of deriving
# the payload from the registry, and an unclaimed module is a hole in it rather than a free pass.
for m in keep:
    if m not in owner:
        users = sorted(x for x in keep if m in deps.get(x, ()))[:4]
        problems.append(f"{m}: in the payload, claimed by no package (needed by {' '.join(users) or 'a root'})")

if problems:
    print(f"{os.path.basename(out)}: the registry and the tree disagree:", file=sys.stderr)
    for p in problems:
        print("  " + p, file=sys.stderr)
    sys.exit(1)

if check:
    was = [l.strip() for l in open(out)] if os.path.exists(out) else []
    was = [l for l in was if l and not l.startswith("#")]
    if was != keep:
        print(f"{os.path.basename(out)}: out of date -- "
              f"{len(set(was)-set(keep))} to drop, {len(set(keep)-set(was))} to add", file=sys.stderr)
        sys.exit(1)
    print(f"{os.path.basename(out)}: {len(keep)} modules, as the registry says")
else:
    open(out, "w").write("\n".join(keep) + "\n")
    print(f"{os.path.basename(out)}: {len(keep)} modules from {len(packages)} packages")
PY
	rm -f "$graph"
}

if [ $# -gt 0 ]; then
	for p in "$@"; do generate "$p"; done
else
	generate linux64
	generate win64
fi
