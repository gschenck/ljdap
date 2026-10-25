# ljdap – Konzept

Stand 2026-10-25 (fortgeschrieben bis M2, siehe 15). Ein DAP-Server (Debug Adapter Protocol) in reinem Lua für
LuaJIT, der in das zu untersuchende Programm geladen wird. Bedienoberfläche
ist ein beliebiger DAP-Client: Sublime Text (Paket „Debugger“), VS Code,
später ein F7Cmdr-Frontend.

## 1 Entscheidungen von GS

| Punkt | Entscheidung |
|---|---|
| Name | **ljdap** |
| Repo | eigenes, **öffentliches** GitHub-Repo `gschenck/ljdap`, Lizenz **MIT** |
| Lua-Versionen | **LuaJIT 2.1 und Lua 5.1** zuerst; 5.2–5.4 später |
| TCP-Code | eigener, kleiner TCP-Teil per FFI im Agenten; die Doppelung zu F7Cmdr `net/sock.lua` ist gewollt (Agent muss abhängigkeitsfrei sein). F7Cmdr übernimmt nichts aus ljdap und umgekehrt. |
| Vorgehen | Konzept zuerst ins Repo, Bau erst nach Bestätigung durch GS |

Rahmen aus der Diskussion: GS arbeitet neben F7Cmdr hauptsächlich mit
Sublime Text. Fertige Lua-Anbindungen für Sublime (SubDebug/MobDebug: nur
ST3, LuaSocket nötig; local-lua-debugger: braucht Node) überzeugen nicht.
Das Sublime-Paket „Debugger“ (daveleroy, ST4, DAP) ist ein gutes Frontend,
liefert aber keinen Lua-Adapter mit.

## 2 Ziele und Nicht-Ziele (Version 1)

**Ziele**
- Eine Datei zum Einbinden, ohne Abhängigkeiten (kein Node, keine C-DLL,
  kein LuaSocket nötig): `luajit -l ljdap skript.lua` oder
  `require("ljdap").start{...}`.
- Läuft in Skripten, TUI-Programmen (F7Cmdr selbst) und GUI-Programmen
  (FemConn, Skeleton, gsText); Linux und Windows.
- Haltepunkte (auch bedingt, Trefferzähler, Logpoints), Step In/Over/Out,
  Weiter, Pause, Stack, Locals/Upvalues/Globals mit aufklappbaren Tabellen,
  Werte ändern, Ausdrücke auswerten, Anhalten bei Fehler.
- Coroutinen als DAP-„Threads“.

**Nicht-Ziele v1**
- Echte OS-Threads (eigener lua_State je Thread, F7Cmdr `threads.lua`).
- Lua 5.2–5.4 (`_ENV`, `goto`, andere Vararg/Coroutine-Details).
- Hot-Reload, Rückwärts-Debugging, Profiler.
- Eigener Adapter-Prozess: ljdap **ist** der DAP-Server im Debuggee.

## 3 Einbindung (API-Entwurf)

```
luajit -l ljdap skript.lua args…        # Optionen über Umgebung LJDAP
LJDAP="port=4711,wait=1" luajit -l ljdap skript.lua
luajit ljdap.lua --port 4711 --wait skript.lua args…   # Starter-Modus
```
```lua
local dbg = require("ljdap")
dbg.start{ port = 4711, host = "127.0.0.1", wait = true }  -- wait: blockiert bis Client verbunden
dbg.breakhere()      -- programmatischer Haltepunkt (no-op ohne Client)
dbg.stop()
```
- `wait=false`: Programm läuft weiter, Client kann sich später verbinden
  (Anhängen an laufenden Prozess, wichtig für F7Cmdr und GUI-Programme).
- Ohne Client und ohne Haltepunkte: Hook-Kosten nahe null (nur Count-Hook
  zum Socket-Abfragen, siehe 6).
- Ausgabe: optional `print`/`io.write` zusätzlich als DAP-`output`-Event.

## 4 Repo-Aufbau

