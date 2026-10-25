// Startet VS Code (über @vscode/test-electron) mit dieser Erweiterung und
// führt test/e2e/suite.js darin aus. Nur in der CI (lädt VS Code herunter).
'use strict';
const path = require('path');
const { runTests } = require('@vscode/test-electron');

const ROOT = path.resolve(__dirname, '..', '..', '..', '..');

(async () => {
  try {
    await runTests({
      extensionDevelopmentPath: path.resolve(__dirname, '..', '..'),
      extensionTestsPath: path.resolve(__dirname, 'suite.js'),
      launchArgs: [ROOT, '--disable-extensions', '--disable-workspace-trust'],
      extensionTestsEnv: { LJDAP_ROOT: ROOT, LJDAP_TEST_LUA: process.env.LJDAP_TEST_LUA || 'luajit' },
    });
  } catch (e) {
    console.error('VS-Code-Test fehlgeschlagen:', e && e.message ? e.message : e);
    process.exit(1);
  }
})();
