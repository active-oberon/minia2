# tree-sitter-oberon — an Active Oberon grammar

An incremental grammar for A2 / Active Oberon, so an editor can colour and navigate a
`.Mod` file without a compiler running behind it. The language server (`ob lsp`) still owns
everything that needs the symbol table — semantic tokens, go-to-definition, the outline;
this grammar owns what the syntax alone decides, and it keeps working on a file that does
not compile yet.

The grammar is a transcription, not a guess: every production is the EBNF that
`source/FoxParser.Mod` carries in a comment above the procedure implementing it, and every
token form comes from `source/FoxScanner.Mod`. Where the two disagree — and they do, the
comments are older than the code — the code wins, and the rule says so.

## Using it

**Neovim** needs no plugin: `nvim-treesitter` installs parsers, it does not run them.

```sh
editors/tree-sitter/install-nvim.sh     # builds oberon.so, copies the queries
```

…then, once, in your config:

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "oberon",
  callback = function() pcall(vim.treesitter.start) end,
})
```

The filetype comes from `ftdetect` (`*.Mod` → `oberon`), and the parser is found by that
same name. **Helix, Zed, Emacs** take the grammar by repository and subdirectory
(`active-oberon/minia2`, `editors/tree-sitter`); `tree-sitter.json` declares the scope,
the file types and the query path they read.

## Working on it

```sh
tree-sitter generate --js-runtime native   # no node needed: the CLI has QuickJS built in
tree-sitter test                           # the cases in test/corpus
tests/treesitter-check.sh                  # + parses every module in source/
```

`src/parser.c` is generated and committed, so an editor can build the grammar without the
CLI. The check regenerates it in a copy and fails if the committed one is stale.

The real test is the library: `tests/treesitter-check.sh` parses all of `source/` and
compares the failures against the two that are known. It is `task treesitter`, and part of
`task test`.

## What the external scanner does

Five things the regex lexer cannot express, each of them a loop `FoxScanner.Mod` writes by
hand:

- **`(* … *)` nests** — `ReadComment` counts levels.
- **A `CODE` body is text** — `SkipToEndOfCode` swallows it up to the `END` or `WITH` that
  closes the block. It is assembler, and the grammar does not read assembler.
- **A note after `END Module.`** — A2 modules carry commentary and command lines there;
  the compiler stops at the period.
- **The skipped branch of a conditional** — see below.
- **`\"…"\`** — the raw string with a chosen delimiter, `GetEscapedString`.

## Known limits

- **Conditional compilation keeps the first branch.** With no `-D` definitions there is no
  other defensible choice, and the branches hold code for different targets — sometimes
  code that is deliberately not code at all (`#ELSE UNIMPLEMENTED #END`). The skipped text
  becomes one `inactive_branch` node, coloured like a comment, the way an editor dims an
  inactive `#ifdef`.
- **Uppercase keywords only.** The scanner has a lowercase table, picked from the case of
  the opening `MODULE`; nothing in the tree uses it.
- **`0.` is not a number.** A real literal needs a digit after the point, or `0..9` could
  not be a range. Three files in `ocp` write `0.`; `0.0` parses.
- **A stray `;` between declarations fails.** `DeclarationSequence` allows the empty
  declaration, but at that position it cannot be told from the separator a section already
  owns. `source/RasterPixelFormats.Mod` has one.
- **A note containing a module does not stay a note.** `source/TVDriver.Mod` puts an
  example `MODULE` in its trailing commentary, and the scanner ends the note there.
