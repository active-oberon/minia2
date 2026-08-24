#!/usr/bin/env bash
#
# Write configs/moduleListA64.txt: the headless standard library in dependency order.
#
# The order comes from Release.Build, which is what the host platform is built in. The selection is
# what the SDK image ships (docker/headless-core.txt) PLUS what the test suites import: these
# objects have two consumers, and the suites test the graphics stack, which the image leaves out.
# Deriving only from the payload was tried on 2026-08-24 and cost 23 cases in Raster.Test and
# WMGraphics.Test -- they lost Raster, WMGraphics, WMRectangles and Displays. Four modules are
# dropped because they cannot exist on AArch64 -- the reasons are in the head of the list.
#
# Usage: tests/gen-a64-stdlib.sh

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
host="${HOST:-Linux64}"
oberon="$root/compilers/$host/oberon"
[ -x "$oberon" ] || oberon="$root/compilers/$host/oberon.exe"
[ -x "$oberon" ] || { echo "no bootstrap compiler in $root/compilers/$host" >&2; exit 2; }

exclude="Oberon OberonGadgets OberonApplications OberonVoyager OberonAnts OberonDocumentation Fun Education Testing EFI CjkFonts Pr3Fonts Pr6Fonts"

ordered=$(cd "$root" && AOSPATH="$root/data" "$oberon" Release.Build --list --exclude="\"$exclude\"" "$host" 2>&1 \
	| tr -d '\r' | grep -E "^[^ ]+\.Mod[[:space:]]" | tr -d ' ')

# The dependency graph, to close the suites' imports over: a case importing WMGraphics needs
# everything WMGraphics needs, and none of that is in the payload.
graph="$(mktemp)"
(cd "$root" && AOSPATH="$root/data" "$oberon" DependencyWalker.Walk --define=UNIX,AMD64 \
	--fileExtension=".GofUu" source/*.Mod 2>/dev/null) | tr -d '\r' | grep "\.GofUu:" > "$graph"

printf '%s\n' "$ordered" | python3 -c '
import sys, glob, re, os
root = "'"$root"'"
graph = "'"$graph"'"
ordered = [l.strip() for l in sys.stdin if l.strip()]
keep = {l.strip() for l in open(root + "/docker/headless-core.txt") if l.strip()}

deps = {}
for line in open(graph):
    lhs, _, rhs = line.strip().partition(":")
    m = lhs[:-6] if lhs.endswith(".GofUu") else lhs
    deps.setdefault(m, set()).update(t[:-6] for t in rhs.split() if t.endswith(".GofUu"))

# every module a test case names, closed over imports: the suites are the second consumer of
# these objects and they reach past the payload on purpose
wanted = set()
for f in glob.glob(root + "/tests/*.Test"):
    for line in open(f, encoding="latin-1", errors="replace"):
        if "IMPORT" not in line: continue
        for name in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", line.split("IMPORT",1)[1]):
            wanted.add(name)
stack = list(wanted)
while stack:
    m = stack.pop()
    for d in deps.get(m, ()):
        if d not in wanted: wanted.add(d); stack.append(d)
keep |= {m for m in wanted if m in deps}
drop = {"CPUID.Mod", "AMD64.Shortreal.Mod", "AMD64.FoxArrayBaseOptimized.Mod", "Unix.Beep.Mod"}
def module(f): return f[:-4].split(".")[-1]
seen, out = set(), []
for f in ordered:
    m = module(f)
    if m in keep and m not in seen and f not in drop:
        seen.add(m); out.append(f)
missing = keep - seen - {module(f) for f in drop}
if missing:
    sys.stderr.write("not found in the release list: " + " ".join(sorted(missing)) + "\n")
head = open(root + "/configs/moduleListA64.txt").read().split("\n#\n")[0] if False else None
sys.stdout.write("\n".join(out) + "\n")
sys.stderr.write("%d modules\n" % len(out))
' > /tmp/a64-stdlib-body.$$

{
	sed -n '1,/^# Regenerate with/p' "$root/configs/moduleListA64.txt"
	cat /tmp/a64-stdlib-body.$$
} > "$root/configs/moduleListA64.txt.new"
rm -f /tmp/a64-stdlib-body.$$ "$graph"
mv "$root/configs/moduleListA64.txt.new" "$root/configs/moduleListA64.txt"
echo "wrote configs/moduleListA64.txt"
