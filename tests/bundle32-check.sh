#!/usr/bin/env bash
#
# Assemble one of the 32-bit tarball SDKs and use it: the i386 one on this machine if it has a
# 32-bit C library, the armhf one under qemu-user against a sysroot. What runs afterwards is the
# bundle's own run.sh -- every verb, then one suite -- so the check is the same one a stranger
# unpacking the tarball would make, and it fails where they would fail.
#
# Neither of these can be answered by building alone: `task Linux32` produced a working ELF for
# weeks of nothing, and the two defects that mattered -- Builtins importing FPE64 on ARM, and
# 32-bit readdir failing on ext4 -- were both invisible until the SDK ran on its own target.
#
# Exits 2, not 1, when the machine cannot run the binaries: no 32-bit libc, no qemu, no sysroot.
# BUNDLE32_REQUIRE turns that into a failure, for a runner that is meant to have them.
#
# Usage: tests/bundle32-check.sh <Linux32|LinuxARM> [build directory]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
platform="${1:?usage: bundle32-check.sh <Linux32|LinuxARM> [build directory]}"
build="${2:-$root/target/$platform}"
case "$platform" in
	Linux32)  out="$root/target/bundle-linux32"; loader=/lib/ld-linux.so.2 ;;
	LinuxARM) out="$root/target/bundle-armhf";   loader=/lib/ld-linux-armhf.so.3 ;;
	*) echo "no 32-bit bundle for platform $platform" >&2; exit 2 ;;
esac

[ -x "$build/oberon" ] || { echo "no build in $build (task $platform)" >&2; exit 2; }

# What it takes to run the result, per platform. The i386 one runs here or not at all; the armhf
# one runs under qemu, which needs the loader and libc of the target beside it.
if [ "$platform" = Linux32 ]; then
	[ -f "$loader" ] || { echo "no 32-bit C library on this machine ($loader)" >&2; exit 2; }
else
	command -v qemu-arm >/dev/null || command -v qemu-arm-static >/dev/null || {
		echo "no qemu-arm to run the armhf SDK with" >&2; exit 2; }
	sysroot="${ARM32_SYSROOT:-$root/target/LinuxARM/sysroot}"
	[ -f "$sysroot$loader" ] || sysroot=/usr/arm-linux-gnueabihf
	[ -f "$sysroot$loader" ] || {
		echo "no armhf C library: task arm32-sysroot, or ARM32_SYSROOT=… " >&2; exit 2; }
	export QEMU_LD_PREFIX="$sysroot"
fi

"$root/tests/bundle.sh" -p "$platform" -o "$out" --no-tar "$build"

# run.sh is the bundle's own, and it is what a stranger runs. --quick leaves out the full suites:
# those are `ob test` in the bundle, minutes here and the better part of an hour under qemu.
( cd "$out" && ./run.sh --quick )
