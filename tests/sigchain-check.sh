#!/usr/bin/env bash
#
# Faults on a thread that is not A2's go back to the handler that was there before A2.
#
# A2 installs its trap handler for the whole process, and a process is not always ours alone: an
# Android application belongs to ART first, and ART catches SIGSEGV to check for nil itself. So the
# runtime remembers what it displaced and, when a fault arrives on a thread it has no process for,
# hands the signal back instead of reporting a trap over a stack it knows nothing about.
#
# Checked here without Android, because nothing about it is Android's: tests/sigchain.c installs its
# own SIGSEGV handler, starts the ordinary host image on a thread of its own through the loader in
# android/a2boot.c, and then faults on the thread that stayed behind -- foreign to A2 by construction,
# since A2 never entered it.
#
# Two runs, and the pair is the point:
#   foreign  the fault is on the C thread and the C handler must report it, after the shell's banner
#            proves A2 was up and had taken the signal over;
#   our own  the image faults on a thread of its own (a store to an unmapped page from a module
#            compiled on the spot) and A2 must report the trap while the C handler stays silent.
#
# Needs a C compiler and the host image (`task Linux64`); nothing else.
#
# Usage: tests/sigchain-check.sh [build directory]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$root/target/Linux64}"
case "$build" in /*) ;; *) build="$PWD/$build" ;; esac

oberon="$build/oberon"
if [ ! -x "$oberon" ]; then
	echo "no built runtime in $build; run 'task Linux64' first" >&2
	exit 2
fi

cc="${CC:-cc}"
command -v "$cc" >/dev/null 2>&1 || { echo "[SKIP] the signal chaining check needs a C compiler" >&2; exit 2; }

# The loader in a2boot.c maps the image itself, so it only works where it knows the relocation and
# the machine: x86-64 and AArch64. Anywhere else there is nothing to check here.
case "$(uname -m)" in
	x86_64|aarch64|arm64) ;;
	*) echo "[SKIP] the image loader only maps x86-64 and AArch64 images" >&2; exit 2 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

harness="$work/sigchain"
if ! build_log=$("$cc" -O2 -Wall -DA2BOOT_NO_MAIN -o "$harness" \
		"$root/tests/sigchain.c" "$root/android/a2boot.c" -lpthread 2>&1); then
	echo "the signal chaining harness did not build:" >&2
	printf '%s\n' "$build_log" | tail -20 >&2
	exit 1
fi

marker='sigchain: the handler installed before A2 was given the signal'

# --- the fault on a thread A2 does not know ------------------------------------------------------
#
# stdin is held open by a sleep rather than closed: the shell spins on end of input instead of
# leaving, and the image has to stay alive until the fault comes.
status=0
foreign=$( (cd "$build" && sleep 30 \
	| PWD="$build" A2_IMAGE="$oberon" timeout 60 "$harness" run oberon.cfg 2>&1) | tr -d '\r' ) || status=$?

if [ "$status" -ne 0 ]; then
	echo "the run that faults on a foreign thread left with $status:" >&2
	printf '%s\n' "$foreign" | tail -30 >&2
	exit 1
fi
# The banner comes from the shell, which starts after Traps has installed the handler: banner first
# and marker after is what says A2 had taken the signal over and gave it back anyway.
if ! printf '%s\n' "$foreign" | grep -q 'Shell v'; then
	echo "the image did not reach its shell before the fault, so nothing was proved:" >&2
	printf '%s\n' "$foreign" | tail -30 >&2
	exit 1
fi
if ! printf '%s\n' "$foreign" | grep -qF "$marker"; then
	echo "the fault on a foreign thread did not reach the handler that was installed before A2:" >&2
	printf '%s\n' "$foreign" | tail -30 >&2
	exit 1
fi
if printf '%s\n' "$foreign" | grep -q 'Trap 11'; then
	echo "A2 reported a trap for a thread that is not its own:" >&2
	printf '%s\n' "$foreign" | tail -30 >&2
	exit 1
fi

# --- the fault on a thread of A2's own -----------------------------------------------------------
#
# The other half: chaining must not swallow our own faults. The module is compiled by the running
# image and asked for by the shell, and the trap report has to come from A2.
cat > "$work/SigChainFault.Mod" <<'EOF'
MODULE SigChainFault;	(* a fault of our own, for tests/sigchain-check.sh *)
IMPORT SYSTEM;

	PROCEDURE Do*;
	BEGIN
		SYSTEM.PUT32( 1000H, 1 )	(* a page no one maps *)
	END Do;

END SigChainFault.
EOF

status=0
ours=$( (cd "$build" && printf 'Compiler.Compile %s\nSigChainFault.Do\nexit\n' "$work/SigChainFault.Mod" \
	| PWD="$build" A2_IMAGE="$oberon" A2_SIGCHAIN_QUIET=1 timeout 60 "$harness" run oberon.cfg 2>&1) \
	| tr -d '\r' ) || status=$?

if [ "$status" -ne 0 ]; then
	echo "the run that faults inside A2 left with $status:" >&2
	printf '%s\n' "$ours" | tail -30 >&2
	exit 1
fi
if printf '%s\n' "$ours" | grep -qF "$marker"; then
	echo "a fault on A2's own thread was handed to the handler installed before A2:" >&2
	printf '%s\n' "$ours" | tail -30 >&2
	exit 1
fi
if ! printf '%s\n' "$ours" | grep -q 'Trap 11'; then
	echo "A2 did not report the trap for a fault on a thread of its own:" >&2
	printf '%s\n' "$ours" | tail -30 >&2
	exit 1
fi
if ! printf '%s\n' "$ours" | grep -q 'SigChainFault.Do'; then
	echo "the trap A2 reported does not name the procedure that faulted:" >&2
	printf '%s\n' "$ours" | tail -30 >&2
	exit 1
fi

echo "signal chaining: a foreign thread's fault went to the previous handler, ours stayed with A2"
