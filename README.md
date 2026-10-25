# ljdap

DAP-Server (Debug Adapter Protocol) in reinem Lua für LuaJIT 2.1 und Lua 5.1.
ljdap wird in das zu untersuchende Programm geladen; bedient wird es aus
einem beliebigen DAP-Client (Sublime Text mit Paket „Debugger“, VS Code).

*A pure-Lua Debug Adapter Protocol server for LuaJIT 2.1 / Lua 5.1, loaded
into the debuggee. No Node, no C module, no LuaSocket required.*

> **Stand: M1 (0.1.0-dev).** Verbindung, Initialisierung, Anhängen und
> Trennen funktionieren unter Linux und Windows. Haltepunkte, Stepping und
> Variablen folgen mit M2. Plan: [docs/KONZEPT.md](docs/KONZEPT.md).

## Einbindung

Während der Entwicklung liegen die Module unter `src/`; das
Ein-Datei-Release `ljdap.lua` folgt mit M4.

```sh
# Modulpfad (bis M4)
export LUA_PATH="/pfad/zu/ljdap/src/?.lua;/pfad/zu/ljdap/src/?/init.lua;;"

luajit -l ljdap skript.lua args…                  # Vorgaben: 127.0.0.1:4711, wait=0
LJDAP="port=4711,wait=1" luajit -l ljdap skript.lua
```

```lua
local dbg = require("ljdap")
dbg.start{ port = 4711, host = "127.0.0.1", wait = true }
-- in der Hauptschleife (siehe „JIT“ unten):
dbg.poll()
```

`require("ljdap")` startet nur dann von selbst, wenn `LJDAP` gesetzt ist
oder das Modul über `-l ljdap` geladen wurde; sonst erst mit `dbg.start{}`.
Schlägt der Start fehl (Port belegt), meldet ljdap das auf stderr und das
Programm läuft ohne Debugger weiter.

### Optionen (`LJDAP="k=v,k=v"` bzw. `start{…}`)

| Option | Vorgabe | Bedeutung |
|---|---|---|
| `host` | `127.0.0.1` | Adresse (nur IPv4 in Punktschreibweise) |
| `port` | `4711` | TCP-Port |
| `wait` | `0` | `1`: Programm wartet, bis ein Client `configurationDone` geschickt hat |
| `backend` | `auto` | `posix`, `windows` (FFI), `luasocket`, `stdio` |
| `poll` | `10000` | Socket-Abfrage alle n Lua-Anweisungen (Count-Hook), `0` = aus |
| `jit` | `on` | `off`: `jit.off()` beim Start |
| `log` | – | Datei für einen Mitschnitt aller DAP-Nachrichten |

### JIT und spätes Anhängen

Lua-Hooks laufen unter LuaJIT nicht in kompiliertem Code. ljdap schaltet
den JIT deshalb **ab, sobald ein Client verbunden ist**, und wieder an,
wenn er sich trennt. Das Zeitverhalten unter dem Debugger ist daher anders.

Ohne verbundenen Client bleibt der JIT an; ein Client, der sich **später**
verbinden will (`wait=0`), wird dann nur angenommen, wenn das Programm
Interpreter-Code ausführt. Für Programme mit Hauptschleife (TUI, GUI):

- `require("ljdap").poll()` einmal je Durchlauf aufrufen (billig: ein
  `poll()`-Systemaufruf), oder
- mit `jit=off` starten.

Unter Lua 5.1 gibt es diese Einschränkung nicht.

## Einrichtung der Editoren (geplant)

- **Sublime Text:** kleines Zusatzpaket aus `editors/sublime/` nach
  `Packages/ljdap/` kopieren; Konfiguration `"type": "ljdap"` mit
  `"request": "attach"`, `host`, `port`.
- **VS Code:** Erweiterung aus `editors/vscode/`; launch.json mit
  `"type": "ljdap"`.

## Grenzen

- Kein Lua 5.2–5.4, keine echten OS-Threads (eigene `lua_State`).
- stdio-Transport nur blockierend und nur für Programme, die stdin/stdout
  nicht selbst nutzen; Pause im laufenden Programm ist damit nicht möglich.
- Ein Halt in einem FFI-Callback blockiert den C-Aufrufer (ab M2).

## Entwicklung

- Module in `src/ljdap/`; Ein-Datei-Release `ljdap.lua` (M4) wird von
  `tools/amalgamate.lua` erzeugt.
- Unit-Tests: `sh tests/run.sh` (luajit und lua5.1).
- Szenarien mit echtem DAP-Client: `python3 -m unittest discover -s tests/scenarios -v`;
  andere Interpreter über `LJDAP_INTERPS="luajit;lua5.1;wine /pfad/luajit.exe"`.
- CI: Linux (luajit, lua5.1), Windows-LuaJIT (MinGW) unter Wine und auf
  einem echten Windows-Runner.
- Änderungen: [CHANGELOG.md](CHANGELOG.md), Versionierung nach SemVer.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
