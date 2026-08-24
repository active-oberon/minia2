#!/bin/sh
# The VS Code extension: it builds, and what comes out is a .vsix VS Code will take.
#
# Usage: tests/vscode-check.sh
#
# The extension is three files and a word list -- what breaks is not the logic but the packaging:
# a grammar that is not valid JSON, a client that does not parse, a zip missing the manifest VS Code
# reads first. All three are checked here. Whether the server then answers is `ob lsp`'s own business
# and is checked by tests/LSP.Test. Exit 2 means "could not check" (no node, no zip, no node_modules).

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
ext="$root/editors/vscode"

command -v node >/dev/null || { echo "[SKIP] no node"; exit 2; }
command -v zip >/dev/null || { echo "[SKIP] no zip"; exit 2; }
[ -d "$ext/node_modules/vscode-languageclient" ] || {
	echo "[SKIP] no node_modules -- run \`npm install\` in editors/vscode"; exit 2; }

node --check "$ext/src/extension.js" || { echo "[FAIL] src/extension.js does not parse" >&2; exit 1; }
for json in "$ext/package.json" "$ext/language-configuration.json" "$ext/syntaxes/activeoberon.tmLanguage.json"; do
	node -e "JSON.parse(require('fs').readFileSync('$json','utf8'))" || {
		echo "[FAIL] $json is not valid JSON" >&2; exit 1; }
done

# The grammar has to name the scope the package.json points at, or the file opens unhighlighted with
# no error anywhere.
scope=$(node -p "JSON.parse(require('fs').readFileSync('$ext/syntaxes/activeoberon.tmLanguage.json','utf8')).scopeName")
declared=$(node -p "require('$ext/package.json').contributes.grammars[0].scopeName")
[ "$scope" = "$declared" ] || { echo "[FAIL] grammar scope $scope, package.json says $declared" >&2; exit 1; }

out=$(mktemp -d)
vsix=$("$ext/package.sh" "$out")
[ -s "$vsix" ] || { echo "[FAIL] no .vsix was built" >&2; rm -rf "$out"; exit 1; }
for member in '\[Content_Types\].xml' 'extension.vsixmanifest' 'extension/package.json' 'extension/node_modules/vscode-languageclient/package.json'; do
	unzip -l "$vsix" | grep -q "$member" || {
		echo "[FAIL] the .vsix has no $member -- VS Code would refuse it" >&2; rm -rf "$out"; exit 1; }
done
size=$(du -k "$vsix" | cut -f1)
rm -rf "$out"
echo "[PASS] the extension packs into a .vsix VS Code accepts (${size} KB)"
