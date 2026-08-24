# Active Oberon for VS Code

Syntax highlighting and the minia2 language server (`ob lsp`) — hover, completion,
diagnostics, go-to-definition, the outline with "dangerous" words, folding.

There is **no marketplace listing on purpose**: the extension is versioned with the SDK it
talks to, and it is installed from the `.vsix` that ships beside the tarball.

## Install

```sh
code --install-extension active-oberon-<version>.vsix
```

The server is the SDK's `ob`. The extension looks for it in this order: the
`activeOberon.server.path` setting, then `$A2_OB`, then `ob` on the PATH — the same order
`docs/IDE.md` gives Neovim.

## Settings

| Setting | What it is |
|---|---|
| `activeOberon.server.path` | the `ob` command; empty means `$A2_OB`, then the PATH |
| `activeOberon.server.args` | `["lsp", "--live"]` by default; `${workspaceFolder}` is substituted |
| `activeOberon.stdlibSource` | passed as `$A2_STDLIB_SRC` — go-to-definition into the standard library |
| `activeOberon.symbolDir` | passed as `$A2_SYMS` — a prebuilt symbol directory, so imports resolve from build artifacts |
| `activeOberon.trace.server` | log the LSP traffic |

Without the tarball, point the same two settings at the image:

```json
"activeOberon.server.path": "docker",
"activeOberon.server.args": ["run", "--rm", "-i", "-v", "${workspaceFolder}:/work", "minia2-sdk", "lsp", "--live"]
```

## Build the .vsix

```sh
cd editors/vscode && npm install && npx @vscode/vsce package
```

`task vscode` does the same and then checks the result.
