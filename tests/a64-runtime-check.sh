#!/usr/bin/env bash
#
# Compile the Unix runtime for UnixA64, module by module, and report how much of it got through.
#
# The list is the beginning of what Release.Build prints for Linux64 -- the same order the host
# platform is built in, which is a dependency order -- down to the two shells. It is everything that
# is linked into the `oberon` binary plus the file systems that come with it. Nothing here is run:
# an AArch64 libc is needed for that, and there is none on this machine, so what this checks is that
# the compiler gets through the runtime and produces object files for it.
#
# Each module is compiled in its own process, so that one failure does not hide the modules behind
# it. The symbol files of the modules already done are found in the output directory.
#
# Usage: tests/a64-runtime-check.sh [build directory] [output directory]

set -eo pipefail

# Directories given on the command line are made absolute: every one of them is used after a `cd`
# into the build directory, and a relative one would be read from there rather than from where it
# was given. The output directory need not exist yet, so this does not go through `cd`.
absolute() {
	case "$1" in
		/*) printf '%s\n' "$1" ;;
		*) printf '%s\n' "$PWD/$1" ;;
	esac
}

# What went wrong, as far as the compiler said so. A failure with no line mentioning an error --
# a directory that is not there, say -- would otherwise be reported as nothing at all, because a
# `grep` that matches nothing ends the script under `set -e`.
Reason() {
	printf '%s\n' "$1" | grep -E 'error' | head -"$2" || printf '%s\n' "$1" | tail -"$2"
}

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
build="$(absolute "$build")"
out="${2:-$root/target/A64/bin}"
out="$(absolute "$out")"

oberon="$build/oberon"
[ -x "$oberon" ] || oberon="$build/oberon.exe"
if [ ! -x "$oberon" ]; then
	echo "no built runtime in $build; run 'task Linux64' or 'task oberon' first" >&2
	exit 2
fi

modules=(
	AMD64.Builtins.Mod Trace.Mod Linux.Glue.Mod Linux.Unix.Mod Unix.Machine.Mod
	Heaps.Mod Modules.Mod Unix.Objects.Mod Unix.Kernel.Mod RealConversions.Mod
	Strings.Mod UTF8Strings.Mod KernelLog.Mod Plugins.Mod Streams.Mod Pipes.Mod
	Commands.Mod In.Mod Out.Mod AMD64.Reals.Mod Reflection.Mod TrapWriters.Mod
	CRC.Mod SystemVersion.Mod Unix.StdIO.Mod Unix.Traps.Mod Locks.Mod Unix.Clock.Mod
	Disks.Mod DiskCaches.Mod Files.Mod Dates.Mod Options.Mod FileTrapWriter.Mod
	Caches.Mod DiskVolumes.Mod OldDiskVolumes.Mod RAMVolumes.Mod DiskFS.Mod
	OldDiskFS.Mod OberonFS.Mod FATVolumes.Mod FATFiles.Mod ISO9660Volumes.Mod
	ISO9660Files.Mod Unix.UnixFiles.Mod RelativeFileSystem.Mod BitSets.Mod
	Diagnostics.Mod StringPool.Mod ObjectFile.Mod GenericLinker.Mod Loader.Mod
	Unix.BootConsole.Mod Shell.Mod StdIOShell.Mod
	Unix.ProcessInfo0.Mod ProcessInfo.Mod System.Mod
)

mkdir -p "$out"
failed=()
for module in "${modules[@]}"; do
	# The runtime reads its working directory from $PWD rather than from getcwd().
	output=$( (cd "$build" && PWD="$build" "$oberon" do "
		System.DoFile oberon.cfg ~
		Files.AddSearchPath $root/source ~
		Files.AddSearchPath $out ~
		Compiler.Compile -p=UnixA64 --destPath=$out/ $root/source/$module ~
	") 2>&1 | tr -d '\r' ) || true
	if printf '%s\n' "$output" | grep -q ' done\.'; then
		printf '  %-28s ok\n' "$module"
	else
		failed+=("$module")
		printf '  %-28s FAILED\n' "$module"
		Reason "$output" 5 | sed 's/^/      /'
	fi
done

echo "UnixA64: $(( ${#modules[@]} - ${#failed[@]} )) of ${#modules[@]} runtime modules compiled"
if [ ${#failed[@]} -gt 0 ]; then
	echo "still failing: ${failed[*]}" >&2
	exit 1
fi
