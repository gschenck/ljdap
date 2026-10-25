// Läuft in VS Code: launch-Sitzung mit Haltepunkt, Stack, Weiter, exited.
'use strict';
const path = require('path');
const assert = require('assert');
const vscode = require('vscode');

function waitFor(pred, ms, what) {
  return new Promise((resolve, reject) => {
    const t0 = Date.now();
    const tick = () => {
      const v = pred();
      if (v) return resolve(v);
      if (Date.now() - t0 > ms) return reject(new Error('Zeitüberschreitung: ' + what));
      setTimeout(tick, 100);
    };
    tick();
  });
}

async function run() {
  const ROOT = process.env.LJDAP_ROOT;
  const steps = path.join(ROOT, 'tests', 'fixtures', 'steps.lua');
  const msgs = [];
  vscode.debug.registerDebugAdapterTrackerFactory('ljdap', {
    createDebugAdapterTracker() {
      return { onDidSendMessage: (m) => msgs.push(m), onError: (e) => msgs.push({ type: 'error', e: String(e) }) };
    },
  });
  vscode.debug.addBreakpoints([new vscode.SourceBreakpoint(
    new vscode.Location(vscode.Uri.file(steps), new vscode.Position(12, 0)))]);
  const started = await vscode.debug.startDebugging(undefined, {
    type: 'ljdap', request: 'launch', name: 'ljdap-e2e', program: steps, cwd: ROOT,
    lua: process.env.LJDAP_TEST_LUA || 'luajit',
  });
  assert.ok(started, 'startDebugging');
  const stopped = await waitFor(() => msgs.find((m) => m.type === 'event' && m.event === 'stopped'),
    20000, 'stopped-Event; Nachrichten: ' + JSON.stringify(msgs).slice(0, 1500));
  assert.strictEqual(stopped.body.reason, 'breakpoint');
  const session = vscode.debug.activeDebugSession;
  const st = await session.customRequest('stackTrace', { threadId: 1 });
  assert.strictEqual(st.stackFrames[0].name, 'rechne');
  assert.strictEqual(st.stackFrames[0].line, 13);
  const sc = await session.customRequest('scopes', { frameId: st.stackFrames[0].id });
  const loc = await session.customRequest('variables', { variablesReference: sc.scopes[0].variablesReference });
  assert.deepStrictEqual(loc.variables.map((v) => [v.name, v.value]), [['a', '3'], ['b', '4']]);
  const ev = await session.customRequest('evaluate', { expression: 'a + b', frameId: st.stackFrames[0].id, context: 'watch' });
  assert.strictEqual(ev.result, '7');
  await session.customRequest('continue', { threadId: 1 });
  const exited = await waitFor(() => msgs.find((m) => m.type === 'event' && m.event === 'exited'), 20000, 'exited');
  assert.strictEqual(exited.body.exitCode, 0);
  console.log('VS-Code-E2E OK: Halt rechne:13, Variablen, evaluate, exited 0');
}

module.exports = { run };
