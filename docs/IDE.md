# A2 / Active Oberon IDE (minia2 SDK + LSP)

A full editor experience for **A2 / Active Oberon**, with no per-OS toolchain to
build: the compiler, standard library and a language server ship as one SDK. **The way to
have it is the tarball** — 64-bit Linux on x86 or ARM, Android/Termux, and Windows, where it
is `ob.exe` and wants no bash: nothing installed, no container, no privilege. One command,
`sdk/install.sh`, puts it in `~/.local/share/a2sdk`.

The **Docker image** (`minia2-sdk`) is the fallback for a machine where the tarball has no
build — macOS today — and for CI that already thinks in containers. It is one way of four,
not the default. Your editor talks to the SDK over LSP either way.

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

From the tarball `ob` *is* the command — the link that `install.sh` makes is all it takes,
and nothing else is needed.

If you work through the image instead, alias it under **another name**:

```sh
alias obd='docker run --rm -v "$PWD:/work" minia2-sdk'
alias obdit='docker run --rm -it -v "$PWD:/work" minia2-sdk'   # interactive verbs, e.g. repl
```

> ⚠️ **Do not call that alias `ob`.** It would shadow the real binary, and then `ob` means
> different things depending on which shell you are in — the editor spawns the binary while
> your prompt spawns a container. Older revisions of this document did exactly that; it was
> written when the image was the only way to have the SDK, and that stopped being true on
> 2026-08-10.

| Command | Does |
|---------|------|
| `ob run <File.Mod> [Proc]` | compile + execute (`go run` model) |
| `ob build <File.Mod> [-o name] [-t linux64\|win64\|a64] [Proc]` | standalone native executable |
| `ob compile <File.Mod> [-o dir]` | just the `.GofUu` object file |
| `obit repl` / `ob version` | interactive A2 shell / SDK banner (`ob repl` from the tarball) |
| `ob lsp [--live]` | the language server (editors spawn this) |
| `ob dap` | the debug adapter: breakpoints, stepping, and where it trapped (§1f) |

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

### 1d. VS Code

The extension lives in this repository, in `editors/vscode`, and is installed from a `.vsix`
— **there is no marketplace listing on purpose**: it is versioned with the SDK it talks to.
The `.vsix` ships beside the tarball in a release, or is built here:

```sh
cd editors/vscode && npm install && ./package.sh     # prints the path of the .vsix
code --install-extension active-oberon-<version>.vsix
```

It finds the server the same way the Neovim config does — the `activeOberon.server.path`
setting, else `$A2_OB`, else `ob` on the PATH — and gives it `$A2_STDLIB_SRC` /
`$A2_SYMS` from `activeOberon.stdlibSource` / `activeOberon.symbolDir` (see §5). Without
the tarball, point it at the image instead:

```json
"activeOberon.server.path": "docker",
"activeOberon.server.args": ["run", "--rm", "-i", "-v", "${workspaceFolder}:/work", "minia2-sdk", "lsp", "--live"]
```

Syntax highlighting comes with it — the same word lists as our Pygments lexer, so the
colours match what the documentation and the website show. `task vscode` builds and checks
the package.

### 1e. PET, A2's own editor

Inside A2 there is no client and no server: **PET calls the same engine in its own process**.
`source/LSP.Mod` and `source/PET.Mod` are modules of one tree, both in Active Oberon, so there
is no JSON-RPC to start, no path to configure and nothing to install — the editor is talking to
the compiler that is already loaded.

| Key | What it does |
|-----|--------------|
| `CTRL-G` | Go to the declaration of the name under the cursor. Other modules included: the file opens in a tab of its own, and the toolbar back arrow walks the jump back, because the jump is recorded like PET's own. |
| `CTRL-K` | What the name under the cursor is — kind, name, type and its doc comment — in the log panel. |

The Program Structure panel is still PET's own parser (`PETModuleTree.Mod`), not the server's
outline; replacing it is a separate step and would gain the user nothing today.

Two coordinate systems meet here, and that is the whole of the plumbing: the server counts
lines and byte offsets in the UTF-8 image of the text, PET's caret counts characters of a
`Texts.Text`. `UTF8Strings.OffsetOfIndex` and `IndexOfOffset` translate, so a file with
non-ASCII comments lands on the right character rather than a few columns off.

### 1f. Debugging (`ob dap`)

`ob dap` speaks the [Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/)
over stdio, the way `ob lsp` speaks LSP. It runs the program in its own process and stops it —
on a **breakpoint**, on a **step**, or **where it trapped**. At every stop the editor gets the
call stack with file and line, the parameters and locals of every frame, and, for a trap, the
dump in its debug console.

A breakpoint is the instruction at that line replaced by one the processor traps on, put back
whenever the program stands still, so what the editor reads is never the patch. A step is the
same thing planted on every other statement of the procedure and on the place it returns to.

