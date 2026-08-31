#!/bin/sh
# Put the grammar where Neovim looks for it: a shared object named after the language,
# and the queries under a directory named after it.
#
# Usage: editors/tree-sitter/install-nvim.sh
#
# Neovim needs no plugin for this -- nvim-treesitter installs parsers, it does not run
# them. The filetype comes from ftdetect (*.Mod -> oberon), the parser is found by that
# same name, and `vim.treesitter.start()` in a FileType autocommand turns it on.

set -eu

here=$(cd "$(dirname "$0")" && pwd)
site="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site"
config="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"

mkdir -p "$site/parser" "$config/queries/oberon"
cc -O2 -fPIC -shared -I"$here/src" "$here/src/parser.c" "$here/src/scanner.c" \
	-o "$site/parser/oberon.so"
cp "$here/queries/"*.scm "$config/queries/oberon/"

echo "installed: $site/parser/oberon.so"
echo "queries:   $config/queries/oberon/"
cat <<'LUA'

Add this once, if it is not there already:

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "oberon",
    callback = function() pcall(vim.treesitter.start) end,
  })
LUA
