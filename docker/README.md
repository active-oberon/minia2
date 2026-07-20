# minia2 as a Docker SDK (PoC)

A Go-style toolchain for **A2 / Active Oberon**, packaged as one Docker image.
No per-OS host port needed — it runs anywhere Docker does (Linux, macOS, Windows
via Docker Desktop / WSL2). The compiled output is a Linux glibc ELF.

This is a proof of concept: it wraps the repo's existing self-hosting toolchain
(the `oberon` runtime + the precompiled standard library that `task Linux64`
produces) behind an `ob` CLI. It does **not** yet produce a single standalone
native executable with the runtime baked in — see *Limitations* below.

## Build

From the repository root (the build compiles the runtime + stdlib from source):

```sh
docker build -f docker/Dockerfile -t minia2-sdk .
```

## Use

Mount your working directory at `/work` and call `ob`:

```sh
# print the SDK banner (default command)
docker run --rm minia2-sdk

# compile + run a module's Do command (like `go run`)
docker run --rm -v "$PWD:/work" minia2-sdk run Hello.Mod

# run a named exported command instead of Do
docker run --rm -v "$PWD:/work" minia2-sdk run Hello.Mod Main

# compile a module to an object file (.GofUu) in ./out
docker run --rm -v "$PWD:/work" minia2-sdk compile Hello.Mod -o out

# interactive A2 shell
docker run --rm -it minia2-sdk repl
```

A minimal module (`docker/examples/Hello.Mod`):

```oberon
MODULE Hello;
IMPORT KernelLog;
	PROCEDURE Do*;
	BEGIN KernelLog.String("Hello from A2 / Active Oberon!"); KernelLog.Ln
	END Do;
END Hello.
```

## How it works

| Piece | Role |
|-------|------|
| `/opt/a2sdk/oberon` | the self-contained A2 runtime (statically-linked kernel + Fox compiler + linker), a dynamically-linked glibc ELF |
| `/opt/a2sdk/lib/*.SymUu`, `*.GofUu` | the **headless-core** standard library — 310 modules (symbol + object files) |
| `ob` | the CLI wrapper hiding `.cfg` / `System.DoFile` / search-path plumbing |

The image is ~134MB, trimmed from a naive ~255MB in three steps:

- **No desktop `data/`** (fonts, wallpapers, skins — ~48MB): headless compile/run
  never reads it.
- **No extra apt packages**: the runtime's shared libs (`libc`, `libdl`,
  `ld-linux`) already ship in `debian:bookworm-slim`.
- **Headless-core stdlib only** (~18MB saved): of the 712 built stdlib modules,
  only the 310 whose import closure never reaches the window manager / display /
  raster are shipped. See `docker/headless-core.txt`; regenerate it with
  `docker/gen-headless-core.sh` (it taint-propagates the GUI roots through A2's
  own `DependencyWalker`). The kept set is closed under imports, so every retained
  module both compiles and loads. Importing a GUI module (e.g. `WMGraphics`) is
  a compile error by design — use the full desktop build for GUI work.

The A2 compiler resolves imported modules from its **current working directory**,
not from a configurable search path. So `ob` runs each build inside a private
scratch dir seeded with symlinks to the stdlib, keeping the shared SDK read-only
and letting builds run concurrently. `compile` then emits `Module.GofUu`; `run`
compiles and hands the module name to the runtime, which loads and executes it.

## Limitations (PoC scope)

- **Not a single static binary.** `ob run` uses the runtime + dynamically loaded
  object files (the `go run` model), not a `go build`-style standalone ELF with
  the runtime linked in. Baking `Linker.Link` into an `ob build` verb is the next
  step.
- **Linux ELF / Win PE output only** — never native macOS Mach-O. The base must be
  glibc (the runtime links `libc`/`libdl`); musl/Alpine will not work.
- Dead-code elimination is module-granular, so binaries are larger than Go's.
