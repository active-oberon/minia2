#!/usr/bin/env bash
#
# The Docker Hub description, made out of docs/SDK.md rather than written twice.
#
# Two things have to happen on the way. Hub renders one Markdown blob with no repository
# around it, so a relative link points at nothing -- every link is rewritten to an absolute
# one. And the description is capped at 25000 characters, which this file is over, so the two
# longest sections are left as a paragraph pointing at the page they came from: editor setup
# (which is the IDE guide's job anyway) and the binding generator.
#
# Usage: docker/hub-description.sh [> description.md]

set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source="$root/docs/SDK.md"
repo="${HUB_SOURCE_URL:-https://github.com/active-oberon/minia2/blob/main}"
limit=25000

[ -f "$source" ] || { echo "no $source" >&2; exit 1; }

# Everything but two sections: the editor one is 10k of Neovim configuration that belongs to
# docs/IDE.md, and the binding one is 5k of a generator's options. The headings that bound
# each are the contract; if any is renamed the awk below stops dropping that section and the
# size check catches it.
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
		/^## Bindings to a C library/ { skip = 1
			print "## Bindings to a C library"
			print ""
			print "`ob bind <header.h>` writes the binding to a C library out of the library'"'"'s own"
			print "header, instead of a line per function by hand: the header is read by clang and what"
			print "comes out is a module of `PROCEDURE {PlatformCC}` variables resolved from the shared"
			print "library when the module is loaded. Unions, bit fields and wrappers over a variadic"
			print "function are laid out; whatever cannot be translated is named in the module with its"
			print "reason. The options and the measured numbers are in the SDK guide: DOCS_SDK_URL"
			print ""
			next
		}
		/^## Use it with Docker/ { skip = 0 }
		/^## How it works/ { skip = 0 }
		!skip { print }
	' "$source" |
	sed -e "s#(\.\./docs/#($repo/docs/#g" \
	    -e "s#(docker/#($repo/docker/#g" \
	    -e "s#DOCS_IDE_URL#[\`docs/IDE.md\`]($repo/docs/IDE.md)#" \
	    -e "s#DOCS_SDK_URL#[\`docs/SDK.md\`]($repo/docs/SDK.md)#"
)"

size=${#description}
if [ "$size" -gt "$limit" ]; then
	echo "the description is $size characters, and Docker Hub takes $limit" >&2
	exit 1
fi

printf '%s\n' "$description"
