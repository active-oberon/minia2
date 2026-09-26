# minia2 2026.09.26

This release updates the six native SDK archives for Linux x86-64, Linux i386,
Linux armhf, Linux AArch64, Android AArch64, and Windows x86-64. It also includes
Linux and Windows desktop builds, the VS Code extension, installer, and checksums.

## Changes since 2026.09.14

- Added the AArch64 instruction set and assembler to the compiler tree.
- Expanded standard-library tests and fixed defects in numbers, text, HTTP,
  collections, converters, parsers, and SVG handling.
- Updated the AArch64 standard-library module list for the new test dependencies.
  CI now checks that this generated list stays in sync with source and tests.
- Corrected X11 window creation so `--gui=800x600` requests its final size before
  the window manager sees it. This keeps the demo window beside an editor.

## Downloads

The release includes `minia2-sdk-2026.09.26-<platform>.tar.gz` for
`linux-amd64`, `linux-386`, `linux-armhf`, `linux-arm64`, `android-arm64`, and
`windows-amd64`. The desktop archives are `minia2-Linux64-2026.09.26.zip` and
`minia2-Win64-2026.09.26.zip`. The VS Code `.vsix`, installer, and `SHA256SUMS`
are published alongside them.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/active-oberon/minia2/2026.09.26/sdk/install.sh | sh -s -- --version 2026.09.26
```

On Windows, unpack the Windows SDK archive and run `ob.exe`. See the
[SDK manual](https://github.com/active-oberon/minia2/blob/2026.09.26/docs/SDK.md)
and [IDE guide](https://github.com/active-oberon/minia2/blob/2026.09.26/docs/IDE.md).

## Known limits

The 32-bit SDK smoke checks run in CI, but the complete 32-bit suites still have
known unresolved failures. Hardware validation of this release has not been done.
Native macOS and musl-based Linux are not supported.
