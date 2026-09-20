#!/usr/bin/env bash
#
# Shared Android SDK/NDK discovery for shell scripts. The NDK names its host tools by the
# machine that runs them, not the Android target, so keep that choice in one place.

android_posix_path() {
	local path="$1"
	if command -v cygpath >/dev/null 2>&1; then
		case "$path" in
			[A-Za-z]:\\*|[A-Za-z]:/*) cygpath -u "$path"; return ;;
		esac
	fi
	printf '%s\n' "$path"
}

android_latest_dir() {
	local parent
	parent="$(android_posix_path "$1")"
	[ -d "$parent" ] || return 1
	if sort -V </dev/null >/dev/null 2>&1; then
		ls -d "$parent"/* 2>/dev/null | sort -V | tail -1
	else
		ls -d "$parent"/* 2>/dev/null | sort | tail -1
	fi
}

android_tool_in_dir() {
	local dir="$1" tool="$2" candidate
	for candidate in "$dir/$tool" "$dir/$tool.exe" "$dir/$tool.cmd" "$dir/$tool.bat"; do
		[ -f "$candidate" ] || continue
		case "$candidate" in
			*.cmd|*.bat) ;;
			*) [ -x "$candidate" ] || continue ;;
		esac
		printf '%s\n' "$candidate"
		return 0
	done
	return 1
}

android_find_sdk() {
	local sdk candidate
	sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
	if [ -n "$sdk" ]; then
		sdk="$(android_posix_path "$sdk")"
	fi
	if [ -z "$sdk" ]; then
		for candidate in "$HOME/Android/Sdk" /c/Android/SDK /data/Android/Sdk /opt/android-sdk; do
			[ -d "$candidate" ] && sdk="$candidate" && break
		done
	fi
	[ -n "$sdk" ] && [ -d "$sdk" ] || return 1
	printf '%s\n' "$sdk"
}

android_find_ndk() {
	local sdk="${1:-}" ndk candidate latest
	ndk="${ANDROID_NDK:-${NDK:-}}"
	if [ -n "$ndk" ]; then
		ndk="$(android_posix_path "$ndk")"
		[ -d "$ndk" ] || return 1
		printf '%s\n' "$ndk"
		return 0
	fi
	for candidate in "$HOME/Android/Sdk/ndk" "${sdk:+$sdk/ndk}" /c/Android/SDK/ndk /data/Android/Sdk/ndk /opt/android-sdk/ndk; do
		[ -n "$candidate" ] && [ -d "$candidate" ] || continue
		latest="$(android_latest_dir "$candidate")"
		[ -n "$latest" ] && printf '%s\n' "$latest" && return 0
	done
	return 1
}

android_ndk_prebuilt_bin() {
	local ndk root system machine tag dir
	ndk="$(android_posix_path "$1")"
	root="$ndk/toolchains/llvm/prebuilt"
	[ -d "$root" ] || return 1
	system="$(uname -s)"
	machine="$(uname -m)"

	case "$system" in
		MINGW*|MSYS*|CYGWIN*) set -- windows-x86_64 ;;
		Darwin*)
			case "$machine" in
				arm64|aarch64) set -- darwin-arm64 darwin-x86_64 ;;
				*)             set -- darwin-x86_64 darwin-arm64 ;;
			esac ;;
		Linux*) set -- linux-x86_64 ;;
		*)      set -- ;;
	esac
	for tag in "$@"; do
		dir="$root/$tag/bin"
		[ -d "$dir" ] && printf '%s\n' "$dir" && return 0
	done
	for dir in "$root"/*/bin; do
		[ -d "$dir" ] && printf '%s\n' "$dir" && return 0
	done
	return 1
}

android_ndk_tool() {
	local bin
	bin="$(android_ndk_prebuilt_bin "$1")" || return 1
	android_tool_in_dir "$bin" "$2"
}

android_sdk_tool() {
	local sdk="$1" relative="$2" tool="$3"
	android_tool_in_dir "$sdk/$relative" "$tool"
}
