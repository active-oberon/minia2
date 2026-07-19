# minia2

A slimmed, self-hosting **A2 (Active Oberon) desktop for development** — kernel +
Fox compiler + window manager + PET IDE + the useful GUI tooling, with the obsolete
parts of upstream A2 removed (old Oberon subsystem, OberonAnts, games/demos,
education examples, test corpora, EFI boot, CJK/printer fonts).

Carved from the full A2 tree: **762 source modules** (of ~1783 upstream) built into a
graphical desktop. Not the ETH "minimal core" (that is a ~430-module console system) —
this keeps the full GUI dev environment (GUI Builder, DTP, skins, file manager,
inspectors, repositories, terminals) minus the junk.

## Targets

Linux64 and Win64 only. The `compilers/` bootstrap binaries are self-contained
A2+Fox executables; 32-bit/ARM are not built.

## Build

```sh
task                              # build all platforms (Linux64 + Win64)
task build-platform PLATFORM=Linux64
```

Output lands in `target/<PLATFORM>/`. Launch the desktop with `target/Linux64/a2.sh`
(needs an X display) or `target/Win64/a2.bat`.

**Building the Windows version:** cross-compile `Win64` from a native Linux
filesystem. Use a regular Linux installation, a Linux virtual machine, or WSL2.
When using WSL2, clone or copy the repository into the WSL2 filesystem (for
example, `~/src/minia2`) before running `task Win64`. Do not build it directly
from a mounted Windows drive such as `/mnt/c` or `/mnt/d`: the A2 build can fail
to import symbol files created earlier in the same compilation pass.

The build drives A2's own `Release.Build` with a package `--exclude` list
(`MINI_EXCLUDE` in `Taskfile.yml`) then links the static kernel from
`configs/moduleList*.txt`.

## Layout

| Path | What |
|------|------|
| `compilers/{Linux64,Win64}/` | bootstrap A2+Fox binaries (the only prebuilt artifacts) |
| `source/` | the 762-module closure (`.Mod`) |
| `configs/` | `env.yml` (per-target build flags) + static-link module lists |
| `data/` | fonts, config XML, skins, curated `MenuPage*.XML`, `Release.Tool` |
| `data/Release.Tool` | package definitions (fork-local: WebBrowser + IMAP mail removed) |
| `data/Linux.BuildMenu.Tool` | recipe to regenerate the 8-tab start menu (needs a display) |

## Start menu

8 tabs (Docu, System, Files, Tools, Edit, Develop, Inspect, Looks). Regenerate with
`MenuPages.Generate` via `data/Linux.BuildMenu.Tool` inside a running graphical A2;
the generated `data/MenuPage*.XML` are shipped as static files.
