#!/usr/bin/env bash
#
# The Docker Hub description, made out of docs/SDK.md rather than written twice.
#
# Two things have to happen on the way. Hub renders one Markdown blob with no repository
# around it, so a relative link points at nothing -- every link is rewritten to an absolute
# one. And the description is capped at 25000 characters, which this file is close to, so
# the editor-setup section (which is the IDE guide's job anyway) is left out and pointed at.
#
# Usage: docker/hub-description.sh [> description.md]

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source="$root/docs/SDK.md"
repo="${HUB_SOURCE_URL:-https://github.com/active-oberon/minia2/blob/main}"
limit=25000

[ -f "$source" ] || { echo "no $source" >&2; exit 1; }

# Everything but the editor section, which is 8k of Neovim configuration that belongs to
# docs/IDE.md. The two headings that bound it are the contract; if either is renamed the
# awk below stops dropping anything and the size check catches it.
description="$(
	awk '
		/^## Editor setup/ { skip = 1
			print "## Editor setup (LSP)"
			print ""
			print "`ob lsp` is a language server (JSON-RPC over stdio) with diagnostics, hover,"
			print "go-to-definition, outline, completion, signature help, references, semantic tokens,"
			print "rename, formatting and code actions. Installation, editor configuration and every"
			print "environment variable are in the IDE guide: DOCS_IDE_URL"
			print ""
			next
		}
		/^## How it works/ { skip = 0 }
		!skip { print }
	' "$source" |
	sed -e "s#(\.\./docs/#($repo/docs/#g" \
	    -e "s#(docker/#($repo/docker/#g" \
	    -e "s#DOCS_IDE_URL#[\`docs/IDE.md\`]($repo/docs/IDE.md)#"
)"

size=${#description}
if [ "$size" -gt "$limit" ]; then
	echo "the description is $size characters, and Docker Hub takes $limit" >&2
	exit 1
fi

printf '%s\n' "$description"
