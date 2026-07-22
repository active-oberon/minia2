# minia2 as a Docker SDK (PoC)

A Go-style toolchain for **A2 / Active Oberon**, packaged as one Docker image.
No per-OS host port needed — it runs anywhere Docker does (Linux, macOS, Windows
via Docker Desktop / WSL2). The compiled output is a Linux glibc ELF.

It wraps the repo's self-hosting toolchain (the `oberon` runtime + the precompiled
standard library that `task` produces) behind an `ob` CLI that feels like Go:
`ob run` (compile+run), `ob build` (standalone native executable with the runtime
baked in — Linux ELF or, via `-t win64`, a Windows PE `.exe`), `ob compile`, and
`ob lsp` (a language server with diagnostics for your editor). See *Limitations*
for the current scope.

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

# build a standalone native executable with the runtime baked in (like `go build`)
docker run --rm -v "$PWD:/work" minia2-sdk build Hello.Mod -o hello
# ...then run it on any glibc Linux box — no A2 install needed. It auto-runs the
# module's Do command (no argument required):
./hello                   #  ->  Hello from A2 / Active Oberon!

# cross-build a Windows .exe from the same Linux image
docker run --rm -v "$PWD:/work" minia2-sdk build Hello.Mod -t win64 -o hello.exe
# -> hello.exe : PE32+ console executable for Windows x86-64

# run a named exported command instead of Do
docker run --rm -v "$PWD:/work" minia2-sdk run Hello.Mod Main

# compile a module to an object file (.GofUu) in ./out
docker run --rm -v "$PWD:/work" minia2-sdk compile Hello.Mod -o out

# interactive A2 shell
docker run --rm -it minia2-sdk repl

