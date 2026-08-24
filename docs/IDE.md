# A2 / Active Oberon IDE (minia2 SDK + LSP)

A full editor experience for **A2 / Active Oberon**, with no per-OS toolchain to
build: the compiler, standard library and a language server ship as one SDK — either
a **tarball** you unpack (64-bit Linux on x86 or ARM, and Windows, where it is `ob.exe`
and wants no bash; nothing installed, no container in the loop) or a **Docker image**
(`minia2-sdk`, anywhere Docker runs: Linux, macOS, Windows via Docker Desktop / WSL2).
Your editor talks to it over LSP either way.

This document covers **installation, editor setup, every feature, and the
keybindings**. For how the toolchain itself works (`ob run/build/compile`, standalone
binaries, image internals) see [`docs/SDK.md`](../docs/SDK.md).

---

## 1. Install

### 1a. Get the SDK

**The tarball** — one directory, no daemon, and the shortest path to a working editor:

```sh
curl -fsSL https://raw.githubusercontent.com/active-oberon/minia2/main/sdk/install.sh | sh
# ...or by hand, from a release tarball:
tar xzf minia2-sdk-<version>-linux-amd64.tar.gz
cd minia2-sdk-<version>-linux-amd64
./run.sh --quick                 # does it work? every verb, in about a minute
export A2_OB="$PWD/ob"           # what the editor configs below look for
mkdir -p ~/.local/bin && ln -sf "$PWD/ob" ~/.local/bin/ob     # and `ob` on the PATH
```

It comes from a release, or from `task bundle` in this repository. `ob` finds the SDK
beside itself (following the symlink), so neither the export nor the link needs any
further setup; `A2SDK` overrides the location if you want it elsewhere.

**Or the image.** Pull the published one and tag it as `minia2-sdk` (what the editor
config expects):

```sh
docker pull docker.io/puhachenko/minia2-sdk:latest
docker tag  docker.io/puhachenko/minia2-sdk:latest minia2-sdk
```

…or build it from this repository:

```sh
git clone https://github.com/active-oberon/minia2.git && cd minia2
docker build -f docker/Dockerfile -t minia2-sdk .
```

Verify: `docker run --rm minia2-sdk version` (or `ob version` from the tarball).

### 1b. The `ob` command (CLI)

From the tarball `ob` *is* the command — the link above is all it takes. With the image,
an alias makes it feel like one:

```sh
alias ob='docker run --rm -v "$PWD:/work" minia2-sdk'
alias obit='docker run --rm -it -v "$PWD:/work" minia2-sdk'   # for the interactive REPL
```

| Command | Does |
|---------|------|
| `ob run <File.Mod> [Proc]` | compile + execute (`go run` model) |
| `ob build <File.Mod> [-o name] [-t linux64\|win64\|a64] [Proc]` | standalone native executable |
| `ob compile <File.Mod> [-o dir]` | just the `.GofUu` object file |
| `obit repl` / `ob version` | interactive A2 shell / SDK banner (`ob repl` from the tarball) |
| `ob lsp [--live]` | the language server (editors spawn this) |

### 1c. Neovim

Editor-manager-agnostic (works with NVChad / LazyVim / plain config): three standard
Neovim runtime files. They live in the dotfiles repo
(`github.com/andrqxa-tools/dotfiles`, branch `master`, under
`Editors/NeoVim/NvChad/`) — copy them into `~/.config/nvim/`:

- `ftdetect/oberon.lua` — treat `*.Mod` as filetype `oberon`:
  ```lua
  vim.filetype.add({ extension = { Mod = "oberon" } })
  ```
- `after/ftplugin/oberon.lua` — starts the LSP client, wires the buffer-local keymaps,
  turns on inline diagnostics and turns on **folding** when the server offers it.
  It prefers the tarball SDK — `$A2_OB`, else `ob` on `PATH` — and falls back to
  `docker … minia2-sdk lsp --live`, mounting the file's directory at `/work`. Prefer the
  tarball: an image built yesterday does not have what the server learnt today.
  Honours `$A2_STDLIB_SRC` and `$A2_SYMS` (see §5).