```
ljdap/
  README.md            Einbindung, Sublime/VS-Code-Einrichtung, Grenzen
  LICENSE              MIT
  CHANGELOG.md
  docs/KONZEPT.md      dieses Dokument (fortgeschrieben)
  src/ljdap/           Module (Entwicklung)
    json.lua           eigener JSON-Kodierer/-Dekodierer (UTF-8, große Zahlen, null)
    transport.lua      TCP (FFI POSIX/ws2_32), Rückfall LuaSocket, stdio; Content-Length-Rahmen
    protocol.lua       DAP-Nachrichten: Requests, Responses, Events, seq
    hooks.lua          sethook-Strategie, Step-Zustand, Coroutinen-Umhüllung
    breakpoints.lua    Haltepunkte, Bedingungen, Trefferzähler, Logpoints
    vars.lua           Variablen-Referenzen, Tabellen, cdata, Formatierung
    eval.lua           Ausdrücke im Frame (setfenv-Umgebung)
    paths.lua          Pfad-Normalisierung, Quelle <-> Datei
    session.lua        Zustandsmaschine, Haltschleife
  ljdap.lua            Ein-Datei-Release, erzeugt von tools/amalgamate.lua (eingecheckt)
  tools/amalgamate.lua
  editors/
    sublime/           Debugger-Adapterkonfiguration bzw. kleines Python-Plugin
    vscode/launch.json Beispiel mit "debugServer"
  tests/
    unit/*.lua         json, paths, vars, eval (luajit und lua5.1)
    dap_client.py      minimaler DAP-Client
    scenarios/*.py     echte Sitzungen gegen tests/fixtures/*.lua
    fixtures/
  .github/workflows/ci.yml   Linux luajit + lua5.1; Windows-Teil unter Wine
```
Regel: Entwicklung in `src/`, das eingecheckte `ljdap.lua` wird nur durch
`tools/amalgamate.lua` erzeugt; die CI prüft, dass es aktuell ist.
**Umgesetzt nach M2 (vorgezogen):** Module als `package.preload`, `init.lua`
als Hauptchunk (gleiche Stack-Ebenen für die `-l`-Erkennung). Agentencode
wird in der Ein-Datei-Version an genau dieser Datei erkannt, nicht am
Verzeichnis. Releases über den Workflow `release` bei Tag `v*`
(Dateien: `ljdap.lua`, `ljdap-sublime-<v>.zip`, `ljdap.sublime-package`,
`SHA256SUMS`); kein „nightly“ (Entscheidung GS).

## 5 Transport

- **ljdap ist TCP-Server** auf `127.0.0.1:<port>` (Vorgabe 4711, Annahme),
  der Client verbindet sich. Das passt zu VS Code (`"debugServer": 4711` in
  launch.json, ohne Erweiterung) und vermutlich zum Sublime-Debugger
  (**prüfen**, siehe 12). Optional Gegenrichtung `connect=host:port`.
- **FFI POSIX:** socket/setsockopt(SO_REUSEADDR)/bind/listen/accept/recv/
  send/poll, nicht blockierend über fcntl O_NONBLOCK. **Windows:** ws2_32
  (WSAStartup, ioctlsocket FIONBIO, select, closesocket). SIGPIPE: MSG_NOSIGNAL
  (Linux) bzw. SO_NOSIGPIPE (macOS).
- **Rückfall:** LuaSocket, wenn ohne FFI (Lua 5.1) vorhanden; sonst stdio-Modus
  (`--stdio`, nur für Programme, die stdin/stdout nicht selbst nutzen).
- **Rahmen:** `Content-Length: n\r\n\r\n<json>`; Teilpakete puffern.
- Verbindungsabbruch: Haltepunkte bleiben, Programm läuft weiter, neuer
  Client kann sich verbinden.

## 6 Hook-Strategie (Kern, größte Fehlerquelle)

- **JIT:** Zeilen-Hooks laufen in kompilierten Traces nicht. Bei aktivem
  Client mit Haltepunkten oder Stepping `jit.off()`; nach Trennen wieder
  `jit.on()` (Annahme: `jit.flush()` nötig, prüfen). Im README benennen:
  Zeitverhalten unter dem Debugger ist anders.
