# minia2 2026.09.02 — a debugger, in three editors

Breakpoints and stepping for Active Oberon, driven from whichever editor you already use.

`ob dap` is an ordinary debug adapter, so nothing editor-specific had to be written: an editor
that speaks the Debug Adapter Protocol talks to the SDK directly. A breakpoint is one instruction
written into the program's own code and taken back out whenever the program stands still — `INT 3`
on x86-64, `BRK #0` on AArch64 — and the line table it needs is the one the compiler's backend
already computed and used to throw away. `--debug` keeps it.

- **Neovim** — through `nvim-dap`; the snippet is in [`docs/IDE.md`](https://github.com/active-oberon/minia2/blob/main/docs/IDE.md) §1f.
- **VS Code** — the `.vsix` beside these tarballs. `F5` on an open `.Mod` file needs no
  `launch.json`: the open file is the program and its `Do` is what runs.
- **PET, A2's own editor** — the same code with the protocol taken off it, so the desktop
  debugs itself: `F9` marks a line, `ALT-F9` runs the page's module or lets a stopped program
  go on, `F8` steps, `ALT-F3` lets go for good. Where the program stopped goes into the log with
  the parameters and locals of the frame, and the caret moves there.

What you get at a stop: the call stack as `Module.Procedure file:line`, and each frame's
parameters and locals. Stepping is by statement. Two ceilings worth knowing: a step does not
enter a call (that needs an instruction decoder), and the line table lives in the process that
compiled — so `ob dap` debugs what it built, which is what `F5` and `ALT-F9` both do anyway.

## Also in this release

- **Syntax highlighting through tree-sitter** for Neovim, Helix and Zed —
  `editors/tree-sitter/`, generated from the EBNF in the compiler's own parser. Conditional
  compilation is bracketed but no longer dimmed: the grammar reads the first branch and the
  compiler without `-D` takes `#ELSE`, so dimming was wrong on every x86 host.
- The window a hot key moves a whole view over no longer takes the keyboard focus off-screen
  with it — the view follows the window.
- `CTRL+Q` is named for what it does, which is reboot; `CTRL+SHIFT+Q` leaves for good.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/active-oberon/minia2/main/sdk/install.sh | sh
```

Or unpack a tarball below and run `./ob`. Four hosts: x86-64 Linux, Windows, AArch64 Linux
(glibc — a Pi 4/5, an ARM server, a phone under `proot-distro`) and AArch64 Android (Bionic, for
Termux itself). `install.sh` picks between the last two by looking at which loader the machine
has. `SHA256SUMS` covers every asset.
