// What the extension hands VS Code, checked without VS Code.
//
// tests/vscode-check.sh answers for the packaging and for the strings two files have to agree on.
// This answers for the two pieces of logic behind F5, which no string comparison reaches:
//
//   -  resolveDebugConfiguration on an empty configuration -- what happens when a person presses F5
//      on a .Mod file and there is no launch.json anywhere. Get this wrong and VS Code opens the
//      "select a debugger" list instead, with nothing to say why.
//   -  createDebugAdapterDescriptor -- the command, the arguments and the environment the editor
//      will actually spawn. Spawned here, and asked to initialize: an adapter that answers is an
//      adapter, and the rest of the conversation is tests/DAP.Test's and ob-check's business.
//
// `vscode` and the language client are stubbed: neither exists outside the editor, and the server
// is tests/LSP.Test's subject. The configuration defaults come out of package.json rather than
// being written again here -- what VS Code would use is what the manifest says.
//
// Usage: node tests/vscode-probe.js [path to ob]

const fs = require('fs');
const path = require('path');
const Module = require('module');
const { spawn } = require('child_process');

const root = path.resolve(__dirname, '..');
const ext = path.join(root, 'editors', 'vscode');
const manifest = JSON.parse(fs.readFileSync(path.join(ext, 'package.json'), 'utf8'));
const ob = process.argv[2] || 'ob';
const fixture = path.join(root, 'examples', 'Hello.Mod');

function die(what) {
	console.error(`[FAIL] ${what}`);
	process.exit(1);
}

// The defaults VS Code hands a getConfiguration('activeOberon'), read off the manifest.
const defaults = {};
for (const [key, value] of Object.entries(manifest.contributes.configuration.properties)) {
	defaults[key.replace(/^activeOberon\./, '')] = value.default;
}

let spawned = null;
const registered = { factory: null, provider: null };

const vscodeStub = {
	workspace: {
		workspaceFolders: [{ uri: { fsPath: root } }],
		getConfiguration: () => ({ get: (key) => defaults[key] }),
		createFileSystemWatcher: () => ({ dispose() {} })
	},
	window: {
		activeTextEditor: { document: { languageId: 'oberon', fileName: fixture } },
		showErrorMessage: () => {},
		showInformationMessage: () => {}
	},
	commands: { registerCommand: () => ({ dispose() {} }) },
	debug: {
		registerDebugAdapterDescriptorFactory: (type, factory) => {
			registered.factory = { type, factory };
			return { dispose() {} };
		},
		registerDebugConfigurationProvider: (type, provider) => {
			registered.provider = { type, provider };
			return { dispose() {} };
		}
	},
	DebugAdapterExecutable: class {
		constructor(command, args, options) {
			Object.assign(this, { command, args, options });
		}
	}
};

const load = Module._load;
Module._load = function (request, parent, isMain) {
	if (request === 'vscode') return vscodeStub;
	if (request === 'vscode-languageclient/node') {
		return { LanguageClient: class { start() { return Promise.resolve(); } stop() { return Promise.resolve(); } } };
	}
	return load.call(this, request, parent, isMain);
};

const extension = require(path.join(ext, 'src', 'extension.js'));
extension.activate({ subscriptions: [] });

if (!registered.factory) die('activate registered no debug adapter factory');
if (!registered.provider) die('activate registered no debug configuration provider');

// F5 with nothing configured at all.
const resolved = registered.provider.provider.resolveDebugConfiguration(undefined, {});
if (!resolved) die('F5 with no launch.json resolved to nothing, so VS Code would ask for a configuration');
for (const [key, want] of [['type', registered.factory.type], ['request', 'launch'],
		['program', fixture], ['procedure', 'Do']]) {
	if (resolved[key] !== want) die(`F5 resolved ${key} to ${JSON.stringify(resolved[key])}, not ${JSON.stringify(want)}`);
}
if (!resolved.name) die('F5 resolved a configuration with no name, which VS Code shows in its picker');
console.log(`[PASS] F5 with no launch.json resolves to ${resolved.type}/${resolved.request} on ${path.basename(resolved.program)}, procedure ${resolved.procedure}`);

// A file that is not ours must be left to whoever owns it, or every language's F5 lands here.
vscodeStub.window.activeTextEditor = { document: { languageId: 'go', fileName: '/tmp/main.go' } };
if (registered.provider.provider.resolveDebugConfiguration(undefined, {}) !== undefined) {
	die('F5 on a file that is not Active Oberon still resolved to our debugger');
}
console.log('[PASS] F5 on a file of another language is left alone');

const descriptor = registered.factory.factory.createDebugAdapterDescriptor();
if (!descriptor || !descriptor.command) die('the factory produced no executable');
if (JSON.stringify(descriptor.args) !== JSON.stringify(defaults['debug.args'])) {
	die(`the adapter is started with ${JSON.stringify(descriptor.args)}, not ${JSON.stringify(defaults['debug.args'])}`);
}
console.log(`[PASS] the adapter is spawned as \`${descriptor.command} ${descriptor.args.join(' ')}\``);

// The command the editor would run, run. `ob` is named on the command line because the extension
// resolves to the bare name on the PATH, and a check must not depend on what is installed.
spawned = spawn(ob, descriptor.args, { env: descriptor.options.env, stdio: ['pipe', 'pipe', 'inherit'] });

const request = { seq: 1, type: 'request', command: 'initialize', arguments: { adapterID: descriptor.command } };
const body = JSON.stringify(request);
spawned.stdin.write(`Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`);

let transcript = '';
const timer = setTimeout(() => {
	spawned.kill();
	die('the adapter did not answer initialize within 30s');
}, 30000);

spawned.stdout.on('data', (chunk) => {
	transcript += chunk.toString();
	if (!/"command"\s*:\s*"initialize"/.test(transcript)) return;
	clearTimeout(timer);
	const answered = /"success"\s*:\s*true/.test(transcript);
	spawned.stdin.end();
	spawned.kill();
	if (!answered) die(`the adapter answered initialize without success: ${transcript.slice(0, 200)}`);
	console.log('[PASS] the command the editor spawns answers initialize as a debug adapter');
	process.exit(0);
});

spawned.on('error', (err) => {
	clearTimeout(timer);
	console.log(`[SKIP] could not spawn ${ob}: ${err.message}`);
	process.exit(2);
});
