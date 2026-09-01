// The whole extension: point VS Code at `ob lsp` and `ob dap`, which is where every feature
// actually lives. Nothing is implemented here -- both are servers the SDK already ships.
const vscode = require('vscode');
const { LanguageClient } = require('vscode-languageclient/node');

let client;

// resolveCommand prefers what the user configured, then $A2_OB, then the PATH -- the same order
// docs/IDE.md gives Neovim, so one SDK serves both editors without a second setting to keep in sync.
function resolveCommand(config) {
	const configured = (config.get('server.path') || '').trim();
	if (configured !== '') return configured;
	const fromEnv = (process.env.A2_OB || '').trim();
	if (fromEnv !== '') return fromEnv;
	return 'ob';
}

function substitute(value) {
	const folders = vscode.workspace.workspaceFolders;
	const root = folders && folders.length > 0 ? folders[0].uri.fsPath : '';
	return value.replace(/\$\{workspaceFolder\}/g, root);
}

function serverOptions(config) {
	const env = Object.assign({}, process.env);
	const stdlib = (config.get('stdlibSource') || '').trim();
	const syms = (config.get('symbolDir') || '').trim();
	if (stdlib !== '') env.A2_STDLIB_SRC = substitute(stdlib);
	if (syms !== '') env.A2_SYMS = substitute(syms);

	// No `transport` field on purpose: setting it to stdio makes the client append a --stdio flag of
	// its own to the command line, and `ob` exits with "unknown option: --stdio". Left out, the client
	// speaks over the pipes it already opened, which is what `ob lsp` expects.
	const run = {
		command: substitute(resolveCommand(config)),
		args: (config.get('server.args') || ['lsp', '--live']).map(substitute),
		options: { env }
	};
	return { run, debug: run };
}

// `ob dap` is a debug adapter of the ordinary kind, so VS Code needs no code of ours to talk to
// it: it is handed the same command the server runs on, with the debug arguments instead.
function debugAdapterFactory() {
	return {
		createDebugAdapterDescriptor() {
			const config = vscode.workspace.getConfiguration('activeOberon');
			const env = Object.assign({}, process.env);
			const stdlib = (config.get('stdlibSource') || '').trim();
			const syms = (config.get('symbolDir') || '').trim();
			if (stdlib !== '') env.A2_STDLIB_SRC = substitute(stdlib);
			if (syms !== '') env.A2_SYMS = substitute(syms);
			return new vscode.DebugAdapterExecutable(
				substitute(resolveCommand(config)),
				(config.get('debug.args') || ['dap']).map(substitute),
				{ env }
			);
		}
	};
}

// F5 with no launch.json at all: the open file is what the user means, and the SDK's own default
// for which procedure to run is Do. Without this VS Code would ask for a configuration first.
function debugConfigurationProvider() {
	return {
		resolveDebugConfiguration(folder, config) {
			if (!config.type && !config.request && !config.name) {
				const editor = vscode.window.activeTextEditor;
				if (!editor || editor.document.languageId !== 'oberon') return undefined;
				config.type = 'ob';
				config.request = 'launch';
				config.name = 'Run this module';
				config.program = editor.document.fileName;
			}
			if (!config.procedure) config.procedure = 'Do';
			return config;
		}
	};
}

function start() {
	const config = vscode.workspace.getConfiguration('activeOberon');
	client = new LanguageClient(
		'activeOberon',
		'Active Oberon Language Server',
		serverOptions(config),
		{
			documentSelector: [{ scheme: 'file', language: 'oberon' }],
			synchronize: { fileEvents: vscode.workspace.createFileSystemWatcher('**/*.{Mod,mod}') }
		}
	);
	return client.start();
}

async function stop() {
	if (client) {
		await client.stop();
		client = undefined;
	}
}

function activate(context) {
	context.subscriptions.push(
		vscode.debug.registerDebugAdapterDescriptorFactory('ob', debugAdapterFactory()),
		vscode.debug.registerDebugConfigurationProvider('ob', debugConfigurationProvider()),
		vscode.commands.registerCommand('activeOberon.restartServer', async () => {
			await stop();
			await start();
			vscode.window.showInformationMessage('Active Oberon: language server restarted');
		})
	);

	start().catch((err) => {
		// A missing `ob` is the one failure that happens to everybody once, so it says what to do.
		vscode.window.showErrorMessage(
			`Active Oberon: could not start the language server (${err.message}). ` +
			'Install the SDK tarball and put `ob` on the PATH, or set activeOberon.server.path.'
		);
	});
}

function deactivate() {
	return stop();
}

module.exports = { activate, deactivate };
