# A2 / Active Oberon IDE (minia2 SDK + LSP)

A full editor experience for **A2 / Active Oberon**, with no per-OS toolchain to
install: the compiler, standard library and a language server ship as one Docker
image (`minia2-sdk`), and your editor talks to it over LSP. Works anywhere Docker
runs (Linux, macOS, Windows via Docker Desktop / WSL2).

This document covers **installation, editor setup, every feature, and the
keybindings**. For how the toolchain itself works (`ob run/build/compile`, standalone
binaries, image internals) see [`docker/README.md`](../docker/README.md).

---

## 1. Install

### 1a. Get the SDK image

Pull the published image and tag it as `minia2-sdk` (what the editor config expects):

```sh
docker pull docker.io/puhachenko/minia2-sdk:latest
docker tag  docker.io/puhachenko/minia2-sdk:latest minia2-sdk
```

…or build it from this repository:

```sh
git clone https://gitlab.com/a25665725/minia2.git && cd minia2
docker build -f docker/Dockerfile -t minia2-sdk .
```

Verify: `docker run --rm minia2-sdk version`.

### 1b. The `ob` command (CLI)

Add an alias so the SDK feels like a local tool:

```sh
alias ob='docker run --rm -v "$PWD:/work" minia2-sdk'
alias obit='docker run --rm -it -v "$PWD:/work" minia2-sdk'   # for the interactive REPL
```

| Command | Does |
|---------|------|
| `ob run <File.Mod> [Proc]` | compile + execute (`go run` model) |
| `ob build <File.Mod> [-o name] [-t linux64\|win64] [Proc]` | standalone native executable |
| `ob compile <File.Mod> [-o dir]` | just the `.GofUu` object file |
| `obit repl` / `ob version` | interactive A2 shell / SDK banner |
| `ob lsp [--live]` | the language server (editors spawn this) |

### 1c. Neovim

Editor-manager-agnostic (works with NVChad / LazyVim / plain config): three standard
Neovim runtime files. They live in the dotfiles repo
(`github.com/andrqxa-tools/dotfiles`, branch `ide-setup`, under
`Editors/NeoVim/NvChad/`) — copy them into `~/.config/nvim/`:

- `ftdetect/oberon.lua` — treat `*.Mod` as filetype `oberon`:
  ```lua
  vim.filetype.add({ extension = { Mod = "oberon" } })
  ```
- `after/ftplugin/oberon.lua` — starts the LSP client (`docker … minia2-sdk lsp --live`),
  mounts the file's directory at `/work`, wires the buffer-local keymaps, and turns on
  inline diagnostics. Honours `$A2_STDLIB_SRC` and `$A2_SYMS` (see §5).
- `syntax/oberon.vim` — syntax highlighting (keywords/types/builtins; `END` is coloured
  by what it closes).

Restart Neovim, open a `.Mod` file — the server starts automatically and you should see
diagnostics, hover, completion, etc.

> **VS Code**: point any generic LSP-bridge extension at
> `docker run --rm -i -v "$PWD:/work" minia2-sdk lsp --live` with a document selector
> for `*.Mod` / language `oberon`.

---

## 2. Features

