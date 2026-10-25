// ljdap – Hilfsfunktionen der VS-Code-Erweiterung ohne Abhängigkeit von
// `vscode` (mit node:test prüfbar).
'use strict';

const net = require('net');
const path = require('path');

/** Freien TCP-Port auf 127.0.0.1 ermitteln. */
function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

/** Wartet, bis auf host:port eine TCP-Verbindung möglich ist. */
function waitForPort(port, host = '127.0.0.1', timeoutMs = 5000, isAlive = () => true) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      if (!isAlive()) return reject(new Error('Lua-Programm wurde vor dem Verbindungsaufbau beendet'));
      const sock = net.connect(port, host);
      sock.once('connect', () => { sock.destroy(); resolve(); });
      sock.once('error', () => {
        sock.destroy();
        if (Date.now() > deadline) reject(new Error(`ljdap nicht erreichbar auf ${host}:${port}`));
        else setTimeout(attempt, 100);
      });
    };
    attempt();
  });
}

/**
 * Befehlszeile für den Starter-Modus: [interpreter, argumente].
 * ljdapPath: Pfad zu ljdap.lua (Vorgabe aus der Erweiterung).
 */
function launchCommand(config, ljdapPath, port) {
  if (!config.program) throw new Error('launch: Feld "program" fehlt');
  const args = [config.ljdap || ljdapPath, '--port', String(port)];
  if (config.log) args.push('--log', String(config.log));
  args.push(String(config.program), ...(config.args || []).map(String));
  return [config.lua || 'luajit', args];
}

/** Umgebung für den Prozess: vorhandene Umgebung plus config.env. */
function launchEnv(config, base = process.env) {
  const env = Object.assign({}, base);
  for (const [k, v] of Object.entries(config.env || {})) env[k] = String(v);
  return env;
}

/** Vorgaben ergänzen (leere launch.json → aktuelle Datei starten). */
function resolveConfig(config, activeFile) {
  const c = Object.assign({}, config);
  if (!c.type && !c.request && !c.name) {
    if (!activeFile || !activeFile.endsWith('.lua')) return undefined;
    Object.assign(c, { type: 'ljdap', request: 'launch', name: 'Lua: aktuelle Datei', program: activeFile });
  }
  if (c.request === 'launch' && !c.cwd && c.program) c.cwd = path.dirname(c.program);
  return c;
}

module.exports = { freePort, waitForPort, launchCommand, launchEnv, resolveConfig };
