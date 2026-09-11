#!/usr/bin/env bash
#
# Put a C library for another architecture where the checks for it look for one.
#
# The AArch64 and ARM32 checks run their image under qemu-user, which needs a sysroot holding
# that architecture's loader and the rest of libc. On Debian and Ubuntu the libc6-<arch>-cross
# packages are those sysroots and this script is not needed. Where they cannot be installed --
# no root, or a distribution that does not carry them -- this unpacks the library out of a
# Debian image of that architecture. Nothing is run from the image: only its /lib and /usr/lib
# are taken, so no emulation is needed to build it.
#
# Usage: tests/sysroot.sh [arm64|armhf] [destination]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
arch="${1:-arm64}"
case "$arch" in
	arm64) platform=linux/arm64; loader=lib/ld-linux-aarch64.so.1; default="$root/target/A64/sysroot"; package=libc6-arm64-cross ;;
	armhf) platform=linux/arm/v7; loader=lib/ld-linux-armhf.so.3; default="$root/target/LinuxARM/sysroot"; package=libc6-armhf-cross ;;
	*) echo "no such architecture: $arch (arm64 or armhf)" >&2; exit 2 ;;
esac
dest="${2:-$default}"
image="${A64_SYSROOT_IMAGE:-debian:bookworm-slim}"

if [ -f "$dest/$loader" ]; then
	echo "$arch C library already in $dest"
	exit 0
fi

if ! command -v docker >/dev/null; then
	echo "no docker, and no $arch C library to unpack without it; install $package" >&2
	echo "or point the check's sysroot variable at a sysroot of your own" >&2
	exit 2
fi

docker pull --platform "$platform" "$image" >/dev/null

mkdir -p "$dest"
container="$(docker create --platform "$platform" "$image" true)"
trap 'docker rm "$container" >/dev/null 2>&1 || true' EXIT
# Exporting the filesystem does not run the container, so this works without binfmt registered.
docker export "$container" | tar -C "$dest" -xf - lib usr/lib

if [ ! -f "$dest/$loader" ]; then
	echo "$image did not carry $(basename "$loader"); is it really an $arch image?" >&2
	exit 1
fi

echo "$arch C library unpacked into $dest ($(du -sh "$dest" | cut -f1))"