- ~~**Selektiver Zeilen-Hook:** Grundzustand nur Call/Return-Hook …~~
  **Umgesetzt (M2, nach Messung):** Zeilen-Hook nur, wenn irgendwo ein
  Haltepunkt gesetzt ist oder gesteppt wird; sonst nur der Count-Hook.
  Im Hook ein Vorfilter ohne `getinfo`: Tabelle „Zeilennummer → Anzahl
  Haltepunkte über alle Dateien“, erst bei Treffer Quelle vergleichen.
  Messung (3 Mio. Aufrufe, Interpreter): leerer Lua-Hook „l“ 4–7×, „c“
  2–2,5×, „cr“ 3,6×; Call-Hook mit Quellprüfung je Aufruf 20×, mit
  Zwischenspeicher je Funktion 9–15×; schlanker Zeilen-Hook mit Vorfilter
  6× (Lua 5.1) bzw. 14× (LuaJIT). Der selektive Ansatz ist also nicht
  schneller, weil schon jeder Call/Return-Hook-Aufruf zählt. Gesamt mit
  ljdap und einem Haltepunkt in anderer Datei: ≈ 9–10× (Lua 5.1),
  ≈ 13–20× (LuaJIT, ohnehin ohne JIT); ohne Haltepunkt ≈ 1,0–1,5×
  (`tests/perf/bench.py`).
- **Step-Logik:** Stack-Tiefe zum Zeitpunkt des Befehls merken; over = halten
  bei Tiefe ≤ Start, in = nächste Zeile beliebig, out = Tiefe < Start. Tail
  calls (LuaJIT „tail return“) berücksichtigen.
  **Gemessen (M2):** Bei `return g(x)` ersetzt LuaJIT den Rahmen (Tiefe
  gleich, `getinfo` meldet den alten Namen) → „Step over“ hält in `g`.
  Lua 5.1 legt einen Pseudorahmen „(tail call)“ an (Tiefe + 1) → „Step
  over“ hält im Aufrufer. Beides bleibt so, steht im README. Nach einem
  Rücksprung meldet Lua die Aufrufzeile nicht erneut; gehalten wird an der
  nächsten neuen Zeile.
- **Agentencode beim Steppen überspringen:** Quellen unter dem Verzeichnis
  von `ljdap/` (mit vereinheitlichten Trennern; `require` erzeugt unter
  Windows gemischte Trenner).
- **Pause und Socket-Abfrage:** Count-Hook alle N Anweisungen (z. B. 10 000,
  einstellbar) prüft nicht blockierend den Socket. Pause setzt
  „bei nächster Zeile halten“. Zu prüfen: Count-Hook unter JIT (läuft nicht
  in Traces) → bei verbundenem Client ohnehin jit.off; ohne Client reicht
  das seltene Abfragen beim Verbindungsaufbau (accept) per Count-Hook im
  Interpreter, sonst Hinweis „Anhängen wirkt erst nach Interpreter-Code“.
  **Gemessen (M1):** Mit JIT wird ein Client während einer kompilierten
  Schleife nicht angenommen; mit `jit=off`, unter Lua 5.1 oder mit
  `ljdap.poll()` in der Schleife sofort. Umsetzung M1: JIT aus (`jit.off()`
  + `jit.flush()`), sobald ein Client verbunden ist, wieder an nach dem
  Trennen; ohne Client `ljdap.poll()` bzw. Option `jit=off` (README).
- **Coroutinen:** Hooks gelten je Coroutine. `coroutine.create/wrap` umhüllen
  und Hook in jeder neuen Coroutine setzen; DAP-Thread-ID je Coroutine
  (schwache Tabelle). Haupt-Coroutine = Thread 1. Stop in Coroutine zeigt
  deren Stack.
  Zusätzlich `coroutine.resume` umhüllen: Hook beim ersten Resume einer
  noch unbekannten Coroutine nachsetzen. So werden auch Coroutinen erfasst,
  die vor dem Laden von ljdap bzw. vor dem Verbinden entstanden sind
  (Lehre aus huanzai/lua-debug). Grenze: Code, der `coroutine.resume`/`wrap`
  vor dem Laden von ljdap in eine lokale Variable kopiert hat, wird nicht
  erreicht → README empfiehlt `-l ljdap` beim Start.
- **Haltschleife:** Im Hook blockierend auf Requests warten (stackTrace,
  variables, evaluate, continue …), danach zurückkehren. Agentenframes aus
  dem Stack ausblenden (Ebenen-Offset ermitteln, nicht hart codieren).
  **Umgesetzt (M2):** Jeder Halt merkt sich eine Markierungsfunktion (den
  Hook bzw. `ljdap.breakhere`); Frame 0 ist der Rahmen direkt darüber, die
  Ebene wird bei jeder Anfrage per `getinfo(l, "f")` neu gesucht. Wichtig:
  kein Tail Call auf dem Weg zur Markierung (`breakhere`).