| Feature | What it does |
|---------|--------------|
| **Diagnostics** | Syntax + semantic errors/warnings on open & save (`--live` also re-checks as you type, debounced). Full message shown inline. |
| **Hover** | Type, kind and doc-comment of the symbol under the cursor, resolved across modules (`KernelLog.Int` → its real signature). Readable type names (`Streams.Writer`, `SIGNED32`). |
| **Go-to-definition** | Jumps to the declaration — same-file *and* cross-module (project modules resolve to a sibling; stdlib with `$A2_STDLIB_SRC`). Works from statement use-sites and declaration-site type annotations. |
| **Document symbols** | Hierarchical module outline — types with their fields & methods, procedures, variables, constants. (PET's module-tree panel.) |
| **Completion** | After `Mod.` → the module's exported symbols; after `var.` → the fields/methods of its record/object type (incl. inherited); otherwise keywords + imports + this module's declarations. With kind + signature. |
| **Signature help** | While typing a call, shows the parameter list and highlights the active argument (`Mod.Proc(`, `proc(`, `obj.Method(`). |
| **Find references** | Every use-site of a symbol + its declaration. Project-wide for module-level symbols and record/object members; current-file for locals. |
| **Semantic tokens** | Identifiers coloured by *meaning* (namespace / type / function / method / variable / parameter / property / enumMember) on top of syntax highlighting. |
| **Rename** | Renames a module-level symbol (type, procedure, module variable, constant) and every use across the project, as one edit. (Locals / members declined for now.) |
| **Formatting** | Reprints the module in Fox's canonical style, preserving the IMPORT list and comments. Only syntactically-valid files. |
| **Code actions** | *Import &lt;M&gt;* quickfix for an undeclared module qualifier; *Comment / Uncomment* the selection. |

---

## 3. Keybindings (Neovim)

Buffer-local in `.Mod` files (plus your config-manager's own LSP maps):

| Key | Action |
|-----|--------|
| `K` | Hover (type / signature / doc) |
| `gd`, `<C-]>`, `Ctrl-Click` | Go to definition |
| `gr` | Find references (Telescope picker / quickfix) |
| `g0` | Document outline (Telescope picker / loclist) |
| `<leader>ra` | Rename (NVChad default) |
| `<leader>fm` | Format buffer (NVChad default), or `:lua vim.lsp.buf.format()` |
| `<leader>ca` | Code actions (NVChad default), or `:lua vim.lsp.buf.code_action()` |
| *(auto)* | Completion (nvim-cmp); manual trigger `<C-Space>` |
| `:lua vim.lsp.buf.signature_help()` | Signature help (bind a key if you like) |
| `[d` / `]d`, `<leader>e` | Diagnostics navigation / float (NVChad defaults) |

Completion, diagnostics and semantic-token colouring apply automatically — nothing to press.

---

## 4. Project-aware resolution

Editing a single file works against the standard library. For real multi-module code,
the server resolves your **own** modules too: the file's directory is mounted at
`/work`, and missing dependencies are compiled on demand from their `.Mod` source
(imports resolve transitively). Diagnostics, hover, completion, references, rename all
work across the whole project.

---

## 5. Environment variables

Set these before launching the editor (the ftplugin reads them):

| Variable | Purpose |
|----------|---------|
| `A2_STDLIB_SRC` | Path to a full A2 source tree (e.g. `$HOME/Projects/A2/a2oberon/source`). Enables **go-to-definition into standard-library modules** from any project. |
| `A2_SYMS` | Path to your project's **prebuilt symbol directory** (e.g. `$HOME/Projects/A2/a2oberon/target/Linux64/bin`). Imports then resolve from real build artifacts instead of on-demand compilation — recommended for large trees, and it fixes modules whose source lives in a platform-prefixed file. Must match the server target (`.SymUu` = Linux64). |

```sh
export A2_STDLIB_SRC="$HOME/Projects/A2/a2oberon/source"
export A2_SYMS="$HOME/Projects/A2/a2oberon/target/Linux64/bin"
```

---

## 6. Limitations

- **Target is 64-bit (Unix64/Linux64).** 32-bit-only modules (e.g. CAPO `CubeInt`,
  `ArrayXd*`, whose source is I386-specific) aren't part of the 64-bit world and will
  show unresolved-import cascades. Multi-platform support (selectable `-p=`) is future
  work.
- **On-demand analysis** can fail for modules that don't compile standalone under the
  target (heavy generics/operators); prefer `A2_SYMS` (prebuilt symbols) for those.
- **Rename** is limited to module-level symbols (safe, unambiguous identity); locals
  and record/object members are declined until scope-precise identity is added.
- **Formatting** normalises to Fox's canonical style (its own indentation), so it
  changes hand-tuned layout.
- GUI modules (window manager / raster) are out of scope of the headless image.
