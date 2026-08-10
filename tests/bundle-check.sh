#!/usr/bin/env bash
#
# Check the tarball SDK the way the person who downloads it will: unpack it somewhere else and
# use it, with nothing from this tree in the environment.
#
# The claim being checked is "Docker is not required, and neither is anything else", so the
# checking has to be hostile to the tree it runs in. Three things make it so:
#
#   -  the bundle is unpacked from the TARBALL, not read out of target/bundle -- a file that
#      failed to be packed is then a failure here rather than a surprise for a stranger.
#   -  the environment is scrubbed with `env -i`: no A2SDK, no A2_PLATFORM, no TMPDIR of ours,
#      and a PATH holding only the system directories. Everything the SDK needs it must find
#      beside itself.
#   -  the checks are the ones that ship inside the bundle (run.sh), not a second set written
#      here. What a user runs to see whether their download works is what CI runs.
#
# By default the suites are skipped (--quick): the tree runs them already, on the same objects,
# in `task test`. BUNDLE_FULL=1 runs them out of the bundle as well, which is what a release
# wants -- it is the same compiler but it is not the same arrangement of it.
#
# Exit 2 means the check could not run (no build to bundle); 1 means the bundle is broken.
#
# Usage: tests/bundle-check.sh [build directory]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
case "$build" in /*) ;; *) build="$PWD/$build" ;; esac

if [ ! -x "$build/oberon" ] || [ ! -f "$build/bin/Compiler.SymUu" ]; then
	echo "no build to bundle in $build (run 'task Linux64')" >&2
	exit 2
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

echo "== assembling the bundle"
"$root/tests/bundle.sh" -o "$stage/bundle" "$build" | sed 's/^/   /'
tarball="$(ls "$stage"/minia2-sdk-*-linux-amd64.tar.gz 2>/dev/null | head -1)"
[ -f "$tarball" ] || { echo "bundle.sh produced no tarball in $stage" >&2; exit 1; }

echo
echo "== unpacking $(basename "$tarball") somewhere else"
mkdir -p "$stage/elsewhere"
tar xzf "$tarball" -C "$stage/elsewhere"
sdk="$(ls -d "$stage"/elsewhere/minia2-sdk-*-linux-amd64)"
echo "   $sdk"

# Nothing in the bundle may name this tree. Only the text files are looked at: the runtime is a
# linked binary and may carry whatever paths its linker recorded, which no one reads at run time.
echo
echo "== looking for paths out of the bundle"
leaked=0
for f in "$sdk/ob" "$sdk/run.sh" "$sdk/oberon.cfg" "$sdk/boot-modules.txt" "$sdk/README" "$sdk/VERSION"; do
	[ -f "$f" ] || continue
	if grep -Fq "$root" "$f"; then
		echo "   LEAK  $(basename "$f") names $root" >&2
		leaked=1
	fi
done
[ "$leaked" = 0 ] || { echo "the bundle depends on the tree it was built in" >&2; exit 1; }
echo "   none"

echo
echo "== using it, with an empty environment"
mkdir -p "$stage/tmp"
mode=--quick
[ -n "${BUNDLE_FULL:-}" ] && mode=""
# HOME and TMPDIR are given because a user has them, not because the SDK is entitled to ours;
# TERM keeps anything that asks from misbehaving on a terminal it cannot know.
env -i \
	PATH=/usr/local/bin:/usr/bin:/bin \
	HOME="$stage/home" \
	TMPDIR="$stage/tmp" \
	TERM=dumb \
	bash "$sdk/run.sh" $mode
