#!/bin/sh
# The tree-sitter grammar: it generates, its own cases pass, and it parses the library.
#
# Usage: tests/treesitter-check.sh
#
# The grammar is transcribed from the EBNF in source/FoxParser.Mod, so what breaks is not
# a rule in isolation but the library ceasing to parse -- a construct nobody wrote down.
# The check therefore parses every module in source/ and compares the failures against the
# two that are known (a stray ';' after a comment, and an example module inside a trailing
# note). Exit 2 means "could not check" (no tree-sitter CLI).

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
grammar="$root/editors/tree-sitter"

command -v tree-sitter >/dev/null || {
	echo "[SKIP] no tree-sitter CLI -- cargo install tree-sitter-cli"; exit 2; }

# The committed src/parser.c has to be what grammar.js generates, or an editor builds
# yesterday's grammar and nothing says so. Generated in a copy, so the tree stays clean.
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
mkdir -p "$out/src"
cp "$grammar/grammar.js" "$grammar/tree-sitter.json" "$out/"
cp "$grammar/src/scanner.c" "$out/src/"
(cd "$out" && tree-sitter generate --js-runtime native >/dev/null) || {
	echo "[FAIL] the grammar does not generate" >&2; exit 1; }
cmp -s "$out/src/parser.c" "$grammar/src/parser.c" || {
	echo "[FAIL] src/parser.c is stale -- run \`tree-sitter generate --js-runtime native\` in editors/tree-sitter" >&2
	exit 1; }

cd "$grammar"
tree-sitter test >/dev/null 2>"$out/err" || {
	cat "$out/err" >&2; echo "[FAIL] the grammar's own cases do not pass" >&2; exit 1; }

tree-sitter query queries/highlights.scm "$root/source/DAP.Mod" >/dev/null 2>"$out/err" || {
	cat "$out/err" >&2
	echo "[FAIL] queries/highlights.scm does not compile against the grammar" >&2; exit 1; }

known="RasterPixelFormats.Mod TVDriver.Mod"
failed=$(tree-sitter parse --quiet --stat "$root"/source/*.Mod 2>/dev/null | awk '/ERROR/ {print $1}' | xargs -r -n1 basename | sort || true)
unexpected=""
for f in $failed; do
	case " $known " in *" $f "*) ;; *) unexpected="$unexpected $f" ;; esac
done
[ -z "$unexpected" ] || {
	echo "[FAIL] modules that used to parse no longer do:$unexpected" >&2; exit 1; }

total=$(ls "$root"/source/*.Mod | wc -l | tr -d ' ')
count=$(echo "$failed" | grep -c . || true)
echo "[PASS] the grammar parses $((total - count))/$total library modules (known failures: $known)"
