# ljdap

DAP-Server (Debug Adapter Protocol) in reinem Lua für LuaJIT 2.1 und Lua 5.1.
ljdap wird in das zu untersuchende Programm geladen; bedient wird es aus
einem beliebigen DAP-Client (Sublime Text mit Paket „Debugger“, VS Code).

*A pure-Lua Debug Adapter Protocol server for LuaJIT 2.1 / Lua 5.1, loaded
into the debuggee. No Node, no C module, no LuaSocket required.*

> **Stand: M4 (0.1.0-dev).** Starter-Modus und `launch` aus Sublime Text
> und VS Code, Haltepunkte (Verschiebung von Kommentar- und
> Leerzeilen, Bedingungen, Trefferzähler, Logpoints), Step over/in/out auch
> über Coroutine-Grenzen, Pause, Stack und Variablen aller Coroutinen,
> Werte ändern und Ausdrücke auswerten (Watch, Hover, Konsole), Halt bei
> Fehlern (nicht abgefangen / alle), `ljdap.breakhere()`, `stopOnEntry`,
> `pathMappings`; Linux und Windows. Plan: [docs/KONZEPT.md](docs/KONZEPT.md).

## Schnellstart

Aus dem Editor: Plugin für [Sublime Text](#sublime-text-paket-debugger)
oder [VS Code](#vs-code) installieren, Konfiguration mit
`"request": "launch"` und `"program": "${file}"` anlegen, Debuggen starten.
Der Editor ruft dann selbst den **Starter-Modus** auf:

```sh
luajit ljdap.lua [--port 4711] [--host 127.0.0.1] [--nowait] [--jit off] [--log datei] skript.lua args…
lua5.1 ljdap.lua --version
```

Das Skript bekommt `arg` und `...` wie beim Interpreter, läuft unter
`xpcall` (Halt bei nicht abgefangenen Fehlern in beiden Interpretern) und
wartet bis `configurationDone`. Endet das Skript, meldet ljdap `exited`
mit dem Rückgabewert; „Stop“ im Editor beendet das Programm.

Für Programme, die anders gestartet werden (Hauptprogramm mit eigener
Umgebung, Server, TUI): ljdap einbinden und mit `attach` verbinden.

## Einbindung (attach)

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

   Die Datei `.python-version` (`3.8`) gehört dazu: Plugin und
   Debugger-Paket müssen im selben Plugin-Host laufen (ab Build 4200 ist
   das Python 3.14, das `3.8` übernimmt).
3. Im `.sublime-project` eine Konfiguration anlegen (Vorlage:
   `editors/sublime/ljdap.sublime-project.example`, oder *Debugger: Add
   Configuration* → *ljdap*):

```json
"debugger_configurations": [
  { "name": "Skript", "type": "ljdap", "request": "launch",
    "program": "${file}", "lua": "luajit" },
  { "name": "ljdap", "type": "ljdap", "request": "attach",
    "host": "127.0.0.1", "port": 4711 }
]
```

4. `launch`: *Debugger: Start* startet das Skript selbst; Ausgabe in der
   Debugger-Konsole. Weitere Felder: `args`, `cwd`, `env`, `lua`
   (Interpreter oder Pfad), `port` (Vorgabe frei gewählt), `ljdap`
   (eigener Pfad zu `ljdap.lua`, Vorgabe aus dem Paket), `stopOnEntry`.
5. `attach`: Programm starten, z. B. `LJDAP="port=4711,wait=1" luajit -l ljdap skript.lua`
   (Windows: `set LJDAP=port=4711,wait=1`), dann in Sublime *Debugger: Start*.

Weitere `attach`-Felder: `stopOnEntry` (mit `wait=1` an der ersten Zeile
anhalten), `pathMappings` (`[{ "localRoot": "C:\\Projekte\\x", "remoteRoot": "/home/gs/x" }]`,
wenn Programm und Editor verschiedene Pfade sehen), `timeout`.

## VS Code

1. `ljdap-vscode-<version>.vsix` aus den *Releases* installieren
   (*Erweiterungen → … → Aus VSIX installieren*, oder
   `code --install-extension ljdap-vscode-<version>.vsix`).
2. `.vscode/launch.json`:

```json
{
  "version": "0.2.0",
  "configurations": [
    { "type": "ljdap", "request": "launch", "name": "Lua-Skript",
      "program": "${file}", "lua": "luajit" },
    { "type": "ljdap", "request": "attach", "name": "ljdap anhängen",
      "host": "127.0.0.1", "port": 4711 }
  ]
}
```

Felder wie bei Sublime Text; `ljdap.lua` liegt in der Erweiterung.
Haltepunkte in `.lua`-Dateien setzen, F5. Endet der Prozess, bevor sich
VS Code verbinden konnte (falscher Interpreter, Syntaxfehler im Starter),
zeigt die Erweiterung eine Meldung mit der Ausgabe.

## Grenzen

- **Geschwindigkeit** (`python3 tests/perf/bench.py`, aufrufintensiver
  Code, Faktor gegenüber dem Lauf ohne ljdap; LuaJIT bezogen auf `-joff`,
  weil der JIT bei verbundenem Client aus ist):

  | Lauf | LuaJIT 2.1 | Lua 5.1 |
  |---|---|---|
  | ohne ljdap, JIT an | ≈ 0,1× | – |
  | Client verbunden, keine Haltepunkte | ≈ 1,0–1,7× | ≈ 1,0–1,6× |
  | Haltepunkt (in anderer Datei) oder Stepping | ≈ 13–20× | ≈ 9–11× |

  Sobald irgendwo ein Haltepunkt gesetzt ist, läuft ein Zeilen-Hook; das
  kostet in reinem Lua so viel. Rechenlastige Programme: Haltepunkte
  gezielt setzen und wieder entfernen.
- **Tail Calls** (`return f(x)`): LuaJIT ersetzt den Rahmen, „Step over“
  auf so einer Zeile hält in `f`; Lua 5.1 zeigt einen Rahmen „(tail call)“
  und hält in der aufrufenden Funktion.
- Arbeitsverzeichnis: Relative Quellpfade werden mit dem Verzeichnis beim
  Start von ljdap aufgelöst. Wechselt das Programm danach das Verzeichnis
  und lädt relativ, passen die Pfade nicht.
- **Coroutinen:** erfasst werden Coroutinen, die über `coroutine.create`/
  `wrap`/`resume` laufen, nachdem ljdap geladen ist. Code, der diese
  Funktionen vorher in lokale Variablen kopiert hat, sieht ljdap unter Lua
  5.1 nicht (dort gelten Hooks je Coroutine; unter LuaJIT global). Darum
  ljdap per `-l ljdap` beim Start laden.
- **Fehler-Halt:**
  - *Nicht abgefangen* (Standard): im Starter-Modus (`launch`) immer;
    sonst unter LuaJIT nur, wenn ljdap mit
    `luajit … -l ljdap skript.lua` geladen wird – ljdap führt das Skript
    dann selbst unter `xpcall` aus (abschaltbar mit `LJDAP="run=0"`); mit
    `require("ljdap").start{}` aus dem Programm heraus gibt es diesen Halt
    nicht. Unter Lua 5.1 über `debug.traceback` des Interpreters.
    Fehler, die eine Coroutine beenden, hält ljdap nur unter LuaJIT an
    (Lua 5.1 erlaubt kein `yield` über `xpcall`).
  - *Alle Fehler (auch in pcall)*: ljdap ersetzt solange `pcall`/`xpcall`
    durch Hüllen; Code mit vorher kopiertem `local pcall = pcall` wird
    nicht erfasst.
- **Ausdrücke** werden im Programm ausgeführt (auch Funktionsaufrufe mit
  Seiteneffekten); eine Endlosschleife im Ausdruck hält das Programm an.
  Varargs stehen als Pseudovariable `vararg` bereit (nur LuaJIT).
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
- VS-Code-Erweiterung: `cd editors/vscode && npm test` (nachgebildetes
  `vscode`-Modul, echter ljdap-Prozess; `LJDAP_TEST_LUA=lua5.1` für den
  anderen Interpreter); Ende-zu-Ende mit echtem VS Code nur in der CI
  (`test/e2e/run.js`, `@vscode/test-electron` unter Xvfb).
- Szenarien mit echtem DAP-Client: `python3 -m unittest discover -s tests/scenarios -v`;
  andere Interpreter über `LJDAP_INTERPS="luajit;lua5.1;wine /pfad/luajit.exe"`.
- CI: Linux (luajit, lua5.1), Windows-LuaJIT (MinGW) unter Wine und auf
  einem echten Windows-Runner, Sublime Text und VS Code Ende-zu-Ende.
- Änderungen: [CHANGELOG.md](CHANGELOG.md), Versionierung nach SemVer.

## Release

1. Version in `src/ljdap/version.lua`, `editors/sublime/ljdap_adapter.py`
   (`VERSION`) und `editors/vscode/package.json` setzen (Tests prüfen den
   Gleichlauf), im CHANGELOG `[Unreleased]` in `[x.y.z] – Datum`
   umbenennen, `luajit tools/amalgamate.lua`, Commit auf `main`.
2. Tag setzen und schieben (Büro-PC): `git tag vx.y.z` und `tools\push_tags.cmd`.
3. Der Workflow `release` prüft Tag ↔ Version, testet, baut mit
   `tools/build_release.sh` und veröffentlicht das Release mit `ljdap.lua`,
   `ljdap-sublime-x.y.z.zip`, `ljdap.sublime-package`,
   `ljdap-vscode-x.y.z.vsix`, `SHA256SUMS`; Text
   aus dem CHANGELOG-Abschnitt. Ohne Tag (manuell gestartet) ist es ein
   Probelauf ohne Veröffentlichung.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
