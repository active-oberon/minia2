#!/usr/bin/env bash
#
# Check the tarball SDK the way the person who downloads it will, which means being hostile to
# the tree this runs in:
#
#   -  unpacked from the TARBALL, not read out of target/bundle, so a file that failed to be
#      packed fails here and not in a stranger's download;
#   -  `env -i`: no A2SDK, no TMPDIR of ours, a PATH of system directories only;
#   -  the checks are the bundle's own run.sh, so what CI runs is what a user runs.
#
# Suites skipped by default (`task test` runs them on the same objects); BUNDLE_FULL=1 adds them,
# which a release wants -- same compiler, different arrangement of it.
#
# Exit 2: could not run (no build to bundle). Exit 1: the bundle is broken.
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

# Nothing in the bundle may name this tree. Text files only: the runtime may carry linker paths,
# which nothing reads at run time.
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
# HOME and TMPDIR because a user has them, not because the SDK may have ours.
env -i \
	PATH=/usr/local/bin:/usr/bin:/bin \
	HOME="$stage/home" \
	TMPDIR="$stage/tmp" \
	TERM=dumb \
	bash "$sdk/run.sh" $mode
