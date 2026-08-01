#!/usr/bin/env bash
#
# Put an AArch64 C library where the A64 checks look for one.
#
# `tests/a64-system-check.sh` and `tests/a64-gc-check.sh` run the AArch64 image under qemu-user,
# which needs a sysroot holding ld-linux-aarch64.so.1 and the rest of libc. On Debian and Ubuntu
# the libc6-arm64-cross package is that sysroot and this script is not needed. Where it cannot be
# installed -- no root, or a distribution that does not carry it -- this unpacks the library out of
# an arm64 Debian image into target/A64/sysroot, which both checks search first. Nothing is run
# from the image: only its /lib and /usr/lib are taken, so no emulation is needed to build it.
#
# Usage: tests/a64-sysroot.sh [destination]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="${1:-$root/target/A64/sysroot}"
image="${A64_SYSROOT_IMAGE:-debian:bookworm-slim}"

if [ -f "$dest/lib/ld-linux-aarch64.so.1" ]; then
	echo "AArch64 C library already in $dest"
	exit 0
fi

if ! command -v docker >/dev/null; then
	echo "no docker, and no AArch64 C library to unpack without it; install libc6-arm64-cross" >&2
	echo "or point A64_SYSROOT at a sysroot of your own" >&2
	exit 2
fi

docker pull --platform linux/arm64 "$image" >/dev/null

mkdir -p "$dest"
container="$(docker create --platform linux/arm64 "$image" true)"
trap 'docker rm "$container" >/dev/null 2>&1 || true' EXIT
# Exporting the filesystem does not run the container, so this works without binfmt registered.
docker export "$container" | tar -C "$dest" -xf - lib usr/lib

if [ ! -f "$dest/lib/ld-linux-aarch64.so.1" ]; then
	echo "$image did not carry ld-linux-aarch64.so.1; is it really an arm64 image?" >&2
	exit 1
fi

echo "AArch64 C library unpacked into $dest ($(du -sh "$dest" | cut -f1))"
