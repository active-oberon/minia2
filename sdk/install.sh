#!/bin/sh
#
# Put the A2 / Active Oberon SDK on this machine:
#
#     curl -fsSL https://raw.githubusercontent.com/active-oberon/minia2/main/sdk/install.sh | sh
#
# It downloads the tarball for this machine from the GitHub releases, unpacks it into
# ~/.local/share/a2sdk, and links `ob` into ~/.local/bin. Nothing else is written, nothing
# is compiled here, and no privilege is asked for -- the tarball is a directory, and this
# script is only the two minutes of moving it into place that everybody otherwise does by
# hand. Removing the SDK is `install.sh --uninstall`, or deleting those two paths.
#
# It is deliberately POSIX sh, not bash: it runs before the SDK exists, on whatever the
# machine happens to have. The SDK's own `ob` has been Active Oberon since 2026-08-11.
#
#   --version <tag>     a particular release instead of the latest
#   --tarball <file>    a tarball already on disk; no network, nothing resolved
#   --dir <path>        where the SDK goes        (default ~/.local/share/a2sdk)
#   --bin <path>        where the `ob` link goes  (default ~/.local/bin)
#   --no-link           unpack only, link nothing
#   --uninstall         remove both
#
# The same values come from the environment: A2SDK_VERSION, A2SDK_TARBALL, A2SDK_HOME,
# A2SDK_BIN. Flags win over the environment.

set -eu

repo="${A2SDK_REPO:-active-oberon/minia2}"
version="${A2SDK_VERSION:-}"
tarball="${A2SDK_TARBALL:-}"
home_dir="${A2SDK_HOME:-$HOME/.local/share/a2sdk}"
bin_dir="${A2SDK_BIN:-$HOME/.local/bin}"
link=1
uninstall=0

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }
say() { printf '%s\n' "$1"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--version) [ $# -ge 2 ] || die "--version needs a tag"; version="$2"; shift 2 ;;
		--tarball) [ $# -ge 2 ] || die "--tarball needs a file"; tarball="$2"; shift 2 ;;
		--dir)     [ $# -ge 2 ] || die "--dir needs a path"; home_dir="$2"; shift 2 ;;
		--bin)     [ $# -ge 2 ] || die "--bin needs a path"; bin_dir="$2"; shift 2 ;;
		--no-link) link=0; shift ;;
		--uninstall) uninstall=1; shift ;;
		-h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) die "unknown option: $1 (--help lists them)" ;;
	esac
done

