#!/usr/bin/env bash
#
# What differs between the platforms this tree builds, in one place for the shell -- the same
# role configs/env.yml plays for the Taskfile, and the extensions come straight out of it rather
# than being written down a second time. Sourced, not run:
#
#     . tests/platform-env.sh && platform_env Linux32
#
# leaves EXTENSION, SYMBOLFILEEXCEPTION, COMPILEOPTIONS (the compiler's -p), FILENAME and
# MODULE_LIST as env.yml has them, plus LINKPLATFORM (the linker's -p, empty for Windows, whose
# format flags carry it instead), OBTARGET (what `ob -t` calls this platform), FLAVOUR (what a
# release asset of it is called) and CORELIST/GUILIST (the payload this platform ships, which
# tests/gen-headless-core.sh derives from the registry).

platform_env() {
	local platform="$1" root
	root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

	# env.yml is a flat map of platform to key and value, two levels and no more.
	local line
	line="$(awk -v want="$platform" '
		/^[A-Za-z]/ { inside = ($0 == want ":") ; next }
		inside && /^[ \t]*[A-Za-z_]+:/ {
			key = $0; sub(/:.*/, "", key); gsub(/[ \t]/, "", key)
			value = $0; sub(/^[^:]*:[ \t]*/, "", value); gsub(/"/, "", value); sub(/[ \t\r]+$/, "", value)
			printf "%s=%s\n", key, value
		}' "$root/configs/env.yml")"
	[ -n "$line" ] || { echo "no platform $platform in configs/env.yml" >&2; return 1; }
	local pair
	while IFS= read -r pair; do
		[ -n "$pair" ] || continue
		export "${pair%%=*}=${pair#*=}"
	done <<< "$line"

	case "$platform" in
		Win32|Win64) LINKPLATFORM="" ;;
		*)           LINKPLATFORM="$platform" ;;
	esac
	case "$platform" in
		Linux64)  OBTARGET=linux64; FLAVOUR=linux-amd64 ;;
		Linux32)  OBTARGET=linux32; FLAVOUR=linux-386 ;;
		LinuxARM) OBTARGET=arm32;   FLAVOUR=linux-armhf ;;
		Win64)    OBTARGET=win64;   FLAVOUR=windows-amd64 ;;
		*) echo "no SDK flavour for platform $platform" >&2; return 1 ;;
	esac
	# Linux32 shares the x86-64 payload on purpose: i386 closes over the same modules and differs
	# only in word size. LinuxARM does not -- Builtins imports FPE64 there and nowhere else.
	case "$platform" in
		Win64)    CORELIST=configs/headless-core-win64.txt; GUILIST=configs/gui-core-win64.txt ;;
		LinuxARM) CORELIST=configs/headless-core-armhf.txt; GUILIST=configs/gui-core-armhf.txt ;;
		*)        CORELIST=configs/headless-core.txt;       GUILIST=configs/gui-core.txt ;;
	esac
	export LINKPLATFORM OBTARGET FLAVOUR CORELIST GUILIST
}
