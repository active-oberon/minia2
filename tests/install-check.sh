#!/usr/bin/env bash
#
# Check sdk/install.sh -- the one command that puts the SDK on a machine.
#
# Offline, against the tarball this tree builds: the installer is given it with --tarball, so
# nothing here reaches the network and nothing depends on a release existing. What is checked is
# everything after the download, which is where an installer actually goes wrong: where it puts
# the SDK, whether the linked `ob` still finds its own runtime, whether installing twice upgrades
# rather than accumulates, whether it refuses to overwrite somebody else's `ob`, and whether
# uninstall removes exactly what it installed and nothing else.
#
# The download itself is checked as far as it can be without a release: the platform the machine
# resolves to, via a `uname` put in front of the real one on PATH.
#
# Usage: tests/install-check.sh [build directory]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
case "$build" in /*) ;; *) build="$PWD/$build" ;; esac

installer="$root/sdk/install.sh"
[ -f "$installer" ] || { echo "no $installer" >&2; exit 2; }

# The tarball the installer is fed. Built if it is not there, because a check that silently uses
# a months-old artifact is the failure mode this whole file exists to avoid.
tarball="$(ls -t "$(dirname "$build")"/minia2-sdk-*-linux-amd64.tar.gz 2>/dev/null | head -1)"
if [ -z "$tarball" ]; then
	echo "no tarball in $(dirname "$build"); run 'task bundle' first" >&2
	exit 2
fi
echo "install-check: $(basename "$tarball")"

work="$(mktemp -d "${TMPDIR:-/tmp}/install-check.XXXXXX")"
trap 'rm -rf "$work"' EXIT
home="$work/home/.local/share/a2sdk"
bin="$work/home/.local/bin"
fail=0

ok()   { echo "ok    $1"; }
bad()  { echo "FAIL  $1"; fail=1; }

run_installer() { sh "$installer" --tarball "$tarball" --dir "$home" --bin "$bin" "$@"; }

echo "=== install"
if out="$(run_installer 2>&1)"; then ok "installed"; else bad "install failed: $(printf '%s' "$out" | tail -3)"; fi
[ -x "$home/ob" ] && ok "ob is in $home" || bad "no ob in $home"
[ -L "$bin/ob" ]  && ok "ob is linked into the bin directory" || bad "no link in $bin"

# The property that makes a link enough: `ob` resolves the link and finds the runtime, the
# objects and the packages beside the real file rather than beside the link.
if hello="$("$bin/ob" run "$home/examples/Hello.Mod" 2>&1)"; then
	case "$hello" in
		*"Hello from A2"*) ok "the linked ob compiled and ran a module" ;;
		*) bad "the linked ob printed: $(printf '%s' "$hello" | tr '\n' ' ')" ;;
	esac
else
	bad "the linked ob could not run a module: $(printf '%s' "$hello" | tail -2)"
fi

# Nothing outside the two directories it was told about. ~ is the usual casualty of an installer
# tested only by its author, who already has it.
strays="$(find "$work/home" -maxdepth 2 -mindepth 1 ! -path "$work/home/.local" ! -path "$work/home/.local/share" ! -path "$work/home/.local/bin" 2>/dev/null || true)"
[ -z "$strays" ] && ok "wrote nothing outside the SDK and bin directories" \
	|| bad "wrote outside its two directories: $(printf '%s' "$strays" | tr '\n' ' ')"

echo "=== install again"
marker="$home/EARLIER-INSTALL"
: > "$marker"
if out="$(run_installer 2>&1)"; then ok "installed over the previous install"; else bad "second install failed: $(printf '%s' "$out" | tail -3)"; fi
[ -f "$marker" ] && bad "the previous install is still there (upgrade left $marker behind)" \
	|| ok "the previous install was replaced, not merged into"
[ -x "$home/ob" ] && ok "the SDK works after the upgrade" || bad "no ob after the upgrade"
[ -d "$home.old" ] && bad "left $home.old behind" || ok "left no .old directory behind"

echo "=== somebody else's ob"
rm -f "$bin/ob"
printf '#!/bin/sh\necho not the sdk\n' > "$bin/ob"; chmod +x "$bin/ob"
out="$(run_installer 2>&1 || true)"
case "$out" in
	*"is not a link -- left alone"*) ok "refused to overwrite an ob that is not our link" ;;
	*) bad "overwrote a foreign ob (or said nothing about it)" ;;
esac
[ "$("$bin/ob")" = "not the sdk" ] && ok "the foreign ob is untouched" || bad "the foreign ob was replaced"
rm -f "$bin/ob"

echo "=== uninstall"
run_installer >/dev/null 2>&1
printf '#!/bin/sh\necho mine\n' > "$bin/other"; chmod +x "$bin/other"
out="$(sh "$installer" --uninstall --dir "$home" --bin "$bin" 2>&1)"
[ -d "$home" ] && bad "the SDK directory survived uninstall" || ok "removed the SDK directory"
[ -e "$bin/ob" ] && bad "the link survived uninstall" || ok "removed the link"
[ -x "$bin/other" ] && ok "left everything else in the bin directory alone" || bad "removed more than its own link"

# A link that points somewhere else is not ours to remove, whatever it is called.
mkdir -p "$work/elsewhere"; : > "$work/elsewhere/ob"; chmod +x "$work/elsewhere/ob"
ln -sf "$work/elsewhere/ob" "$bin/ob"
sh "$installer" --uninstall --dir "$home" --bin "$bin" >/dev/null 2>&1
[ -L "$bin/ob" ] && ok "left a link that points outside the SDK alone" || bad "removed a link that was not ours"
rm -f "$bin/ob"

echo "=== which tarball this machine asks for"
# uname first on PATH, so the resolution can be checked for machines this one is not. No network:
# the run is expected to stop at the download, and what is read is the asset name in the message.
fakebin="$work/fakebin"; mkdir -p "$fakebin"
probe() {   # probe <uname -s> <uname -m> -> what install.sh says
	printf '#!/bin/sh\ncase "$1" in -s) echo %s ;; -m) echo %s ;; *) echo %s ;; esac\n' "$1" "$2" "$1" > "$fakebin/uname"
	chmod +x "$fakebin/uname"
	PATH="$fakebin:$PATH" A2SDK_REPO=example/nowhere sh "$installer" --version 0000.00.00 \
		--dir "$work/none" --bin "$work/none" 2>&1 || true
}
case "$(probe Linux x86_64)" in
	*"minia2-sdk-0000.00.00-linux-amd64.tar.gz"*) ok "x86-64 Linux asks for the linux-amd64 tarball" ;;
	*) bad "x86-64 Linux resolved to: $(probe Linux x86_64 | tr '\n' ' ')" ;;
esac
case "$(probe Linux aarch64)" in
	*"minia2-sdk-0000.00.00-linux-arm64.tar.gz"*) ok "AArch64 Linux asks for the linux-arm64 tarball" ;;
	*) bad "AArch64 Linux resolved to: $(probe Linux aarch64 | tr '\n' ' ')" ;;
esac
case "$(probe Linux riscv64)" in
	*"no SDK build for Linux on riscv64"*) ok "a machine with no build is told so, and where to look" ;;
	*) bad "an unsupported machine was not refused: $(probe Linux riscv64 | tr '\n' ' ')" ;;
esac

echo
if [ "$fail" = 0 ]; then echo "install-check: ok"; else echo "install-check: FAILED"; fi
exit "$fail"
