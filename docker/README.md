# minia2 as an SDK — a Docker image, or a tarball

A Go-style toolchain for **A2 / Active Oberon**. It wraps the repo's self-hosting
toolchain (the `oberon` runtime + the precompiled standard library that `task`
produces) behind an `ob` CLI that feels like Go: `ob run` (compile+run), `ob build`
(standalone native executable with the runtime baked in — Linux ELF or, via
`-t win64` / `-t a64`, a Windows PE `.exe` or an AArch64 ELF), `ob compile`, and
`ob lsp` (a language server with diagnostics for your editor). See *Limitations*
for the current scope.

**Docker is one way to have it, not the only one.** The same payload ships as a
tarball for three hosts — `linux-amd64`, `linux-arm64`, `windows-amd64` — and `ob`
finds its SDK beside itself and takes the project to be the current directory.
Which one to pick:

| | Docker image | Tarball |
|---|---|---|
| needs | Docker (Linux, macOS, Windows via Desktop/WSL2) | 64-bit Linux (x86 or ARM) + glibc, or 64-bit Windows. No shell, no runtime, nothing installed |
| get it | `docker pull puhachenko/minia2-sdk` | `curl -fsSL …/sdk/install.sh \| sh`, a release tarball, or `task bundle` |
| use it | `docker run --rm -v "$PWD:/work" minia2-sdk run Hello.Mod` | `ob run Hello.Mod` |
| editor (LSP) | a container per session, sources bind-mounted | `cmd = { "/path/to/ob", "lsp" }` |

The tarball is the better fit for an editor and for a machine where a container in the
loop is a nuisance; the image is the better fit for CI and for macOS. On Windows the
tarball is `ob.exe` and wants no bash, Cygwin or WSL.

## Build

From the repository root (both compile the runtime + stdlib from source):

```sh
task sdk                    # the image (docker build, and then a smoke test of it)
task bundle                 # the tarball: target/bundle + minia2-sdk-<version>-linux-amd64.tar.gz
task bundle-check           # unpack the tarball elsewhere and use it with an empty environment
task win-bundle             # the Windows SDK: ob.exe and the library it compiles against
task a64-bundle             # the AArch64 SDK, native on the device
```

Or by hand:

```sh
docker build -f docker/Dockerfile -t minia2-sdk .
```

## Use it without Docker

One command puts the latest release on a machine — download, unpack into
`~/.local/share/a2sdk`, link `ob` into `~/.local/bin`, nothing else touched and no
privilege asked for:

```sh
curl -fsSL https://raw.githubusercontent.com/active-oberon/minia2/main/sdk/install.sh | sh
```

`--dir`, `--bin`, `--version`, `--tarball` and `--uninstall` are the whole interface.
Or by hand, from a release tarball:

```sh
tar xzf minia2-sdk-<version>-linux-amd64.tar.gz
cd minia2-sdk-<version>-linux-amd64
./run.sh --quick                       # does this SDK work? every verb, no suites
./ob run examples/Hello.Mod
./ob build examples/Hello.Mod && ./Hello
mkdir -p ~/.local/bin && ln -sf "$PWD/ob" ~/.local/bin/ob    # `ob` on the PATH
```

Nothing is installed and nothing is written outside the directory. `ob` follows the
symlink back to the SDK, so the link above needs no environment variable; `A2SDK` still
overrides the location if you want it elsewhere. The project is the current directory
(`A2_PROJECT` overrides that), which under Docker is the `/work` mount.

For a machine that is itself AArch64 — a Pi 4/5, an ARM server, a phone under Termux —
`task a64-bundle` builds the SDK where a64 is the native target and the compiler runs on
the device. On Windows the SDK is `ob.exe` and the same library layout beside it; it
wants no bash, no Cygwin and no WSL, and `ob.exe build` writes a `.exe` natively.

## Projects of more than one module

