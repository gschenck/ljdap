'use strict';
// extension.js mit nachgebildetem vscode-Modul
const test = require('node:test');
const assert = require('node:assert');
const path = require('path');
const Module = require('module');
const { Dap } = require('./dap');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const LUA = process.env.LJDAP_TEST_LUA || 'luajit';

const fake = {
  consoleText: '',
  errors: [],
  registered: {},
  DebugAdapterServer: class { constructor(port, host) { this.port = port; this.host = host; } },
  debug: {
    activeDebugConsole: { append: (t) => { fake.consoleText += t; } },
    registerDebugAdapterDescriptorFactory: (t, f) => { fake.registered.factory = f; return { dispose() {} }; },
    registerDebugConfigurationProvider: (t, p) => { fake.registered.provider = p; return { dispose() {} }; },
    onDidTerminateDebugSession: (cb) => { fake.registered.onEnd = cb; return { dispose() {} }; },
  },
  window: {
    activeTextEditor: undefined,
    showErrorMessage: (m) => { fake.errors.push(m); },
    showInformationMessage: () => {},
  },
};
const origLoad = Module._load;
Module._load = function (request, ...rest) {
  if (request === 'vscode') return fake;
  return origLoad.call(this, request, ...rest);
};
const ext = require('../extension');

const context = { extensionPath: ROOT, subscriptions: [] }; // ljdap.lua liegt im Repo-Wurzelverzeichnis
ext.activate(context);

test('Registrierung', () => {
  assert.ok(fake.registered.factory && fake.registered.provider && fake.registered.onEnd);
  assert.strictEqual(context.subscriptions.length, 4);
});

test('attach liefert DebugAdapterServer', async () => {
  const d = await fake.registered.factory.createDebugAdapterDescriptor({ id: 'a', configuration: { request: 'attach', port: 4712 } });
  assert.deepStrictEqual([d.port, d.host], [4712, '127.0.0.1']);
});

test('launch startet ljdap.lua, Ausgabe in die Debug-Konsole', async () => {
  const steps = path.join(ROOT, 'tests', 'fixtures', 'steps.lua');
  const session = { id: 'l1', configuration: { request: 'launch', program: steps, lua: LUA, cwd: ROOT } };
  const d = await fake.registered.factory.createDebugAdapterDescriptor(session);
  assert.ok(d.port > 0);
  const c = new Dap(d.port);
  await c.connect();
  await c.request('initialize', { adapterID: 'ljdap' });
  await c.request('launch', { program: steps });
  await c.request('configurationDone');
  await c.event('exited');
  c.close();
  await new Promise((r) => setTimeout(r, 300));
  assert.match(fake.consoleText, /steps: 16 Punkt 42/);
  fake.registered.onEnd(session);
});

test('launch mit falschem Interpreter: verständlicher Fehler', async () => {
  const session = { id: 'l2', configuration: { request: 'launch', program: 'x.lua', lua: 'gibt-es-nicht-lua', timeout: 2 } };
  await assert.rejects(fake.registered.factory.createDebugAdapterDescriptor(session), /lässt sich nicht starten/);
  assert.match(fake.errors.pop(), /ljdap: gibt-es-nicht-lua/);
});

test('Sitzungsende beendet den Prozess', async () => {
  const session = { id: 'l3', configuration: { request: 'launch', program: path.join(ROOT, 'tests', 'fixtures', 'count.lua'), args: ['20'], lua: LUA, cwd: ROOT } };
  await fake.registered.factory.createDebugAdapterDescriptor(session);
  const proc = fake.registered.factory.procs.get('l3');
  assert.ok(proc && proc.exitCode === null);
  const ended = new Promise((r) => proc.on('exit', r));
  fake.registered.onEnd(session);
  await ended;
});

test('resolveDebugConfiguration ohne launch.json: aktuelle Lua-Datei', () => {
  fake.window.activeTextEditor = { document: { fileName: '/x/y.lua' } };
  const c = fake.registered.provider.resolveDebugConfiguration(undefined, {});
  assert.strictEqual(c.program, '/x/y.lua');
  fake.window.activeTextEditor = undefined;
  assert.strictEqual(fake.registered.provider.resolveDebugConfiguration(undefined, {}), undefined);
});
