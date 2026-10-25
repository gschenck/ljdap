# ljdap – Lua/LuaJIT-Debugger für VS Code

Debuggt Programme unter LuaJIT 2.1 und Lua 5.1 mit
[ljdap](https://github.com/gschenck/ljdap), einem DAP-Server in reinem Lua.

- **launch**: startet `luajit ljdap.lua --port … skript.lua` (ljdap.lua ist
  in der Erweiterung enthalten); Ausgabe in der Debug-Konsole.
- **attach**: verbindet sich mit einem Programm, das ljdap geladen hat
  (`LJDAP="port=4711,wait=1" luajit -l ljdap skript.lua`).

```json
{ "type": "ljdap", "request": "launch", "name": "Lua", "program": "${file}", "lua": "luajit" }
```

Funktionen, Grenzen und Optionen: siehe README des Repositorys.
