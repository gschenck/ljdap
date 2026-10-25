// ljdap – VS-Code-Erweiterung.
//   attach: verbindet sich mit ljdap im laufenden Programm (DebugAdapterServer)
//   launch: startet `lua ljdap.lua --port P skript.lua args…` (Starter-Modus),
//           wartet auf den Port und verbindet sich; stdout/stderr in die
//           Debug-Konsole; Prozess endet mit der Sitzung.
'use strict';

const vscode = require('vscode');
const cp = require('child_process');
const path = require('path');
const lib = require('./lib');

class Factory {
  constructor(context) {
    this.context = context;
    this.procs = new Map(); // session.id -> ChildProcess
  }

  async createDebugAdapterDescriptor(session) {
    const c = session.configuration;
    if (c.request === 'attach') {
      return new vscode.DebugAdapterServer(c.port || 4711, c.host || '127.0.0.1');
    }
    const port = c.port || await lib.freePort();
    const [cmd, args] = lib.launchCommand(c, path.join(this.context.extensionPath, 'ljdap.lua'), port);
    const proc = cp.spawn(cmd, args, { cwd: c.cwd || undefined, env: lib.launchEnv(c) });
    this.procs.set(session.id, proc);
    let exited = false;
    let spawnError;
    proc.on('error', (e) => { spawnError = e; exited = true; });
    proc.on('exit', () => { exited = true; });
    const toConsole = (d) => {
      const con = vscode.debug.activeDebugConsole;
      if (con) con.append(d.toString());
    };
    proc.stdout.on('data', toConsole);
    proc.stderr.on('data', toConsole);
    try {
      await lib.waitForPort(port, '127.0.0.1', (c.timeout || 5) * 1000, () => !exited);
    } catch (e) {
      proc.kill();
      const why = spawnError ? `${cmd} lässt sich nicht starten (${spawnError.message})` : e.message;
      vscode.window.showErrorMessage(`ljdap: ${why}`);
      throw new Error(why);
    }
    return new vscode.DebugAdapterServer(port, '127.0.0.1');
  }

  sessionEnded(session) {
    const p = this.procs.get(session.id);
    if (p) {
      this.procs.delete(session.id);
      if (p.exitCode === null) setTimeout(() => { if (p.exitCode === null) p.kill(); }, 1000);
    }
  }

  dispose() {
    for (const p of this.procs.values()) if (p.exitCode === null) p.kill();
    this.procs.clear();
  }
}

const provider = {
  resolveDebugConfiguration(folder, config) {
    const editor = vscode.window.activeTextEditor;
    const file = editor && editor.document && editor.document.fileName;
    const c = lib.resolveConfig(config, file);
    if (!c) {
      vscode.window.showInformationMessage('ljdap: keine Lua-Datei geöffnet');
      return undefined;
    }
    return c;
  },
};

function activate(context) {
  const factory = new Factory(context);
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory('ljdap', factory),
    vscode.debug.registerDebugConfigurationProvider('ljdap', provider),
    vscode.debug.onDidTerminateDebugSession((s) => factory.sessionEnded(s)),
    factory,
  );
  return { factory };
}

function deactivate() {}

module.exports = { activate, deactivate, Factory, provider };
