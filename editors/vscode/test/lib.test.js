'use strict';
const test = require('node:test');
const assert = require('node:assert');
const path = require('path');
const net = require('net');
const cp = require('child_process');
const lib = require('../lib');
const { Dap } = require('./dap');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const LUA = process.env.LJDAP_TEST_LUA || 'luajit';

test('freePort liefert einen freien Port', async () => {
  const p = await lib.freePort();
  assert.ok(p > 0 && p < 65536);
  await new Promise((resolve, reject) => {
    const s = net.createServer().listen(p, '127.0.0.1', () => s.close(resolve)).on('error', reject);
  });
});

test('launchCommand', () => {
  assert.deepStrictEqual(
    lib.launchCommand({ program: '/p/x.lua', args: ['a', 2], lua: 'lua5.1', log: '/t/l' }, '/ext/ljdap.lua', 4711),
    ['lua5.1', ['/ext/ljdap.lua', '--port', '4711', '--log', '/t/l', '/p/x.lua', 'a', '2']]);
  assert.deepStrictEqual(lib.launchCommand({ program: 'x.lua', ljdap: '/eigen/ljdap.lua' }, '/ext/ljdap.lua', 1),
    ['luajit', ['/eigen/ljdap.lua', '--port', '1', 'x.lua']]);
  assert.throws(() => lib.launchCommand({}, 'l', 1), /program/);
});

test('launchEnv ergänzt die Umgebung', () => {
  const env = lib.launchEnv({ env: { X: 1 } }, { PATH: '/bin' });
  assert.deepStrictEqual(env, { PATH: '/bin', X: '1' });
});

test('resolveConfig', () => {
  assert.strictEqual(lib.resolveConfig({}, undefined), undefined);
  assert.strictEqual(lib.resolveConfig({}, '/a/b.txt'), undefined);
  const c = lib.resolveConfig({}, '/a/b.lua');
  assert.strictEqual(c.request, 'launch');
  assert.strictEqual(c.program, '/a/b.lua');
  assert.strictEqual(c.cwd, '/a');
  const a = lib.resolveConfig({ type: 'ljdap', request: 'attach', name: 'x', port: 5 }, '/a/b.lua');
  assert.strictEqual(a.cwd, undefined);
});

test('waitForPort: Zeitüberschreitung und vorzeitiges Ende', async () => {
  const p = await lib.freePort();
  await assert.rejects(lib.waitForPort(p, '127.0.0.1', 300), /nicht erreichbar/);
  await assert.rejects(lib.waitForPort(p, '127.0.0.1', 3000, () => false), /beendet/);
});

test('Starter-Modus Ende zu Ende: launch, Haltepunkt, exited', async () => {
  const port = await lib.freePort();
  const steps = path.join(ROOT, 'tests', 'fixtures', 'steps.lua');
  const [cmd, args] = lib.launchCommand({ program: steps, lua: LUA }, path.join(ROOT, 'ljdap.lua'), port);
  const proc = cp.spawn(cmd, args, { cwd: ROOT });
  let out = '';
  proc.stdout.on('data', (d) => { out += d; });
  const exited = new Promise((resolve) => proc.on('exit', resolve));
  try {
    await lib.waitForPort(port, '127.0.0.1', 10000, () => proc.exitCode === null);
    const c = new Dap(port);
    await c.connect();
    await c.request('initialize', { adapterID: 'ljdap' });
    await c.request('launch', { program: steps });
    const bp = await c.request('setBreakpoints', { source: { path: steps }, breakpoints: [{ line: 13 }] });
    assert.strictEqual(bp.body.breakpoints[0].verified, true);
    await c.request('configurationDone');
    const st = await c.event('stopped');
    assert.strictEqual(st.body.reason, 'breakpoint');
    const fr = (await c.request('stackTrace', { threadId: 1 })).body.stackFrames[0];
    assert.strictEqual(fr.name, 'rechne');
    assert.strictEqual(fr.line, 13);
    await c.request('continue', { threadId: 1 });
    const ex = await c.event('exited');
    assert.strictEqual(ex.body.exitCode, 0);
    c.close();
    assert.strictEqual(await exited, 0);
    assert.match(out, /steps: 16 Punkt 42/);
  } finally {
    if (proc.exitCode === null) proc.kill();
  }
});

test('Version in package.json passt zu src/ljdap/version.lua (ohne -dev)', () => {
  const fs = require('fs');
  const lua = fs.readFileSync(path.join(ROOT, 'src', 'ljdap', 'version.lua'), 'utf8').match(/return "([^"]+)"/)[1];
  assert.strictEqual(require('../package.json').version, lua.replace(/-.*$/, ''));
});