The project is the directory you are in: every `*.Mod` at its top is compiled and importable,
so a module can import its siblings and `ob build` links the whole import closure. Nothing has
to be listed anywhere, and the order does not matter — the compiler is driven to a fixpoint
(A2's compiler does not topologically reorder a batch, so `ob` iterates instead). Modules the
one you named does not import cost a compile and nothing else; a broken one that nobody imports
does not break the build.

```sh
ob run App.Mod        # App imports Deep, Deep imports Util, all three in this directory
ob build App.Mod -o app
ob build App.Mod -t win64 -o app.exe   # siblings are compiled for the target, not the host
```

Dependencies are the other thing: `ob get github.com/user/repo` vendors them under `.a2pkg/`,
and those are populated the same way, lower tier first. A2's namespace is flat, so a name
provided twice is a collision: between two packages it is a hard error, and a module of your
own with a package's name shadows it with a warning.

Two shapes this does not cover: sources in subdirectories (only the top of the project is
read), and a project whose modules have their own build output you want reused rather than
recompiled (the language server takes `A2_SYMS` for that; the compiler does not).

## Use it with Docker

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

# ... or an AArch64 binary, for a Raspberry Pi 4/5, an ARM server, an Android chroot
docker run --rm -v "$PWD:/work" minia2-sdk build Hello.Mod -t a64 -o hello-arm64
# -> hello-arm64 : ELF 64-bit, ARM aarch64 -- run it there, or here under qemu-aarch64

# run a named exported command instead of Do
docker run --rm -v "$PWD:/work" minia2-sdk run Hello.Mod Main

# compile a module to an object file (.GofUu) in ./out
docker run --rm -v "$PWD:/work" minia2-sdk compile Hello.Mod -o out

# run the test files in the current directory (every *.Test); exit code 1 on failure
docker run --rm -v "$PWD:/work" minia2-sdk test
docker run --rm -v "$PWD:/work" minia2-sdk test CSV.Test -v

# ... eight pieces at a time, which is the same run in a fraction of the wall clock
docker run --rm -v "$PWD:/work" minia2-sdk test -j 8

# ... or compiled for AArch64 and executed under qemu-aarch64 (needs qemu in the image's host)
docker run --rm -v "$PWD:/work" minia2-sdk test -t a64

# iterate on one case: -r matches part of its name (case-insensitive)
docker run --rm -v "$PWD:/work" minia2-sdk test Utf8Strings.Execution.Test -r overlong -v

# record the cases that fail today, so only NEW failures break the build
docker run --rm -v "$PWD:/work" minia2-sdk test --write-expected a2test-expected.txt

# machine-readable summary for CI (counts + one entry per case)
docker run --rm -v "$PWD:/work" minia2-sdk test --report report.json

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
ob build   Hello.Mod -t a64 -o hello-arm64  # cross-build an AArch64 binary
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

> **Full IDE guide:** installation, every feature, keybindings and environment
> variables are in [`docs/IDE.md`](../docs/IDE.md).

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
- **semantic tokens** — resolved identifiers are classified (namespace, type,
  function, method, variable, parameter, property, enumMember) so the editor can
  colour by *meaning* on top of syntax highlighting (a field vs a local vs a
  parameter). Editors with built-in LSP semantic-token support pick this up
  automatically.
- **rename** — renames a module-level symbol (type, procedure, module variable,
  constant) and every use of it across the project as one WorkspaceEdit. Locals and
  record/object members are declined (their name+module+kind identity isn't unique
  enough to rename safely yet).
- **formatting** — reprints the whole module in Fox's canonical style, preserving the
  IMPORT list and comments. Only syntactically-valid files are formatted; the output
  is verified to re-parse.
- **code actions** — quick-fixes: **Import &lt;M&gt;** for an undeclared module
  qualifier (adds it to the IMPORT list, or a new IMPORT after the header), and
  **Comment / Uncomment** the current selection.

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

Without Docker there is nothing to mount: point `A2_SYMS` at the directory instead.

```sh
A2_SYMS=$HOME/Projects/A2/a2oberon/target/Linux64/bin ./ob lsp --live
```

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

From the tarball the command is the path to `ob` and nothing else:
`{ "/path/to/minia2-sdk-.../ob", "lsp", "--live" }` — the project is the directory the
editor is in, so there is no mount to get right and no container per session.

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
local init = {}
local stdlib = vim.env.A2_STDLIB_SRC   -- optional: a full A2 source tree, for stdlib jumps
local cmd
if vim.env.A2_OB and vim.env.A2_OB ~= "" then       -- the tarball SDK: $A2_OB is its `ob`
  cmd = { vim.env.A2_OB, "lsp", "--live" }
  if stdlib and stdlib ~= "" then init.stdlibSrc = stdlib end
else                                                -- the image: mount the project at /work
  cmd = { "docker", "run", "--rm", "-i", "-v", dir .. ":/work:ro" }
  if stdlib and stdlib ~= "" then
    vim.list_extend(cmd, { "-v", stdlib .. ":/libsrc:ro" }); init.stdlibSrc = stdlib
  end
  vim.list_extend(cmd, { "minia2-sdk", "lsp", "--live" })
end
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
go-to-definition can reach standard-library modules from any project, and
`export A2_OB=/path/to/minia2-sdk-.../ob` to use the tarball SDK instead of the image.

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
| `/opt/a2sdk/lib/*.SymUu`, `*.GofUu` | the **headless-core** Linux64 stdlib — 255 modules (symbol + object files) |
| `/opt/a2sdk/lib-win64/*.SymWw`, `*.GofWw` | the headless-core Win64 stdlib — 254 modules, for `build -t win64` |
| `/opt/a2sdk/lib-a64/*.SymU8`, `*.GofU8` | the headless-core AArch64 stdlib — 408 modules including the runtime's, for `build -t a64` |
| `ob` | the driver: one command over the compiler, the linker and the language server |

The image is ~161MB (of which ~16MB is the optional Win64 stdlib), trimmed from a
naive ~255MB Linux-only image in three steps:

- **No desktop `data/`** (fonts, wallpapers, skins — ~48MB): headless compile/run
  never reads it.
- **No extra apt packages**: the runtime's shared libs (`libc`, `libdl`,
  `ld-linux`) already ship in `debian:bookworm-slim`.
