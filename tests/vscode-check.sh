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

# TransportKind.stdio makes the client append --stdio to the command, and `ob` refuses it -- the
# server then dies five times and VS Code gives up. Cheap to state, expensive to rediscover.
! grep -q 'TransportKind' "$ext/src/extension.js" || {
	echo "[FAIL] the client sets a transport, which appends --stdio to the ob command line" >&2; exit 1; }

# The debugger has to be declared for the same type the extension registers a factory for, or F5
# opens the "select a debugger" list and nothing says why. Two files, one string.
declared=$(node -p "require('$ext/package.json').contributes.debuggers[0].type" 2>/dev/null)
[ -n "$declared" ] || { echo "[FAIL] package.json declares no debugger" >&2; exit 1; }
grep -q "registerDebugAdapterDescriptorFactory('$declared'" "$ext/src/extension.js" || {
	echo "[FAIL] no adapter factory for the declared debugger type $declared" >&2; exit 1; }
# A gutter is inert in a language no contributes.breakpoints entry names, whatever the debugger
# declares -- debuggers[].languages only says which debugger to offer for a file. Without this the
# session runs to the end with nothing to stop it, and the step buttons never appear because they
# belong to a stopped session. Nothing on screen says any of that.
node -e "
const m = require('$ext/package.json');
const bp = (m.contributes.breakpoints || []).map(b => b.language);
for (const want of m.contributes.debuggers[0].languages) {
	if (!bp.includes(want)) {
		console.error('[FAIL] contributes.breakpoints does not name ' + want + ', so its gutter cannot take a breakpoint');
		process.exit(1);
	}
}
" || exit 1

args=$(node -p "JSON.stringify(require('$ext/package.json').contributes.configuration.properties['activeOberon.debug.args'].default)")
[ "$args" = '["dap"]' ] || {
	echo "[FAIL] the debug adapter is started with $args, not the dap verb" >&2; exit 1; }

# VS Code's own xml extension claims `.mod` for DTD modules and matches extensions without regard
# to case, so `.Mod` is contested. A files.associations default settles it, because a user
# association is read before any extension's extension list; without it the winner is whichever
# extension registered last, and a MODULE opens as XML.
assoc=$(node -p "require('$ext/package.json').contributes.configurationDefaults['files.associations']['*.Mod']" 2>/dev/null)
[ "$assoc" = "oberon" ] || {
	echo "[FAIL] no files.associations default for *.Mod -- the built-in XML can claim it" >&2; exit 1; }

# Everything above compares strings between files. What F5 actually does is logic, and
# tests/vscode-probe.js is where it gets run: the extension activated against a stubbed editor, the
# configuration it resolves for a .Mod file with no launch.json, and the command it hands over
# spawned and asked to initialize. Exit 2 there means the `ob` it was given could not be spawned.
probeob="$root/target/bundle/ob"
[ -x "$probeob" ] || probeob=$(command -v ob || true)
if [ -n "$probeob" ]; then
	node "$root/tests/vscode-probe.js" "$probeob" || {
		status=$?
		[ "$status" = 2 ] || { echo "[FAIL] the extension does not hand VS Code a working debugger" >&2; exit 1; }
	}
else
	echo "[SKIP] no ob to spawn -- the debugger side of the extension is unchecked"
fi

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
