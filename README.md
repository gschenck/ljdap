# ljdap

DAP-Server (Debug Adapter Protocol) in reinem Lua für LuaJIT 2.1 und Lua 5.1.
ljdap wird in das zu untersuchende Programm geladen; bedient wird es aus
einem beliebigen DAP-Client (Sublime Text mit Paket „Debugger“, VS Code).

*A pure-Lua Debug Adapter Protocol server for LuaJIT 2.1 / Lua 5.1, loaded
into the debuggee. No Node, no C module, no LuaSocket required.*

> **Stand:** Konzeptphase (M0). Noch kein lauffähiger Code.
> Siehe [docs/KONZEPT.md](docs/KONZEPT.md).

## Einbindung (geplant)

```sh
luajit -l ljdap skript.lua args…
LJDAP="port=4711,wait=1" luajit -l ljdap skript.lua
luajit ljdap.lua --port 4711 --wait skript.lua args…
```

```lua
local dbg = require("ljdap")
dbg.start{ port = 4711, host = "127.0.0.1", wait = true }
dbg.breakhere()
```

## Einrichtung der Editoren (geplant)

- **Sublime Text:** kleines Zusatzpaket aus `editors/sublime/` nach
  `Packages/ljdap/` kopieren; Konfiguration `"type": "ljdap"` mit
  `"request": "attach"`, `host`, `port`.
- **VS Code:** Erweiterung aus `editors/vscode/`; launch.json mit
  `"type": "ljdap"`.

## Grenzen (geplant für v1)

- Unter dem Debugger läuft LuaJIT ohne JIT (`jit.off()`); das Zeitverhalten
  ändert sich.
- Keine echten OS-Threads (eigene `lua_State`), kein Lua 5.2–5.4.
- Ein Halt in einem FFI-Callback blockiert den C-Aufrufer.

## Entwicklung

- Module in `src/ljdap/`, Ein-Datei-Release `ljdap.lua` wird von
  `tools/amalgamate.lua` erzeugt.
- Tests: `tests/run.sh` (unter `luajit` und `lua5.1`).
- Änderungen: [CHANGELOG.md](CHANGELOG.md), Versionierung nach SemVer.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