- `lua/plugins/init.lua` — `hedyhli/outline.nvim` for the side panel (`gO`), unfiltered by
  symbol kind on purpose: constants, variables and record fields are exactly what one looks
  for in an Oberon module, and aerial.nvim's default `filter_kind` would drop all three.
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
| **Document symbols** | Hierarchical module outline — types with their fields & methods, procedures, variables, constants — **in the order the file is in**, with a `*` on what the module exports and the imports collapsed under one `IMPORT (n)` node. Operators carry their parameter types, so three declarations of `=` are three distinct rows. `CONST` and `VAR` are deliberately *not* grouped: a name has to stay findable by typing it in a fuzzy symbol search. (This is PET's Program Structure panel; a client that prefers alphabetical sorts it itself, which is why the server sends source order — the reverse is not recoverable.) **A picker flattens and sorts all of that away**, so use the side panel (`gO`) to see it. |
| **Completion** | After `Mod.` → the module's exported symbols; after `var.` → the fields/methods of its record/object type (incl. inherited); otherwise keywords + imports + this module's declarations. With kind + signature. |
| **Signature help** | While typing a call, shows the parameter list and highlights the active argument (`Mod.Proc(`, `proc(`, `obj.Method(`). |
| **Find references** | Every use-site of a symbol + its declaration. Project-wide for module-level symbols and record/object members; current-file for locals. |
| **Semantic tokens** | Identifiers coloured by *meaning* (namespace / type / function / method / variable / parameter / property / enumMember / decorator) on top of syntax highlighting, plus two **modifiers** that mark where the program stops being a checked program: `dangerous` on the whole of `SYSTEM` (`GET`, `PUT`, `MOVE`, `VAL`, `ADR`, the registers) and on `HALT` plus the modifiers in braces — `{UNSAFE}` and `{UNTRACED}` on a pointer, `{UNCOOPERATIVE}`, `{UNCHECKED}`, `{UNTRACKED}` on a block (those five are `decorator`, and come off the token stream: the parser folds them into flags, so no symbol of them survives to colour); `checks` on `ASSERT`. This is what A2's own editor colours through `data/SyntaxHighlighter.XML`, and for a language read from the interrupt handler up it is the highlighting that matters most. Style them in your client — with Neovim's default token links they are invisible until you do. |
| **Rename** | Renames a module-level symbol (type, procedure, module variable, constant) and every use across the project, as one edit. (Locals / members declined for now.) |
| **Formatting** | Reprints the module in Fox's canonical style, preserving the IMPORT list and comments. Only syntactically-valid files. |
| **Code actions** | *Import &lt;M&gt;* quickfix for an undeclared module qualifier; *Comment / Uncomment* the selection. |
| **Folding** | Procedures, records and objects, statement blocks, `REPEAT`/`UNTIL`, the `IMPORT` list and multi-line comments. Not the module itself — it is the file, and folding it would leave one line. Worked out from the tokens, so it keeps working while the file does not parse. |

---

## 3. Keybindings (Neovim)

Buffer-local in `.Mod` files (plus your config-manager's own LSP maps):

| Key | Action |
|-----|--------|
| `K` | Hover (type / signature / doc) |
| `gd`, `<C-]>`, `Ctrl-Click` | Go to definition |
| `gr` | Find references (Telescope picker / quickfix) |
| `g0` | Document outline as a picker (Telescope / loclist) — type to filter |
| `gO` | Document outline as a **side panel** ([outline.nvim](https://github.com/hedyhli/outline.nvim)) — the tree as the server sends it |
| `<leader>rr` | Compile and run the current module (`ob run %`) — output in the pager, `Enter` returns |
| `<leader>rb` | Compile only, binary to `/tmp/<Module>` (`ob build`) |
| `<leader>ra` | Rename (NVChad default) |
| `<leader>fm` | Format buffer (NVChad default), or `:lua vim.lsp.buf.format()` |
| `<leader>ca` | Code actions (NVChad default), or `:lua vim.lsp.buf.code_action()` |
| *(auto)* | Completion (nvim-cmp); manual trigger `<C-Space>` |
| `:lua vim.lsp.buf.signature_help()` | Signature help (bind a key if you like) |
| `[d` / `]d`, `<leader>e` | Diagnostics navigation / float (NVChad defaults) |
| `za` / `zA` | Fold or unfold what the cursor is in (`zA` takes the nested folds with it) |
| `zc` / `zo`, `zC` / `zO` | Close / open one fold, or all of them under the cursor |
| `zM` / `zR` | Close everything / open everything |
| `zm` / `zr` | Close / open one level at a time |
| `zj` / `zk` | Jump to the next fold's start / the previous fold's end |
| `zv` | Open just enough to see the line the cursor is on |
| `:ObFoldImports`, `:ObFoldComments` | Close every fold of that kind |
| `:ObRestart` | Restart the language server (after `task update` puts a new `ob` in place) |

Completion, diagnostics and semantic-token colouring apply automatically — nothing to press.

**The two token modifiers need colours, or they do nothing.** Neovim links semantic tokens to
`@lsp.*` groups, and it has no default for a modifier it has not heard of, so `dangerous` and
`checks` are invisible until you say what they look like. Anywhere in your config:

```lua
-- everything of SYSTEM, plus HALT / UNTRACED / UNTRACKED / UNCHECKED / UNCOOPERATIVE / UNSAFE
vim.api.nvim_set_hl(0, "@lsp.mod.dangerous.oberon", { fg = "#ffd9d0", bg = "#5c1f26", bold = true })
-- ASSERT, and nothing else in the language
vim.api.nvim_set_hl(0, "@lsp.mod.checks.oberon",    { fg = "#2bbac5", bold = true })
```

**A red foreground is the obvious choice and the wrong one.** In the default NvChad theme (onedark)
`Statement` and `Identifier` are both `#e06c75`, so `IMPORT`, `CONST`, `VAR` and every plain
identifier are already red: a red `SYSTEM` lands in the middle of a red page and marks nothing.
Check your own theme before picking — `#e06c75` red, `#c678dd` purple, `#e5c07b` yellow, `#98c379`
green and `#61afef` blue are all spoken for there, which leaves the **background** and **cyan**.
A background wash is also the truer picture: what is marked is a *region* where the language stopped
being checked, not a word that happens to be a keyword.

`:Inspect` on a word says which groups it got, which is the quickest way to see whether the server
sent the modifier at all. A colour change needs only `:e` — it is client-side. A **new `ob` binary**
needs the server restarted, and there is no `:LspRestart` to reach for: nvim-lspconfig 2.x dropped
its `Lsp*` commands and this client is started by the ftplugin with `vim.lsp.start` rather than by
lspconfig, so nothing registers one. Hence `:ObRestart`.
Folding is vim's own set of keys; the server only supplies the ranges. A file opens unfolded
(`foldlevel = 99` in the ftplugin — set it to `0` there if you would rather start folded). On a
67-line module `zM` leaves 13 lines: the header, the constants, the object and one line per
procedure.

---

## 4. Project-aware resolution

Editing a single file works against the standard library, and a directory of modules works as
a project -- for both the server and `ob build`, which compile every `*.Mod` beside the one you
name. For real multi-module code,
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
| `A2_SYMS` | Path to your project's **prebuilt symbol directory** (e.g. `$HOME/Projects/A2/a2oberon/target/Linux64/bin`). Imports then resolve from real build artifacts instead of on-demand compilation — recommended for large trees, and it fixes modules whose source lives in a platform-prefixed file. Must match the server target (`.SymUu` = Linux64). Read directly by `ob lsp` from the tarball SDK; with the image the editor config turns it into a `/psym` mount. |
| `A2_OB` | Path to the tarball SDK's `ob`. Set it and the editor config starts the language server directly instead of `docker run`. |

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