# Removal is the same two paths in reverse, and the link is only removed when it is ours:
# a file called `ob` in ~/.local/bin that points somewhere else belongs to somebody else.
if [ "$uninstall" = 1 ]; then
	removed=0
	if [ -L "$bin_dir/ob" ]; then
		target="$(readlink "$bin_dir/ob")"
		case "$target" in
			"$home_dir"/*) rm -f "$bin_dir/ob"; say "removed $bin_dir/ob"; removed=1 ;;
			*) say "left $bin_dir/ob alone: it points at $target, not into $home_dir" ;;
		esac
	fi
	if [ -d "$home_dir" ]; then rm -rf "$home_dir"; say "removed $home_dir"; removed=1; fi
	[ "$removed" = 1 ] || say "nothing to remove: no $home_dir and no link to it in $bin_dir"
	exit 0
fi

# Which tarball this machine wants. The Windows SDK is a third asset and a `.exe`; a shell
# capable of running this script is not evidence that Windows is what it is running on, so
# only the two Linux hosts are resolved here and anything else is told what to take by hand.
platform=""
if [ -z "$tarball" ]; then
	os="$(uname -s)"
	arch="$(uname -m)"
	# Android shares the kernel and the architecture with any other 64-bit ARM Linux and differs
	# in the one thing that decides whether the image starts at all: its C library. So the loader
	# on the box is what is asked, not uname. Both present means a glibc rootfs on an Android
	# kernel -- proot-distro -- and there the glibc tarball is the right one. A2SDK_SYSROOT is
	# for install-check.sh, which cannot create /system on the machine it runs on.
	bionic=0
	if [ -e "${A2SDK_SYSROOT:-}/system/bin/linker64" ] &&
	   [ ! -e "${A2SDK_SYSROOT:-}/lib/ld-linux-aarch64.so.1" ]; then bionic=1; fi
	case "$os/$arch" in
		Linux/x86_64|Linux/amd64) platform="linux-amd64" ;;
		Linux/aarch64|Linux/arm64)
			if [ "$bionic" = 1 ]; then platform="android-arm64"; else platform="linux-arm64"; fi ;;
		Darwin/*) die "macOS has no SDK build yet; the Docker image runs there (docker/README.md)" ;;
		*) die "no SDK build for $os on $arch; the releases page lists what there is: https://github.com/$repo/releases" ;;
	esac
fi

fetch() {  # fetch <url> <destination>; whichever downloader the machine has
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$1" -o "$2"
	elif command -v wget >/dev/null 2>&1; then
		wget -qO "$2" "$1"
	else
		die "neither curl nor wget here; download $1 by hand and pass it with --tarball"
	fi
}

work="$(mktemp -d "${TMPDIR:-/tmp}/a2sdk-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT INT TERM

if [ -n "$tarball" ]; then
	[ -f "$tarball" ] || die "no such tarball: $tarball"
	archive="$tarball"
	say "install.sh: using $tarball"
else
	# The latest release, read out of the API response without a JSON parser: `tag_name` is
	# the first field of that name in the document, and its value is a plain string.
	if [ -z "$version" ]; then
		fetch "https://api.github.com/repos/$repo/releases/latest" "$work/release.json" ||
			die "could not reach the GitHub API; pass --version <tag> to skip the lookup"
		version="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$work/release.json" | head -1)"
		[ -n "$version" ] || die "no release found for $repo; pass --version <tag>"
	fi
	asset="minia2-sdk-$version-$platform.tar.gz"
	base="https://github.com/$repo/releases/download/$version"
	say "install.sh: downloading $asset"
	fetch "$base/$asset" "$work/$asset" || die "no asset $asset in release $version"
	archive="$work/$asset"

	# Checksums when the release carries them. A release without SHA256SUMS is older than
	# this script, so its absence is reported and not treated as a failure -- but a file
	# that is there and does not match is, because that is the case the check exists for.
	if fetch "$base/SHA256SUMS" "$work/SHA256SUMS" 2>/dev/null; then
		sum=""
		if command -v sha256sum >/dev/null 2>&1; then sum="$(sha256sum "$archive" | cut -d' ' -f1)"
		elif command -v shasum >/dev/null 2>&1; then sum="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
		fi
		if [ -z "$sum" ]; then
			say "install.sh: no sha256sum here, checksum not verified"
		else
			want="$(grep -F " $asset" "$work/SHA256SUMS" | cut -d' ' -f1 | head -1)"
			[ -n "$want" ] || die "SHA256SUMS carries no line for $asset"
			[ "$sum" = "$want" ] || die "checksum mismatch for $asset (got $sum, expected $want)"
			say "install.sh: checksum ok"
		fi
	else
		say "install.sh: release $version publishes no SHA256SUMS, checksum not verified"
	fi
fi

# Unpacked beside the destination and moved in afterwards, so a download that turns out to be
# truncated leaves the SDK that is already installed working.
mkdir -p "$work/unpack"
tar xzf "$archive" -C "$work/unpack" || die "could not unpack $archive"
inner="$(find "$work/unpack" -mindepth 1 -maxdepth 1 -type d)"
[ -n "$inner" ] && [ "$(printf '%s\n' "$inner" | wc -l)" = 1 ] ||
	die "unexpected tarball layout: expected one directory inside $archive"
[ -x "$inner/ob" ] || die "no ob in $archive; that is not an SDK tarball"

parent="$(dirname "$home_dir")"
mkdir -p "$parent"
if [ -e "$home_dir" ]; then
	[ -d "$home_dir" ] || die "$home_dir exists and is not a directory"
	rm -rf "$home_dir.old"
	mv "$home_dir" "$home_dir.old"
fi
mv "$inner" "$home_dir"
rm -rf "$home_dir.old"
say "install.sh: SDK in $home_dir"

# The link, not a copy: `ob` follows it back and finds its runtime and its objects beside
# the real file, so the SDK stays one directory and upgrading it is one `mv`.
if [ "$link" = 1 ]; then
	mkdir -p "$bin_dir"
	if [ -e "$bin_dir/ob" ] && [ ! -L "$bin_dir/ob" ]; then
		say "install.sh: $bin_dir/ob exists and is not a link -- left alone"
		say "            run this instead: ln -sf \"$home_dir/ob\" <somewhere on your PATH>"
	else
		ln -sf "$home_dir/ob" "$bin_dir/ob"
		say "install.sh: ob linked into $bin_dir"
		case ":${PATH}:" in
			*":$bin_dir:"*) ;;
			*) say "install.sh: $bin_dir is not on your PATH; add it:"
			   say "            echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.profile" ;;
		esac
	fi
fi

# What was installed, said by the thing that was installed.
say ""
"$home_dir/ob" version || die "the SDK is in place but 'ob version' failed"
say ""
say "next:  ob run $home_dir/examples/Hello.Mod"
say "check: $home_dir/run.sh --quick"