- **Only what the registry names** (~16MB saved): of the 712 built stdlib modules,
  255 are shipped. Membership is decided by `packages/std/*/a2pkg.json`: a module
  travels if a package whose `headless` is true lists it in `provides` and not in
  `graphical`, or if the import closure of such a module needs it. So the payload
  is a decision somebody wrote down package by package, and
  `docker/gen-headless-core.sh` only works it out — `bash docker/gen-headless-core.sh`
  to regenerate, `task registry` to check without writing. The check fails on a
  module in the payload that no package claims, and on a `graphical` annotation
  that no longer matches the import graph.

  It used to be the other way round: keep everything whose closure never reaches
  the window system. That is a filter for "not graphics", not for "ours", and it
  shipped 144 modules nobody had asked for — a Samba server, a TV tuner driver, a
  Fidonet client, the C# front end of a language nobody here compiles. It also
  could not tell `FoxOberonFrontend` from `FoxCSharpFrontend`: both are loaded by
  name, so both are roots that nothing imports.

  The full networking stack (TCP/UDP/DNS/HTTP) is kept — it registers through the
  generic `Plugins` driver registry, not the GUI. Windows has its own list,
  `headless-core-win64.txt`, from the Win64 closure — not a translation of the
  Linux one: `WinTrace` appears in no Linux closure and `StdIO` imports it on
  Windows. The kept set is closed under imports, so every retained module both
  compiles and loads. Importing a GUI module (e.g. `WMGraphics`) is a compile
  error by design — use the full desktop build for GUI work.

**`ob` is itself Active Oberon** (`sdk/Ob.Mod`), linked into a binary that already holds
Fox: a verb calls `Compiler.Modules` in this process rather than starting one, and an SDK
is that binary plus a library — no shell on the target, which is what lets the Windows one
be `ob.exe` and nothing else. The shell version stays in the source tree as the reference
`tests/ob-check.sh` measures this one against, verb by verb. Imports resolve through the
Files search path, so each build gets a
private scratch directory to write into and the shared SDK stays read-only; several
builds can run at once. `compile` emits `Module.GofUu`; `run` compiles and loads the
module into this same process, which is the mechanism `build` bakes into a binary.

A process is still started in the two places where the work has to be abandonable: a
test case (which may not come back) and the documentation backend (which hangs on some
modules). Both get a deadline; nothing else does.

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

`-t a64` works the same way through the A64 backend: the compiler emits `.GofU8`
against the AArch64 stdlib symbols, and the linker (`-p=LinuxA64`) writes an ELF at
`400000H` whose header the `Glue` module wrote itself. The output is dynamically
linked against `libdl.so.2` and reaches the rest of the C library through `dlopen`,
so it needs a glibc AArch64 system to run on — a Raspberry Pi 4/5 running 64 bit
Linux, an ARM server, an Android chroot, or `qemu-aarch64` with an AArch64 sysroot
(`libc6-arm64-cross` on Debian and Ubuntu).