- **Wiedereintritt:** Sperre gegen Hook-Rekursion (Agent ruft Lua-Code, z. B.
  `__tostring`, `__index` bei der Anzeige); Fehler im Agenten abfangen und
  als `output`-Event melden, nie das Programm abbrechen.
- **Anhalten bei Fehler:** v1 nicht abgefangene Fehler: Einstieg in xpcall
  mit Handler, der am Fehlerort die Haltschleife betritt (Stack ist im
  Handler noch intakt). Option „alle Fehler“ (auch in pcall) per Umhüllung
  von `error`/`assert` – als Ausnahmefilter „raised“ vs. „uncaught“.
- **FFI-Callbacks:** Halt im Callback blockiert den C-Aufrufer (SDL/ImGui
  meist harmlos). Kein Verbot, Hinweis im README.

## 7 DAP-Umfang v1

Requests: `initialize`, `attach`, `launch` (nur Starter-Modus), `configurationDone`,
`setBreakpoints` (condition, hitCondition, logMessage), `setExceptionBreakpoints`
(Filter `uncaught`, `raised`), `threads`, `stackTrace`, `scopes` (Locals,
Upvalues, Varargs, Globals), `variables` (paging: start/count), `setVariable`,
`evaluate` (Kontexte watch/repl/hover), `continue`, `next`, `stepIn`, `stepOut`,
`pause`, `source` (für Chunks ohne Datei, sourceReference), `disconnect`,
`terminate`.

Events: `initialized`, `stopped` (breakpoint/step/pause/exception/entry),
`continued`, `output`, `thread`, `breakpoint` (verifiziert/verschoben),
`exited`, `terminated`.

Capabilities: supportsConfigurationDoneRequest, ConditionalBreakpoints,
HitConditionalBreakpoints, LogPoints, SetVariable, EvaluateForHovers,
ExceptionInfoRequest (optional).

Haltepunkt-Verifikation: Zeilen ohne Code (Kommentar, Leerzeile) auf nächste
gültige Zeile schieben, sobald die Funktion geladen ist
(`debug.getinfo(f, "L").activelines`); bis dahin „unverified“.
**Umgesetzt (M2), besser als geplant:** ljdap übersetzt die Datei beim
`setBreakpoints` (ohne Ausführung) und liest die gültigen Zeilen aller
Funktionen, auch noch nicht aufgerufener: LuaJIT über `jit.util.funcinfo`
/`funck` (Kind-Prototypen), Lua 5.1 durch Lesen von `string.dump`. Damit
sind Haltepunkte sofort verified und verschoben (max. 30 Zeilen). Datei
nicht lesbar → unverified, Haltepunkt bleibt an der gewünschten Zeile.
ljdap prüft Haltepunkte selbst und verlangt kein `sourceContent` (das ist
eine Eigenheit von actboy168/lua-debug, kein DAP-Standard).

Robustheit gegenüber Clients: Optionale Felder können als JSON-`null`
kommen (Sublime-Debugger); `null` und „fehlt“ werden gleich behandelt. Der
JSON-Dekodierer lässt `null` in Objekten weg, in Arrays bleibt der
Platzhalter `json.null`, damit die Indizes stimmen.

## 8 Variablen und Auswertung

- Referenzen je Halt neu vergeben, nach Weiterlaufen ungültig.
- Tabellen: Schlüssel sortiert (Zahlen numerisch, dann Strings), Paging für
  große Tabellen, Metatabelle als eigener Knoten; `__tostring`/`__name`
  nur mit Wiedereintrittssperre und pcall.
- cdata: `tostring` + `ffi.typeof`; Strukturfelder v1 nicht aufklappbar
  (später über `ffi.typeinfo`-ähnliche Reflexion, Annahme).
- Strings gekürzt (z. B. 200 Zeichen in der Liste, voll per evaluate),
  Steuerzeichen escaped, ungültiges UTF-8 als `\xNN`.
- **evaluate:** zuerst `"return " .. expr`, sonst als Anweisung; Umgebung per
  `setfenv` mit `__index` (Locals → Upvalues → fenv der Funktion → _G) und
  `__newindex` (setlocal/setupvalue). Varargs als `...` nicht direkt –
  über Pseudovariable `vararg`.

## 9 Pfade

- `debug.getinfo().source`: `@pfad` (relativ zum cwd beim Laden), `=name`,
  oder Quelltext bei `loadstring`.
