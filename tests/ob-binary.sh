#!/usr/bin/env bash
#
# Build `ob` for a platform: sdk/Ob.Mod and its Unix host layer, compiled and linked last into
# the boot set without the interactive shell -- Ob's own body is the program, and the compiler and
# the linker are inside it, which is why a verb is a procedure call and not a process.
#
# Two callers want exactly this binary and would otherwise each carry a copy of the recipe: the
# tarball (tests/bundle.sh), which ships it, and the AArch64 suites (tests/a64-suites-check.sh),
# which drive it as the harness. tests/ob-check.sh keeps its own build on purpose -- it is the
# check that interrogates the compile and the link themselves.
#
# With -p the objects are compiled for another platform than the host, which is how the 32-bit
# tarballs get an `ob` of their own: the compiler still runs here, the code it writes does not.
#
# What lands in the output directory: ob, and the two symbol files under the platform's extension.
# The symbol files are the caller's business; a bundle puts them in lib/ so that a project and the
# language server can resolve them like any other module.
#
# Usage: tests/ob-binary.sh [-p <platform>] [-r <host build>] <build directory> <output directory>

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
. "$root/tests/platform-env.sh"

platform=Linux64
host=""
args=()
while [ $# -gt 0 ]; do
	case "$1" in
		-p|--platform) platform="$2"; shift 2 ;;
		-r|--runtime) host="$2"; shift 2 ;;
		-*) echo "unknown option: $1" >&2; exit 2 ;;
		*) args+=("$1"); shift ;;
	esac
done
build="${args[0]:?usage: ob-binary.sh [-p platform] [-r host build] <build directory> <output directory>}"
out="${args[1]:?usage: ob-binary.sh [-p platform] [-r host build] <build directory> <output directory>}"
case "$build" in /*) ;; *) build="$PWD/$build" ;; esac
case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
[ -n "$host" ] || host="$build"
case "$host" in /*) ;; *) host="$PWD/$host" ;; esac

platform_env "$platform"

oberon="$host/oberon"
[ -x "$oberon" ] || oberon="$host/oberon.exe"
[ -x "$oberon" ] || { echo "no runtime in $host to build ob with" >&2; exit 2; }
[ -d "$out" ] || { echo "no such directory: $out" >&2; exit 2; }

work="$(mktemp -d "${TMPDIR:-/tmp}/obbin.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The sources go in under their MODULE names: a platform-prefixed file compiles to the module's
# name whatever the file is called, but the linker is given module names and looks for objects.
cp "$root/sdk/Unix.ObHost.Mod" "$work/ObHost.Mod"
cp "$root/sdk/Ob.Mod"          "$work/Ob.Mod"

boot="$(grep -vE '^(StdIOShell|Shell)$' "$root/$MODULE_LIST" | tr -d '\r' | tr '\n' ' ')"
# The host's own objects are on the path as well as the target's: cross-building, the compiler
# itself is loaded from there. The two never collide -- a platform is its object extension.
( cd "$work" && "$oberon" do "
	Files.AddSearchPath $work~
	Files.AddSearchPath $build/bin~
	Files.AddSearchPath $host/bin~
	Compiler.Compile $COMPILEOPTIONS --objectFileExtension=$EXTENSION --symbolFileExtension=$SYMBOLFILEEXCEPTION ./ObHost.Mod ./Ob.Mod ~
	Linker.Link ${LINKPLATFORM:+-p=$LINKPLATFORM} --extension=$EXTENSION --fileName='ob'
	$boot Ob
	~
" ) > "$work/ob.log" 2>&1 || true
[ -f "$work/ob" ] || { sed 's/^/    /' "$work/ob.log" >&2; echo "ob did not link for $platform" >&2; exit 1; }

install -m 755 "$work/ob" "$out/ob"
install -m 644 "$work/Ob$SYMBOLFILEEXCEPTION" "$work/ObHost$SYMBOLFILEEXCEPTION" "$out/"