`test` reads the test-file format the repo's own `tests/*.Test` use: `#` comments,
then cases introduced by `positive: <name>` or `negative: <name>`, each followed by
the Oberon source of that case (one or more `MODULE`s). Every case is compiled and —
unless the file's `# options` line says compile-only — loaded in a **process of its
own**, so a trapping case cannot poison the next one and no `System.Free` bookkeeping is
needed; a case that never comes back is killed on a deadline (`A2_TEST_CASE_TIMEOUT`,
seconds). A positive case must compile and run without failing, a negative one must
fail, and the verdict is the child's exit code — the child is `ob`, which answers for
itself, where the bare A2 runtime exits 0 whatever happened. Modules a case declares are
kept in the scratch directory, since the in-tree files build a shared helper module in
one case and import it from later ones. Your own `*.Mod` in `/work` are compiled first,
so tests can import the code under test.

`-t a64` runs the suites for AArch64: the cases are compiled here and executed under
`qemu-aarch64` on an image linked out of the SDK's own AArch64 objects. Without the
emulator or an AArch64 C library, the files whose cases execute are reported as
**skipped** rather than passed — saying so out loud is the whole point.

`-j N` runs N pieces of the suites at a time. Files are not the unit: 5450
of this tree's 6965 cases are in one file, so the case lists themselves are cut into
chunks, and a chunk brings with it the earlier cases its own cases import (found from
the IMPORT clauses at parse time, replayed compile-only in the chunk's own directory).
Output is buffered per chunk and printed in order, so a parallel run reads exactly like
a sequential one: this tree's 6965 cases give the same 7034 verdict lines in the same
order, in **2m31s on eight cores against 19m02s on one**.

This deliberately does *not* use the in-tree `FoxTest`/`TestSuite` harness: their
import closure reaches `Texts` → `TextUtilities` → `Codecs` → `Displays`/`Raster`/
`Plugins`, i.e. the GUI stack this image excludes on purpose. One consequence: files
whose `# options` ask for another target (`-p=Win32 …`) are reported as skipped rather
than failing every case.

Given a **source** rather than a test file — `ob test Foo.Mod Bar.Mod` — the cases come out of
the modules themselves: an exported parameterless module-scope procedure marked `{TEST}` is a
test the compiler has always known about (`FoxTestBackend` writes one `positive:` case per
procedure), and until 2026-08-24 nothing in `ob` could ask for them. So an invariant can live in
the module it is about instead of in a file beside it. A source with no such procedure is
reported as having none rather than run as an empty file. The harvest is one compiler call for
all the sources named, because the backend creates its file when the options are parsed and
appends to it per module.

`--report FILE` writes one JSON document with the counts and an entry per case
(`{"status": "ok|failed|known|fixed|skipped", "file": …, "kind": …, "name": …}`), which is
what CI keeps as an artifact. `--github` prints an Actions annotation per failing case, so
it lands on the run rather than inside the log; it turns itself on when `GITHUB_ACTIONS`
is set. `-r <text>` runs only the cases whose name contains `<text>`, which is how you
iterate on one failure without waiting out the 5450-case compilation suite — mind that a
case relying on a helper module built by an earlier case cannot run alone.

Cases that are known to fail in the tree are listed in a baseline file —
`a2test-expected.txt` next to the tests by default, `--expect FILE` to point elsewhere —
as `<TestFile><TAB><kind>: <case name>`, `#` comments allowed. A listed case that fails
is reported `known` and does **not** break the run; one that starts passing is reported
`FIXED` and *does*, so the file cannot quietly go stale. `--write-expected FILE`
regenerates it from the current run. The repo's own baseline is `tests/a2test-expected.txt`
and CI runs `ob test` over `tests/` against it, so a new failure anywhere in the suite
fails the build.

## Limitations (PoC scope)

- **The Win64 `.exe` needs Windows (or Wine) to run** — it is a `PE32+ console
  x86-64` image, confirmed running under Wine. Native macOS Mach-O is not
  supported at all.
- Networking on the Win64 target is incomplete (the Linux `Sockets` module has no
  Win64 build in this stdlib); Linux and AArch64 have the full TCP/UDP/HTTP stack.
- The base must be glibc (the runtime links `libc`/`libdl`); musl/Alpine will not
  work — for the SDK image and for running Linux `build` output.
- Dead-code elimination is module-granular, so binaries are larger than Go's
  (hello-world ≈ 1.3 MB — it contains the full kernel + GC + scheduler).
- The Windows SDK (`ob.exe`) cross-builds for `a64` but not for `linux64`: it carries no
  Linux objects, and says so rather than writing something that cannot link.