- Normalisierung: absolut machen (cwd zum Ladezeitpunkt merken), `\` → `/`,
  `./`/`../` auflösen, unter Windows Laufwerk und Groß/Klein ignorieren.
- Optional `sourceRoot`/Pfadabbildung im attach-Request (Debuggee auf zeus,
  Sublime unter Windows).
- Chunks ohne Datei: `sourceReference`, Inhalt per `source`-Request.

## 10 Frontends

- **VS Code:** `"debugServer": <port>` in launch.json wirkt nur für einen
  Debug-Typ, den eine Erweiterung registriert (Annahme, in M1 mit echtem
  VS Code prüfen). Daher kleine Erweiterung in `editors/vscode/`:
  `package.json` (contributes.debuggers, Typ `ljdap`, Schema für
  host/port/sourceRoot) + rund 20 Zeilen `extension.js` mit
  `DebugAdapterDescriptorFactory` → `new DebugAdapterServer(port, host)`.
  Als `.vsix` paketierbar, ohne Node-Laufzeit beim Anwender.
- **Sublime Text (Paket Debugger):** umgesetzt in M2
  (`editors/sublime/ljdap_adapter.py`). Registrierung erst in
  `plugin_loaded()`, weil das Debugger-Paket beim (Neu-)Laden seine
  Untermodule aus `sys.modules` löscht. Test mit nachgebildetem Paket und
  Prüfung der internen API am echten Quelltext in der CI
  (`tests/editors/test_sublime.py`). Geklärt (siehe 15.1): **kein**
  generischer TCP-Adapter per Konfiguration. Kleines Plugin in
  `editors/sublime/` (eine Python-Datei, rund 30 Zeilen): Klasse
  `class Ljdap(dap.Adapter)` mit `type = 'ljdap'`, `start()` gibt
  `dap.SocketTransport(host=…, port=…)` zurück. Installation: Ordner nach
  `Packages/ljdap/` kopieren. Konfiguration im `.sublime-project` unter
  `debugger_configurations` mit `"type": "ljdap", "request": "attach"`.
- **F7Cmdr (später):** Befehl „Mit Debugger starten“ (Kindprozess mit
  `-l ljdap`), F7Cmdr selbst über Umgebungsvariable debuggbar
  (`LJDAP=port=4711` vor dem Start). Kein eigenes Frontend in v1.

## 11 Tests und Qualität

- Unit: json (Rundlauf, Sonderzeichen, Zahlen), paths (Windows/POSIX), vars,
  eval – unter `luajit` und `lua5.1`.
- Szenarien mit `tests/dap_client.py`: Haltepunkt treffen, Step over/in/out
  über Funktionsgrenzen und Tail calls, Coroutine-Halt, bedingter Haltepunkt,
  Logpoint, Fehler-Halt (uncaught/raised), evaluate/setVariable, Pause in
  Endlosschleife, Trennen und Wiederverbinden, Programmende.
- Client-Verhalten nachbilden: Der Testclient kann wie Sublime optionale
  Felder als `null` senden (Schalter je Szenario); mindestens je ein
  Szenario läuft in beiden Varianten.
- Coroutine-Szenario: Coroutine vor dem Verbinden erzeugt, Haltepunkt darin
  nach dem Verbinden.
- Windows: luajit.exe (MinGW) unter Wine, gleiche Szenarien.
- Leistung: Messskript, Laufzeit ohne Client / mit Client ohne Haltepunkt /
  mit Haltepunkt in anderer Datei; Ziel (Annahme) ≤ 1,2× bzw. ≤ 3×
  gegenüber `jit.off()`-Lauf. **Gemessen M2:** ≈ 1,0–1,5× bzw. ≈ 9–20×
  (siehe 6); das zweite Ziel ist nicht erreichbar.
- CI: GitHub Actions (öffentliches Repo → kein Token-Problem). Windows
  zusätzlich zum Wine-Lauf auf einem echten Windows-Runner (für öffentliche
  Repos kostenlos); luajit.exe wird in der CI mit MinGW aus einem
  festgelegten LuaJIT-Commit gebaut.

## 12 Meilensteine

| M | Inhalt | Abnahme |
|---|---|---|
| M0 | Repo, LICENSE, README-Gerüst, KONZEPT, CI-Grundgerüst; Recherche Sublime-Debugger-Anbindung und VS-Code-debugServer | GS bestätigt Konzept |
| M1 | json, transport (POSIX+Windows), protocol; initialize/attach/disconnect; Client-Test | VS Code oder Python-Client verbindet sich |
| M2 | hooks, breakpoints, Stepping, stackTrace/scopes/variables (ohne Coroutinen) | Haltepunkt + Steps in Sublime unter Windows |
| M3 | Coroutinen, evaluate/setVariable, Fehler-Halt, Logpoints/Bedingungen, Pause | Szenarien grün Linux + Wine |
| M4 | amalgamate → ljdap.lua, Sublime-Einrichtung, README, Leistungsmessung, Release v0.1.0 | GS debuggt ein FemConn-/F7Cmdr-Skript |
| M5 | (optional) F7Cmdr-Anbindung „Mit Debugger starten“ | – |

## 13 Risiken und offene Punkte

- ~~Sublime-Debugger: eigene TCP-Adapter ohne Plugin möglich? (M0)~~ Nein,
  Plugin nötig (15.1). Neues Risiko: das Plugin nutzt die interne
  Python-API des Debugger-Pakets (`Debugger.modules.dap`), die sich zwischen
  Versionen verschoben hat. Gegenmittel: Import mit Rückfallpfaden, Test der
  Importpfade gegen den aktuellen Stand des Pakets in der CI, mittelfristig
  Adapter upstream beitragen (15.1).
- VS Code: `debugServer` ohne eigene Erweiterung nicht nutzbar (Annahme, M1).
- ~~Sandbox ohne Wine und MinGW~~ – in M1 installiert, Szenarien laufen
  unter Wine.
- Count-Hook/Pause unter JIT ohne verbundenen Client (6) – gemessen M1,
  gelöst über JIT aus bei Client bzw. `ljdap.poll()`.
- Geschwindigkeit mit aktiven Haltepunkten (6, 11): Ziel ≤ 3× war eine
  Annahme und ist in reinem Lua nicht erreichbar (gemessen 9–20×). Eine
  Verbesserung ohne C-Code ist nicht bekannt; der eigene `lua_State`
  (s. u.) ändert an den Hook-Kosten nichts.
- `jit.off()`/`jit.on()` mitten im Lauf: Verhalten bereits kompilierter
  Traces (flush nötig?).
- Stack-Ebenen-Offset im Hook zwischen LuaJIT und PUC 5.1 unterschiedlich.
- Tail calls: fehlende Frames im Stack, Step-out-Tiefe.
- Programme mit eigenem `debug.sethook` (Profiler) kollidieren – erkennen und
  warnen.
- Idee für später: Agentenzustand (JSON, Transport, Protokoll) in einem
  eigenen `lua_State` per FFI (`luaL_newstate`), wie bei actboy168/lua-debug
  der „luadbg“-Zustand. Vorteil: GC, JIT und Fehler des Agenten berühren das
  Programm nicht. Die Hooks und die Inspektion müssen trotzdem im Zustand
  des Programms laufen. Nicht in v1.

## 14 Start der Sitzung (erledigt mit M0, zur Nachvollziehbarkeit)

1. **GS:** öffentliches, leeres Repo `gschenck/ljdap` anlegen (ohne README/
   Lizenz, die kommen aus der Sitzung) und in der Claude-GitHub-App
   freigeben. Sitzung mit diesem Konzept starten.
2. **Sitzung:** `add_repo gschenck/ljdap` (push), klonen, Identität
   `Gunter Schenck <git.to.typisch@xoxy.net>`, Commits unsigniert
   (`git -c commit.gpgsign=false`), Commit-Trailer laut Sitzung. Nur
   Zweig-Pushs möglich; Tags legt GS an (gleicher Mechanismus wie F7Cmdr
   `tools/dev/push_tags.cmd`, hier `tools/push_tags.cmd`).
3. Werkzeuge prüfen: `luajit`, `lua5.1` (apt), `python3`, Wine, MinGW-LuaJIT
   (aus F7Cmdr-Bau übernehmbar: `vendor/` bzw. luajit-static-binary-Skill).
4. Arbeitsweise GS (Skill gs-arbeitsweise): Deutsch, per du, Für/Wider vor
   Änderungen, Bestätigung abwarten, Annahmen kennzeichnen. M0 liefern, dann
   auf Bestätigung warten.
5. Skills: lua-luajit-development, luajit-static-binary (Windows-Binary für
   Tests), luajit-tui-testing (PTY-Muster, falls F7Cmdr-Szenario).

## 15 Rechercheergebnisse M0 (2026-10-25)

### 15.1 Sublime Text, Paket „Debugger“ (daveleroy)

Geprüft am Quelltext, Stand Commit `8ff9efa` vom 2026-10-12
(github.com/daveleroy/SublimeDebugger):

- Adapter sind Python-Klassen, die von `dap.Adapter` erben. Die Metaklasse
  `AdapterRegistery` registriert jede Unterklasse beim Import, auch aus
  einem fremden Sublime-Paket. Eine rein deklarative Adapterkonfiguration
  (z. B. `debugServer` oder `"adapter": {"host", "port"}` in den
  Einstellungen) gibt es **nicht**; `debugServer` kommt im Code nicht vor.
- `dap.SocketTransport(host, port, timeout=5)` verbindet sich als
  TCP-Client und versucht es `timeout × 4`-mal im Abstand von 0,25 s. Das
  passt genau zu ljdap als TCP-Server im Debuggee. Optional kann derselbe
  Transport vorher einen Prozess starten (`command`) – damit ließe sich
  später „Programm mit ljdap starten“ direkt aus Sublime abbilden.
- Mitgeliefert ist inzwischen ein Lua-Adapter `lua-local`
  (local-lua-debugger-vscode); er braucht Node und startet das Programm
  selbst – für Anhängen an F7Cmdr/GUI-Programme ungeeignet, bestätigt die
  Entscheidung für ljdap.
- Das Paket verlangt Sublime Text ≥ Build 4199 und läuft im
  Python-3.8-Plugin-Host; das ljdap-Plugin braucht dafür eine
  `.python-version` mit `3.8`.
- Fremde Adapter-Plugins gibt es (blurstudio/sublime_debugger-plugin, 2021);
  deren Importpfad (`Debugger.modules.debugger.adapter`) existiert heute
  nicht mehr – die interne API ist nicht stabil (Risiko, siehe 13).

Folgerung: `editors/sublime/` enthält ein Mini-Paket
(`ljdap_adapter.py`, `.python-version`, Beispiel-`.sublime-project`).
Alternative später: Adapter `ljdap` als Pull-Request ins Debugger-Paket
einbringen; dann entfällt das Zusatzpaket.

Entwurf (Umsetzung in M2, Annahme zu Signaturen nach Stand `8ff9efa`):

```python
from Debugger.modules import dap