# language server (LSP over stdio) — editors spawn this; see "Editor setup" below
docker run --rm -i -v "$PWD:/work" minia2-sdk lsp
```

### A shorter command: the `ob` alias

Typing the full `docker run …` each time is tedious. Add an alias to your
`~/.bashrc` (or `~/.zshrc`) so the SDK feels like a locally installed `ob` tool:

```sh
alias ob='docker run --rm -v "$PWD:/work" minia2-sdk'
# interactive verbs (repl) also want a TTY:
alias obit='docker run --rm -it -v "$PWD:/work" minia2-sdk'
```

Reload the shell (`source ~/.bashrc`) and the workflow becomes:

```sh
ob run     Hello.Mod             # compile + run (go run)
ob build   Hello.Mod -o hello    # standalone Linux binary (go build)
./hello                          # run it — no A2 needed, auto-runs Hello.Do
ob build   Hello.Mod -t win64 -o hello.exe   # cross-build a Windows .exe
ob compile Hello.Mod -o out      # just the .GofUu object file
ob version                       # SDK banner
obit repl                        # interactive A2 shell
```

> **Quoting matters.** Use single quotes and `"$PWD"` exactly as above. `$PWD`
> is left unexpanded in the alias definition and resolves to the *current*
> directory each time you call `ob` — that is what bind-mounts your sources into
> `/work`. Writing `"PWD"` (no `$`) makes Docker create an empty **named volume**
> called `PWD` instead, and every file lands as "no such file: Hello.Mod".

## Editor setup (LSP)

`ob lsp` is an [LSP](https://microsoft.github.io/language-server-protocol/) server
speaking JSON-RPC over stdio. It provides:

- **diagnostics** (syntax + semantic errors/warnings) on **open** and **save**, so
  errors refresh on `:w` and clear once fixed rather than flickering per keystroke;
  add **`--live`** to also re-check on change (the client debounces).
- **hover** — type, kind and doc-comment of the symbol under the cursor (resolves
  across modules: hovering `KernelLog.Int` shows its real signature). Works on
  use-sites inside procedures and object/record methods.
- **go-to-definition** — jumps to the declaration. Same-file, and **across modules**:
  a symbol from another project module opens that module's source (a sibling in the
  mounted directory); a standard-library symbol opens its source too when you expose a
  source tree (see *stdlib jumps* below).
- **document symbols** — a hierarchical outline of the module: types with their fields
  and methods as children, plus procedures, variables and constants. Powers the
  editor's outline/breadcrumbs (the equivalent of PET's module-tree side panel).
- **completion** (trigger `.`, or on demand) — after `Mod.` the imported module's
  exported symbols; after `var.` the fields and methods of its record/object type
  (following the base-type chain); otherwise keywords, imported module names and the
  current module's own declarations. Each item carries its kind and signature.
- **signature help** (trigger `(` / `,`) — while typing a call, shows the procedure's
  parameter list and highlights the active argument. Works for `Mod.Proc(`, `proc(`
  and `obj.Method(`.
- **find references** — every use-site of the symbol under the cursor, plus its
  declaration. Project-wide for module-level symbols and record/object members (scans
  the sibling modules that mention the owner), current-file only for locals.

**Project-aware.** The server ships every standard-library symbol (`.SymUu`), and if
you mount your project sources at `/work` it resolves your own modules too — building
any missing dependency's symbols on demand from its `.Mod` source (imports resolve
transitively). So diagnostics/hover work on real multi-module code, not just
single files against the stdlib. Hover and go-to-definition work both on *statement*
use-sites and on *declaration-site* type annotations (`VAR x: Mod.T`, parameter and
return types, record/object fields, and type aliases).

**Prebuilt symbols (recommended for big trees).** On-demand compilation assumes a
module `M` lives in `M.Mod`; that breaks for modules whose source is in a
platform-prefixed file (`I386.Foo.Mod` provides module `Foo`) or that don't compile
under the server's target, producing spurious *"module not loaded"* cascades. Instead,
mount your project's own build output at `/psym` — the server seeds those `.SymUu`
over the bundled stdlib, so imports resolve from the real artifacts (no on-demand
build, no module→file guessing):

```sh
docker run --rm -i -v "$PWD:/work" \
  -v "$HOME/Projects/A2/a2oberon/target/Linux64/bin:/psym:ro" minia2-sdk lsp --live
```

(The prebuilt symbols must match the server's target — `.SymUu` = Linux64/Unix64.)

**stdlib jumps.** Go-to-definition into a standard-library module needs that module's
source available to the editor. Two ways:
- edit inside a full A2 tree (e.g. `a2oberon/source`) — every module is already a
  sibling in `/work`, so stdlib jumps work with no extra setup; or
- from a small project, mount a source tree at `/libsrc` and name its host path in
  `initializationOptions.stdlibSrc`; the server then resolves stdlib symbols to it.

Point any LSP client at `docker run --rm -i -v "$PWD:/work" minia2-sdk lsp [--live]`
(the `-v` mount is what makes your project modules resolvable; `-i`, no `-t`). Add
`-v <a2-source>:/libsrc:ro` and `initializationOptions.stdlibSrc=<a2-source>` for
stdlib go-to-definition.

**Neovim** — the config-manager-agnostic way (works with NVChad/LazyVim/etc.
without touching their files): two standard Neovim runtime files.

`~/.config/nvim/ftdetect/oberon.lua`:
```lua
vim.filetype.add({ extension = { Mod = "oberon" } })
```

`~/.config/nvim/after/ftplugin/oberon.lua`:
```lua
vim.diagnostic.config({ virtual_lines = { current_line = true } })  -- full error text inline
local dir = vim.fs.dirname(vim.api.nvim_buf_get_name(0)) or vim.fn.getcwd()
local cmd = { "docker", "run", "--rm", "-i", "-v", dir .. ":/work:ro" }  -- mount project
local init = {}
local stdlib = vim.env.A2_STDLIB_SRC   -- optional: a full A2 source tree, for stdlib jumps
if stdlib and stdlib ~= "" then
  vim.list_extend(cmd, { "-v", stdlib .. ":/libsrc:ro" }); init.stdlibSrc = stdlib
end
vim.list_extend(cmd, { "minia2-sdk", "lsp", "--live" })
vim.lsp.start({
  name = "ob", cmd = cmd, root_dir = dir, init_options = init,
  flags = { debounce_text_changes = 500 },   -- live, but only after you pause typing
})
-- keymaps: K = hover, gd / <C-]> / Ctrl-Click = go to definition
vim.keymap.set("n", "K",  vim.lsp.buf.hover, { buffer = true })
vim.keymap.set("n", "gd", vim.lsp.buf.definition, { buffer = true })
```
Drop `--live` and the `flags` line for on-open/save-only. `vim.diagnostic.config`
is global — remove that line if you don't want inline text for other filetypes. Set
`export A2_STDLIB_SRC=$HOME/Projects/A2/a2oberon/source` (a full A2 tree) so
go-to-definition can reach standard-library modules from any project.

**VS Code**: use a generic LSP bridge extension (e.g. *"Generic LSP Client"*) or a
tiny extension whose `serverOptions` runs the same `docker … minia2-sdk lsp` command
with `transport: stdio` and a document selector for the `oberon` language / `*.Mod`.

**Test it without an editor** — pipe a framed session in:

```sh
printf 'Content-Length: %d\r\n\r\n%s' 78 \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}' \
  | docker run --rm -i minia2-sdk lsp
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
| `/opt/a2sdk/lib/*.SymUu`, `*.GofUu` | the **headless-core** Linux64 stdlib — 384 modules (symbol + object files) |
| `/opt/a2sdk/lib-win64/*.SymWw`, `*.GofWw` | the headless-core Win64 stdlib — 380 modules, for `build -t win64` |
| `ob` | the CLI wrapper hiding `.cfg` / `System.DoFile` / search-path plumbing |

The image is ~161MB (of which ~16MB is the optional Win64 stdlib), trimmed from a
naive ~255MB Linux-only image in three steps:

- **No desktop `data/`** (fonts, wallpapers, skins — ~48MB): headless compile/run
  never reads it.
- **No extra apt packages**: the runtime's shared libs (`libc`, `libdl`,
  `ld-linux`) already ship in `debian:bookworm-slim`.
- **Headless-core stdlib only** (~16MB saved): of the 712 built stdlib modules,
  only the 384 whose import closure never reaches the window manager / display /
  raster are shipped (this keeps the full networking stack — TCP/UDP/DNS/HTTP —
  which registers through the generic `Plugins` driver registry, not the GUI).
  See `docker/headless-core.txt`; regenerate it with
  `docker/gen-headless-core.sh` (it taint-propagates the GUI roots through A2's
  own `DependencyWalker`). The kept set is closed under imports, so every retained
  module both compiles and loads. Importing a GUI module (e.g. `WMGraphics`) is
  a compile error by design — use the full desktop build for GUI work.

The A2 compiler resolves imported modules from its **current working directory**,
not from a configurable search path. So `ob` runs each build inside a private
scratch dir seeded with symlinks to the stdlib, keeping the shared SDK read-only
and letting builds run concurrently. `compile` then emits `Module.GofUu`; `run`
compiles and hands the module name to the runtime, which loads and executes it.

`build` goes further: it compiles the module, generates a tiny boot driver
(`ObEntry`) whose module body calls your command and then exits, and invokes
`Linker.Link` to statically link the boot set (`boot-modules.txt`, minus the
interactive shell) + your module + `ObEntry` into one native executable. The
linker walks the import graph itself, so only the boot set and your module are
named; the rest of the closure is pulled in automatically. The result embeds the
whole A2 runtime and auto-runs on startup — verified by running the output alone
in a pristine `debian:bookworm-slim` container (`--network none --read-only`, no
`oberon` binary anywhere), which prints the greeting and exits 0 with no argument.

For `-t win64` the compiler still runs on Linux (it loads its backend modules as
Linux `.GofUu`) but emits Win64 `.GofWw` type-checked against the Win64 stdlib
symbols, and the linker writes a PE64 image instead of an ELF.

## Limitations (PoC scope)

- **The Win64 `.exe` needs Windows (or Wine) to run** — it is a `PE32+ console
  x86-64` image, confirmed running under Wine. Native macOS Mach-O is not
  supported at all.
- Networking on the Win64 target is incomplete (the Linux `Sockets` module has no
  Win64 build in this stdlib); the Linux target has the full TCP/UDP/HTTP stack.
- The base must be glibc (the runtime links `libc`/`libdl`); musl/Alpine will not
  work — for the SDK image and for running Linux `build` output.
- Dead-code elimination is module-granular, so binaries are larger than Go's
  (hello-world ≈ 1.3 MB — it contains the full kernel + GC + scheduler).
