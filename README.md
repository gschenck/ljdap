# ljdap

DAP-Server (Debug Adapter Protocol) in reinem Lua für LuaJIT 2.1 und Lua 5.1.
ljdap wird in das zu untersuchende Programm geladen; bedient wird es aus
einem beliebigen DAP-Client (Sublime Text mit Paket „Debugger“, VS Code).

*A pure-Lua Debug Adapter Protocol server for LuaJIT 2.1 / Lua 5.1, loaded
into the debuggee. No Node, no C module, no LuaSocket required.*

> **Stand: M2 (0.1.0-dev).** Haltepunkte (mit Verschiebung von Kommentar-
> und Leerzeilen), Step over/in/out, Stack, Locals/Upvalues/Varargs/Globals
> mit aufklappbaren Tabellen, `ljdap.breakhere()`, `stopOnEntry`,
> `pathMappings`; Linux und Windows. Coroutinen, `evaluate`, bedingte
> Haltepunkte, Logpoints, Fehler-Halt und Pause folgen mit M3.
> Plan: [docs/KONZEPT.md](docs/KONZEPT.md).

## Einbindung

Am einfachsten mit der Ein-Datei-Version `ljdap.lua` (im Repo-Wurzel-
verzeichnis bzw. als Download unter *Releases*): neben das Skript legen oder
in einen Ordner auf dem `LUA_PATH`. Alternativ die Module unter `src/`:

```sh
# nur für die Module unter src/ nötig
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

## Sublime Text (Paket „Debugger“)

1. Paket **Debugger** (daveleroy) über Package Control installieren
   (Sublime Text ≥ Build 4199).
2. Plugin installieren, eine der beiden Formen:
   - `ljdap.sublime-package` aus den *Releases* nach `Installed Packages/`
     legen (*Preferences → Browse Packages…*, dann eine Ebene höher), oder
   - den Ordner `editors/sublime/` (bzw. `ljdap/` aus
     `ljdap-sublime-<version>.zip`) als `Packages/ljdap/` kopieren.
    Die Datei `.python-version` (`3.8`)
   gehört dazu: Plugin und Debugger-Paket müssen im selben Plugin-Host
   laufen (ab Build 4200 ist das Python 3.14, das `3.8` übernimmt).
3. Im `.sublime-project` eine Konfiguration anlegen (Vorlage:
   `editors/sublime/ljdap.sublime-project.example`, oder *Debugger: Add
   Configuration* → *ljdap*):

```json
"debugger_configurations": [
  { "name": "ljdap", "type": "ljdap", "request": "attach",
    "host": "127.0.0.1", "port": 4711 }
]
```

4. Programm starten, z. B. `LJDAP="port=4711,wait=1" luajit -l ljdap skript.lua`
   (Windows: `set LJDAP=port=4711,wait=1`), dann in Sublime *Debugger: Start*.

Weitere `attach`-Felder: `stopOnEntry` (mit `wait=1` an der ersten Zeile
anhalten), `pathMappings` (`[{ "localRoot": "C:\\Projekte\\x", "remoteRoot": "/home/gs/x" }]`,
wenn Programm und Editor verschiedene Pfade sehen), `timeout`.

## VS Code (geplant)

Erweiterung aus `editors/vscode/` mit Debug-Typ `ljdap` (M4).

## Grenzen

- **Geschwindigkeit:** Ohne Haltepunkte kostet ein verbundener Client kaum
  etwas (≈ 1,0–1,5× gegenüber `-joff`). Sobald irgendwo ein Haltepunkt
  gesetzt ist oder gesteppt wird, läuft ein Zeilen-Hook: gemessen ≈ 9–10×
  (Lua 5.1) bzw. ≈ 13–20× (LuaJIT-Interpreter) für aufrufintensiven Code
  (`python3 tests/perf/bench.py`). Rechenlastige Programme: Haltepunkte
  gezielt setzen und wieder entfernen.
- **Tail Calls** (`return f(x)`): LuaJIT ersetzt den Rahmen, „Step over“
  auf so einer Zeile hält in `f`; Lua 5.1 zeigt einen Rahmen „(tail call)“
  und hält in der aufrufenden Funktion.
- Arbeitsverzeichnis: Relative Quellpfade werden mit dem Verzeichnis beim
  Start von ljdap aufgelöst. Wechselt das Programm danach das Verzeichnis
  und lädt relativ, passen die Pfade nicht.
- Stand M2: Haltepunkte und Stepping nur in der Haupt-Coroutine; Bedingungen
  und Logpoints werden noch ignoriert (Haltepunkt hält immer).
- Kein Lua 5.2–5.4, keine echten OS-Threads (eigene `lua_State`).
- stdio-Transport nur blockierend und nur für Programme, die stdin/stdout
  nicht selbst nutzen; Pause im laufenden Programm ist damit nicht möglich.
- Ein Halt in einem FFI-Callback blockiert den C-Aufrufer (SDL/ImGui meist harmlos).

## Entwicklung

- Module in `src/ljdap/`; die eingecheckte Ein-Datei-Version `ljdap.lua`
  wird nur von `luajit tools/amalgamate.lua` erzeugt (nicht von Hand
  ändern); die CI prüft mit `--check`, dass sie aktuell ist. Szenarien gegen
  die Ein-Datei-Version: `LJDAP_SINGLE=1`.
- Unit-Tests: `sh tests/run.sh` (luajit und lua5.1).
- Sublime-Plugin: `python3 -m unittest discover -s tests/editors -v`
  (mit `SUBLIME_DEBUGGER_SRC=<Klon von SublimeDebugger>` zusätzlich Prüfung
  der genutzten internen API).
- Ende-zu-Ende mit echtem Sublime Text (ohne Bildschirm, Xvfb):
  `SUBLIME_TEXT=…/sublime_text SUBLIME_DEBUGGER_SRC=… python3 tests/editors/e2e_sublime.py`
  – setzt Haltepunkt, steppt, prüft Zustand im Debugger-Paket und den
  DAP-Mitschnitt; mit `LJDAP_E2E_OUT=<ordner>` zusätzlich Bildschirmfotos
  und Protokolle (in der CI als Artefakt `sublime-e2e`).
- Szenarien mit echtem DAP-Client: `python3 -m unittest discover -s tests/scenarios -v`;
  andere Interpreter über `LJDAP_INTERPS="luajit;lua5.1;wine /pfad/luajit.exe"`.
- CI: Linux (luajit, lua5.1), Windows-LuaJIT (MinGW) unter Wine und auf
  einem echten Windows-Runner.
- Änderungen: [CHANGELOG.md](CHANGELOG.md), Versionierung nach SemVer.

## Release

1. Version in `src/ljdap/version.lua` und `editors/sublime/ljdap_adapter.py`
   (`VERSION`) setzen, im CHANGELOG `[Unreleased]` in `[x.y.z] – Datum`
   umbenennen, `luajit tools/amalgamate.lua`, Commit auf `main`.
2. Tag setzen und schieben (Büro-PC): `git tag vx.y.z` und `tools\push_tags.cmd`.
3. Der Workflow `release` prüft Tag ↔ Version, testet, baut mit
   `tools/build_release.sh` und veröffentlicht das Release mit `ljdap.lua`,
   `ljdap-sublime-x.y.z.zip`, `ljdap.sublime-package`, `SHA256SUMS`; Text
   aus dem CHANGELOG-Abschnitt. Ohne Tag (manuell gestartet) ist es ein
   Probelauf ohne Veröffentlichung.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
