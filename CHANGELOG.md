# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden in dieser Datei
dokumentiert.

Das Format basiert auf [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
und dieses Projekt hält sich an [Semantic Versioning](https://semver.org/lang/de/).

## [Unreleased]

### Hinzugefügt
- M2: Haltepunkte (`ljdap.breakpoints`): Datei wird beim Setzen übersetzt
  (nicht ausgeführt), gültige Zeilen aller Funktionen über `jit.util` bzw.
  `string.dump` (`ljdap.lines`); Haltepunkte auf Kommentar-/Leerzeilen
  wandern zur nächsten Codezeile und sind sofort verified.
- M2: Stepping (`next`, `stepIn`, `stepOut`, `continue`), `stackTrace`
  mit Paging, `scopes` (Lokal, Varargs unter LuaJIT, Upvalues,
  Global/fenv), `variables` mit aufklappbaren Tabellen, sortierten
  Schlüsseln, Metatabelle und Paging (`ljdap.vars`); Agentencode wird beim
  Steppen übersprungen.
- M2: `ljdap.breakhere()` hält mit verbundenem Client an; `stopOnEntry`,
  `pathMappings` (Editor und Programm mit verschiedenen Pfaden),
  `linesStartAt1`/`columnsStartAt1` (`ljdap.paths`).
- M2: Sublime-Text-Plugin `editors/sublime/` für das Paket „Debugger“ mit
  Konfigurationsvorlage und Schema; Tests mit nachgebildetem Paket und
  Prüfung der internen API am echten Quelltext.
- M2: Hooks (`ljdap.hooks`): Zeilen-Hook mit Vorfilter nur bei
  Haltepunkten/Stepping, sonst nur Count-Hook (gemessen günstiger als
  Call/Return-Hooks, siehe Konzept 6); Messskript `tests/perf/bench.py`.
- M1: `ljdap.json` – eigener JSON-Kodierer/-Dekodierer: UTF-8-Prüfung
  (ungültige Folgen → U+FFFD), Surrogatpaare, `null` in Objekten wird
  weggelassen (Sublime-Debugger), unabhängig von der C-Locale (Lua 5.1 mit
  Dezimalkomma).
- M1: `ljdap.transport` – nicht blockierender TCP-Server per FFI für POSIX
  (Linux, macOS) und Windows (ws2_32), Rückfall LuaSocket, stdio-Modus
  (Windows im Binärmodus); Content-Length-Rahmen mit Teilpaketen. Eigene
  FFI-Namen (`ljdap_*`), keine Kollision mit cdefs des Programms.
- M1: `ljdap.protocol`, `ljdap.session` – `initialize`, `attach`,
  `configurationDone`, `threads`, `disconnect`; `setBreakpoints` und
  `setExceptionBreakpoints` antworten (Haltepunkte noch unverifiziert);
  Wiederverbinden nach Trennen; Start über `LJDAP` bzw. `-l ljdap`;
  `ljdap.poll()` für Hauptschleifen; JIT aus bei verbundenem Client;
  Optionen `wait`, `backend`, `poll`, `jit`, `log`.
- Tests: Unit-Tests für JSON und Transport, Python-DAP-Client
  `tests/dap_client.py` mit Sublime-Modus (`null`-Felder), Szenarien
  `tests/scenarios/test_m1.py`; CI mit Linux, Wine und Windows-Runner.
- Konzept `docs/KONZEPT.md` mit Rechercheergebnissen zu Sublime-Debugger,
  VS Code und lua-debug (M0).
- Repo-Gerüst: README, MIT-Lizenz, Changelog, CI-Grundgerüst,
  Test-Runner `tests/run.sh`, `tools/push_tags.cmd`.
