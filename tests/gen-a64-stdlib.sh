#!/usr/bin/env bash
#
# Write configs/moduleListA64.txt: the headless standard library in dependency order.
#
# The order comes from Release.Build, which is what the host platform is built in; the selection
# comes from docker/headless-core.txt, which is what the SDK image ships. Four modules are dropped
# because they cannot exist on AArch64 -- the reasons are written into the head of the list.
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

printf '%s\n' "$ordered" | python3 -c '
import sys
root = "'"$root"'"
ordered = [l.strip() for l in sys.stdin if l.strip()]
keep = {l.strip() for l in open(root + "/docker/headless-core.txt") if l.strip()}
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
rm -f /tmp/a64-stdlib-body.$$
mv "$root/configs/moduleListA64.txt.new" "$root/configs/moduleListA64.txt"
echo "wrote configs/moduleListA64.txt"
