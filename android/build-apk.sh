#!/usr/bin/env bash
#
# Build the A2 Android application: an APK with no Java in it at all.
#
# A NativeActivity needs no class of its own -- the framework's own android.app.NativeActivity is
# named in the manifest and told which library to load -- so there is nothing to compile for the
# virtual machine, and therefore no reason to bring in Gradle. What is left is four tools that come
# with the SDK: aapt2 to make the package, zipalign to align it, apksigner to sign it, and keytool
# (from the JDK) once, for a debug key.
#
# The image travels as an asset, because the application cannot read /data/local/tmp, where the
# command-line bundle lives: that directory belongs to the shell user. It is unpacked into the
# application's own directory on first run (android/a2app.c).
#
# Usage: android/build-apk.sh [-i image] [-o out-dir] [--install]

set -eo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
image="$root/target/A64/android/oberon.img"
out="$root/target/A64/apk"
install=0
while [ $# -gt 0 ]; do
	case "$1" in
		-i|--image) image="$2"; shift 2 ;;
		-o|--output) out="$2"; shift 2 ;;
		--install) install=1; shift ;;
		*) echo "unknown option: $1" >&2; exit 2 ;;
	esac
done

sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [ -z "$sdk" ]; then
	for candidate in "$HOME/Android/Sdk" /data/Android/Sdk /opt/android-sdk; do
		[ -d "$candidate" ] && sdk="$candidate" && break
	done
fi
[ -d "$sdk" ] || { echo "no Android SDK: set ANDROID_SDK_ROOT" >&2; exit 2; }

# Newest of each, so that this does not name a version that will be gone next month.
tools="$(ls -d "$sdk"/build-tools/* 2>/dev/null | sort -V | tail -1)"
platform="$(ls -d "$sdk"/platforms/android-* 2>/dev/null | sort -V | tail -1)"
[ -n "$tools" ] && [ -n "$platform" ] || { echo "no build-tools or platform in $sdk" >&2; exit 2; }

ndk="${ANDROID_NDK:-${NDK:-}}"
if [ -z "$ndk" ]; then
	for candidate in "$HOME/Android/Sdk/ndk" "$sdk/ndk" /opt/android-sdk/ndk; do
		[ -d "$candidate" ] || continue
		ndk="$(ls -d "$candidate"/* 2>/dev/null | sort -V | tail -1)"
		[ -n "$ndk" ] && break
	done
fi
clang="$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android28-clang"
[ -x "$clang" ] || { echo "no NDK compiler: looked for $clang" >&2; exit 2; }
[ -f "$image" ] || { echo "no image at $image (build one with tests/a64-bundle.sh --android)" >&2; exit 2; }

rm -rf "$out"
mkdir -p "$out/lib/arm64-v8a" "$out/assets" "$out/res"

# The library. a2boot.c is compiled without its main -- here the entry point is the framework's
# call, not a command line -- and a2app.c supplies that entry.
"$clang" -O2 -Wall -shared -fPIC -o "$out/lib/arm64-v8a/liba2app.so" \
	-DA2BOOT_NO_MAIN "$root/android/a2app.c" "$root/android/a2boot.c" \
	-landroid -llog
cp "$image" "$out/assets/oberon.img"

# The display, the window manager above it and the demos travel as object files rather than inside the
# image: the image is the same 32-module runtime the command line bundle uses, and A2 loads what it
# needs at run time. Taken from the lib/ directory of the bundle the image came from, which is where
# tests/a64-bundle.sh puts them.
#
# The window manager is thirteen modules and some 900 KB of objects, and it is what makes the picture
# on the screen A2's system rather than one module that owns the frame buffer: a background, a window
# with decoration, an event loop, and a finger that drags the window by its title bar.
objects="$(dirname "$image")/lib"
missing=""
while read -r module; do
	case "$module" in ''|'#'*) continue ;; esac
	if [ -f "$objects/$module.GofU8" ]; then
		cp "$objects/$module.GofU8" "$out/assets/"
	else
		missing="$missing $module"
	fi
done < "$root/configs/moduleListAndroidApp.txt"
if [ -n "$missing" ]; then
	echo "no object files for:$missing in $objects" >&2
	echo "build the bundle first: tests/a64-bundle.sh --android -o $(dirname "$image")" >&2
	exit 2
fi

# hasCode="false" is what says there is no Java here; without it the runtime looks for classes.dex
# and refuses to start. android.app.lib_name names the library above, without the lib prefix.
cat > "$out/AndroidManifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
	package="live.minitok.a2"
	android:versionCode="1"
	android:versionName="0.1">
	<uses-sdk android:minSdkVersion="28" android:targetSdkVersion="34" />
	<application android:label="A2" android:hasCode="false" android:debuggable="true">
		<activity android:name="android.app.NativeActivity"
			android:label="A2"
			android:configChanges="orientation|keyboardHidden|screenSize"
			android:exported="true">
			<meta-data android:name="android.app.lib_name" android:value="a2app" />
			<intent-filter>
				<action android:name="android.intent.action.MAIN" />
				<category android:name="android.intent.category.LAUNCHER" />
			</intent-filter>
		</activity>
	</application>
</manifest>
XML

# A debug key, made once and kept: reinstalling over an existing application requires the same
# signature, so a key regenerated every build would mean uninstalling every build.
keystore="$root/target/A64/debug.keystore"
if [ ! -f "$keystore" ]; then
	keytool -genkeypair -keystore "$keystore" -alias a2 -storepass android -keypass android \
		-keyalg RSA -keysize 2048 -validity 10000 -dname "CN=A2 debug" >/dev/null 2>&1
	echo "made a debug key at ${keystore#$root/}"
fi

"$tools/aapt2" link \
	-I "$platform/android.jar" \
	--manifest "$out/AndroidManifest.xml" \
	-A "$out/assets" \
	-o "$out/unaligned.apk" \
	--auto-add-overlay

# aapt2 does not put the libraries in; they are added to the zip afterwards, uncompressed and
# aligned, which is what the loader wants when it maps them straight out of the package.
(cd "$out" && zip -q -r -X -0 unaligned.apk lib)

"$tools/zipalign" -f -p 4 "$out/unaligned.apk" "$out/a2.apk"
"$tools/apksigner" sign --ks "$keystore" --ks-pass pass:android --key-pass pass:android \
	--min-sdk-version 28 "$out/a2.apk"
rm -f "$out/unaligned.apk" "$out/a2.apk.idsig"

echo "apk: $out/a2.apk ($(du -h "$out/a2.apk" | cut -f1))"

if [ "$install" = 1 ]; then
	adb install -r "$out/a2.apk"
	echo "installed; start it with:"
	echo "  adb shell am start -n live.minitok.a2/android.app.NativeActivity"
	echo "  adb logcat -s A2"
fi