Neovim, with [`mfussenegger/nvim-dap`](https://github.com/mfussenegger/nvim-dap):

```lua
local dap = require("dap")
dap.adapters.ob = { type = "executable", command = os.getenv("A2_OB") or "ob", args = { "dap" } }
dap.configurations.oberon = {
  { type = "ob", request = "launch", name = "Run this module",
    program = "${file}", procedure = "Do" },
}
```

`<F5>` on an open `.Mod` file compiles it with `--debug` and runs its `Do` (name another
procedure with `procedure = …`); `<F9>` sets a breakpoint, `<F10>` steps over, `<F12>` steps
out. A trap stops the program too, and continuing from a trap lets it die — after the trap
handler there is no stack left to go back to.

Four things are worth knowing:

- The line table lives only in the process that compiled the code (`source/DebugMap.Mod`), so
  `ob dap` debugs what it built itself. Attaching to a binary built earlier needs the table
  written into the object file, which is not done.
- One thread: the activity that stopped. A program that stops on two activities at once reports
  the first.
- A breakpoint in a module body is never reached: the body has already run by the time there is
  code to write a breakpoint into.
- Stepping into a call stops at the next statement of the caller instead — where a call goes is
  in the instruction, and reading it would mean carrying a decoder.

---

## 2. Features

| Feature | What it does |
|---------|--------------|
| **Diagnostics** | Syntax + semantic errors/warnings on open & save (`--live` also re-checks as you type, debounced). Full message shown inline. |
| **Hover** | Type, kind and doc-comment of the symbol under the cursor, resolved across modules (`KernelLog.Int` → its real signature). Readable type names (`Streams.Writer`, `SIGNED32`). |
| **Go-to-definition** | Jumps to the declaration — same-file *and* cross-module (project modules resolve to a sibling; stdlib with `$A2_STDLIB_SRC`). Works from statement use-sites and declaration-site type annotations. |
| **Go-to-type-definition** | The jump go-to-definition cannot make: on a variable it answers the variable, this answers where its *type* is declared — same file or another module. A pointer to a named record answers the record; a basic or anonymous type is declared nowhere and answers null. Bound to `gy` below. |
| **Go-to-implementation** | On a type, every type in the project that extends it — the base chain is followed, so a grandchild counts, and the type asked about is not among the answers. On a method, which of those types overrides it. Module-level types only. Bound to `gi` below; Neovim 0.11+ also has `gri` for it out of the box. |
| **Document highlight** | Every use of the name under the cursor in the open file — find-all-references without the project sweep. A local is collected by its own scope, so the same-named local of a sibling procedure is not highlighted with it. This one is a *request*, so the config asks for it on `CursorHold` and clears it on `CursorMoved`; if nothing lights up, the colourscheme has no `LspReferenceText` / `Read` / `Write` (check with `:hi LspReferenceText`) — a theme setting, not a server one. |
| **Document symbols** | Hierarchical module outline — types with their fields & methods, procedures, variables, constants — **in the order the file is in**, with a `*` on what the module exports and the imports collapsed under one `IMPORT (n)` node. Operators carry their parameter types, so three declarations of `=` are three distinct rows. `CONST` and `VAR` are deliberately *not* grouped: a name has to stay findable by typing it in a fuzzy symbol search. (This is PET's Program Structure panel; a client that prefers alphabetical sorts it itself, which is why the server sends source order — the reverse is not recoverable.) **A picker flattens and sorts all of that away**, so use the side panel (`gO`) to see it. |
| **Completion** | After `Mod.` → the module's exported symbols; after `var.` → the fields/methods of its record/object type (incl. inherited); otherwise keywords + imports + this module's declarations. With kind + signature. |
| **Signature help** | While typing a call, shows the parameter list and highlights the active argument (`Mod.Proc(`, `proc(`, `obj.Method(`). |
| **Find references** | Every use-site of a symbol + its declaration. Project-wide for module-level symbols and record/object members; current-file for locals. |
| **Semantic tokens** | Identifiers coloured by *meaning* (namespace / type / function / method / variable / parameter / property / enumMember / decorator) on top of syntax highlighting, plus two **modifiers** that mark where the program stops being a checked program: `dangerous` on the whole of `SYSTEM` (`GET`, `PUT`, `MOVE`, `VAL`, `ADR`, the registers) and on `HALT` plus the modifiers in braces — `{UNSAFE}` and `{UNTRACED}` on a pointer, `{UNCOOPERATIVE}`, `{UNCHECKED}`, `{UNTRACKED}` on a block (those five are `decorator`, and come off the token stream: the parser folds them into flags, so no symbol of them survives to colour); `checks` on `ASSERT`. This is what A2's own editor colours through `data/SyntaxHighlighter.XML`, and for a language read from the interrupt handler up it is the highlighting that matters most. Style them in your client — with Neovim's default token links they are invisible until you do. |
| **Workspace symbols** | The project-wide symbol box — `Ctrl-T` in VS Code, `gS` in Neovim (Telescope's `lsp_dynamic_workspace_symbols` works too, but it re-queries per keystroke and the server re-parses the project per query). A case-insensitive substring of the name, matched against every module beside the open one, fields and methods included; each row carries the type or object it belongs to. Parse-only per file — it costs a parse, not a check — and an empty query answers nothing rather than the whole tree. |
| **Rename** | A module-level symbol (type, procedure, module variable, constant) is renamed with every use across the project; a local or parameter within its own scope, which is all of it. Record/object members are still declined. |
| **Formatting** | Reprints the module in Fox's canonical style, preserving the IMPORT list and comments. Only syntactically-valid files. |
| **Tests from the buffer** | `{TEST}` procedures run with `<leader>rt` / `<leader>rT` (below). No neotest adapter and none needed for this: `ob test` reports a failing harvested test a second time as `<file>:<line>: FAIL <Module>.<Proc>`, so a plain `errorformat` puts it in the quickfix list — and the same line works in any editor. The line is the test's **declaration**, not the failing statement: a trap prints a code offset after the procedure name, and the reference section has no line table to turn one into a line. The trap itself is in the run's output. |
| **Code actions** | *Import &lt;M&gt;* quickfix for an undeclared module qualifier; *Remove unused import &lt;M&gt;* — put the cursor anywhere in the `IMPORT` clause and one is offered per import nothing names (the comma leaves with the name, and the last import takes the whole clause with it); *Comment / Uncomment* the selection. |
| **Folding** | Procedures, records and objects, statement blocks, `REPEAT`/`UNTIL`, the `IMPORT` list and multi-line comments. Not the module itself — it is the file, and folding it would leave one line. Worked out from the tokens, so it keeps working while the file does not parse. |

---

## 3. Keybindings (Neovim)

Buffer-local in `.Mod` files (plus your config-manager's own LSP maps):

Here `<leader>` is one Space key. For example, `<leader>df` means press `Space`, then
`d`, then `f` (without another Space). The file tree keeps its NvChad defaults: `<C-n>`
opens or closes it, `<leader>e` puts the cursor in it. Under Termux, set the app's
new-session shortcut to something other than `ctrl + n` — the app takes that key
before the terminal, and Neovim never sees it.

| Key | Action |
|-----|--------|
| `gh` | Toggle hover (type / signature / doc; an import shows its module and source path). The popup never takes keyboard focus and also closes when the cursor moves. |
| `gd`, `<C-]>`, `Ctrl-Click` | Go to definition |
| `gr` | Find references (Telescope picker / quickfix) |
| `gS` | Find a symbol anywhere in the project by name — the one navigation Neovim has no default key for |
| `gy` | Go to the **type** of the name under the cursor (`gd` answers the name itself) |
| `gi` | Go to implementation — what extends this type, or what overrides this method (`gri` is Neovim's own default for it) |
| `g0` | Document outline as a picker (Telescope / loclist) — type to filter |
| `gO` | Document outline as a **side panel** ([outline.nvim](https://github.com/hedyhli/outline.nvim)) — the tree as the server sends it |
| `<leader>rr` | Compile and run the current module (`ob run %`) — output in the pager, `Enter` returns |
| `<leader>rb` | Compile only, binary to `/tmp/<Module>` (`ob build`) |
| `<leader>rt` | Run this module's `{TEST}` procedures (`ob test %`). A failing one lands in the quickfix list at its declaration; a green run only echoes the count |
| `<leader>rT` | Run just the `{TEST}` procedure the cursor is in — the nearest one at or above it (`ob test % -r <name>`) |
| `<leader>ra` | Rename the symbol under the cursor |
| `<leader>fm` | Format buffer (NVChad default), or `:lua vim.lsp.buf.format()` |
| `<leader>ca` | Code actions (Normal or Visual mode), or `:lua vim.lsp.buf.code_action()` |
| *(auto)* | Completion (nvim-cmp); manual trigger `<C-Space>` |
| `<C-S>` in Insert mode, or `:lua vim.lsp.buf.signature_help()` | Signature help |
| `[d` / `]d` | Previous / next diagnostic |
| `<leader>df` | Full diagnostic for the current line (or an explicit “none” message) |
| `<leader>ds` | All diagnostics in the location list (NvChad default) |
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
needs the server restarted. Neovim 0.12 has the built-in `:lsp restart ob`; `:ObRestart` wraps it
and also starts the server again if the old client has already stopped or crashed.
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
| `A2_STDLIB_SRC` | Path to a full A2 source tree (e.g. `$HOME/Projects/A2/a2oberon/source`). Enables **go-to-definition into standard-library modules** from any project. Read directly by `ob lsp` from the tarball SDK; with the image the editor config turns it into a `/libsrc` mount. |
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
- **Debugging** (`ob dap`, §1f) has breakpoints, step-over and step-out, and reads a trapped
  program; but one thread, no step-into, nothing in a module body, and only code the same `ob`
  compiled.
- GUI modules (window manager / raster) are out of scope of the headless image.
