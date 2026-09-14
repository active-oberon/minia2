# minia2 2026.09.14 — the SDK on six hosts

Active Oberon on the old laptop, the Raspberry Pi, the phone and the desktop:
this release adds native **i386 and armhf SDKs** alongside Linux x86-64, Windows
x86-64, AArch64 Linux and AArch64 Android. Each SDK contains `ob`, the Fox compiler
and its standard library; no separate A2 installation is needed to compile a program.

The two 32-bit SDKs have been exercised on an i386 laptop and a Raspberry Pi 2.
Release builds also run their bundle checks: i386 on the Linux runner, armhf under
QEMU. The Linux x86-64 archive carries the libraries for all five build targets:
`linux64`, `win64`, `a64`, `linux32` and `arm32`.

## Also in this release

- **Windowed programs from the SDK:** `ob run Window.Mod --gui` and
  `ob build Window.Mod --gui=800x600` open a canvas window on Linux or Windows.
  Repainting after another window covers it, window sizing and HiDPI handling
  have been corrected. The complete A2 desktop remains available separately.
- **C library bindings:** `ob bind header.h --records` reads a header through
  clang and writes an Active Oberon module, including struct layouts, union
  accessors, bit fields and fixed-arity wrappers for variadic functions.
- **GPIO on Linux:** `GPIO` uses the kernel's character-device interface directly;
  `examples/Blink.Mod` demonstrates driving a Raspberry Pi pin.
- **A larger standard library:** Unicode-aware regular expressions, hash maps,
  formatting, a monotonic clock, SHA-512, HKDF, ChaCha20-Poly1305, X25519 and Ed25519.
  Windows gains the terminal, process and local-socket interfaces; the radio
  example plays Ogg itself and uses an external player for other formats.
- **Compiler and runtime corrections:** 32-bit directory enumeration, ARM numeric
  conversions and arithmetic, floating-point literals and symbol files, Windows
  loading and command-line handling, and code/data memory protection.
  `ob build` now prefers freshly compiled objects over leftovers from `ob compile`.
- **Editor documentation refreshed:** current Neovim keys, the VS Code extension,
  debugger limits and the distinction between installed SDKs and source builds.
  Debugging remains available through `ob dap` and directly in PET.

## Downloads

All SDK archives below belong to `2026.09.14`:

- **Linux64:** `minia2-sdk-2026.09.14-linux-amd64.tar.gz` — Linux x86-64, glibc.
- **Linux32:** `minia2-sdk-2026.09.14-linux-386.tar.gz` — Linux i386, glibc.
- **LinuxARM:** `minia2-sdk-2026.09.14-linux-armhf.tar.gz` — 32-bit ARM Linux, glibc.
- **Linux AArch64:** `minia2-sdk-2026.09.14-linux-arm64.tar.gz` — 64-bit ARM Linux,
  including a glibc environment under `proot-distro` on Android.
- **Termux:** `minia2-sdk-2026.09.14-android-arm64.tar.gz` — AArch64 Android/Bionic,
  running directly in Termux without `proot`.
- **Win64:** `minia2-sdk-2026.09.14-windows-amd64.tar.gz` — Windows x86-64, `ob.exe`.

The full **A2 desktop builds** are `minia2-Linux64-2026.09.14.zip` and
`minia2-Win64-2026.09.14.zip`. The VS Code `.vsix`, installer and `SHA256SUMS`
are included alongside them.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/active-oberon/minia2/2026.09.14/sdk/install.sh | sh -s -- --version 2026.09.14
```

On Linux and Termux, the installer selects the archive for the host and installs
it into `~/.local/share/a2sdk`. Android/Bionic and Linux/glibc use different archives;
the installer distinguishes them by their loaders. On Windows, unpack the Windows
archive and run `ob.exe`. Run `ob version` to see the installed version and targets.

See the [SDK manual](https://github.com/active-oberon/minia2/blob/2026.09.14/docs/SDK.md)
and [IDE guide](https://github.com/active-oberon/minia2/blob/2026.09.14/docs/IDE.md).

## Known limits

The 32-bit SDK smoke checks pass, but the complete 32-bit suites still have known
unresolved failures, including ARM debugger and arithmetic cases. The latest ARM
fixes were checked during development; this release is not a new physical-device
validation. GUI builds use the SDK's own host target. Debugging still has one stopped
activity, no step-into and no attach to a previously built binary. Native macOS and
musl-based Linux are not supported.