class Ljdap(dap.Adapter):
    type = 'ljdap'
    docs = 'https://github.com/gschenck/ljdap'

    async def start(self, console, configuration):
        return dap.SocketTransport(
            host=configuration.get('host', '127.0.0.1'),
            port=int(configuration.get('port', 4711)))
```

### 15.2 VS Code

- `debugServer` in launch.json ist laut Doku für die Entwicklung von
  Debug-Adaptern gedacht und setzt einen registrierten Debug-Typ voraus
  (Annahme, nicht in der Sandbox prüfbar). Weg: Mini-Erweiterung (10).

### 15.3 Werkzeuge in der Sandbox

| Werkzeug | Stand |
|---|---|
| luajit | 2.1.1703358377 (apt) |
| lua5.1 | 5.1.5 (apt) |
| python3 | 3.13 |
| git, gh | vorhanden |
| Wine, MinGW | in M1 per apt nachinstalliert (Wine 9.0, MinGW-w64) |
| luajit.exe | in M1 aus LuaJIT v2.1 `a4c0645` mit MinGW gebaut, läuft unter Wine |


### 15.4 Vergleich mit huanzai/lua-debug (Fork von actboy168/lua-debug)

- Nativ (C++-Modul `luadebug` mit eigenem Lua-Zustand, Frontend-Prozess
  `lua-debug.exe`, DLL-Injektion für Anhängen); LuaJIT-Anbindung über
  Interna (`lj_obj.h`, `lj_frame.h` …), gebaut gegen fesily/luajit2.
  Passt nicht zu den Zielen „eine Datei, keine C-DLL, eigene statische
  Binaries“. Fork seit 2024-11 ohne Pflege, 116 Commits hinter dem Original.
- Übernommen: null-Toleranz (7), kein `sourceContent` (7),
  `coroutine.resume`-Umhüllung für spät erfasste Coroutinen (6),
  eigener Agentenzustand als Idee (13).
