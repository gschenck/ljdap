-- ljdap – DAP-Server in reinem Lua für LuaJIT 2.1 und Lua 5.1.
--
-- Einbindung:
--   luajit ljdap.lua [optionen] skript.lua      Starter-Modus (Editor-launch)
--   luajit -l ljdap skript.lua                  startet mit Vorgaben bzw. LJDAP
--   LJDAP="port=4711,wait=1" luajit -l ljdap skript.lua
--   local dbg = require("ljdap"); dbg.start{ port = 4711, wait = true }
--
-- Automatischer Start beim Laden, wenn die Umgebungsvariable LJDAP gesetzt
-- ist (auch leer) oder das Modul über `-l ljdap` geladen wurde. Ein
-- späteres dbg.start{…} wirkt dann nicht mehr (bereits gestartet).
--
-- Öffentliche Funktionen:
--   start(opt) -> true | nil, err   opt: host, port, wait, backend, poll, jit, log
--   stop()     -> true
--   poll()                          in Hauptschleifen aufrufen (siehe README)
--   breakhere()                     programmatischer Haltepunkt (ab M2)
--   VERSION

local session = require("ljdap.session")

local M = {
  VERSION = require("ljdap.version"),
  start = session.start,
  stop = session.stop,
  poll = session.poll,
  state = session.state,
}

--- Programmatischer Haltepunkt; ohne verbundenen Client wirkungslos.
-- Liefert true, wenn angehalten wurde.
function M.breakhere()
  -- kein Tail Call: der Rahmen dieser Funktion dient als Markierung
  local stopped = session.breakhere(M.breakhere)
  return stopped
end

-- Geladen über `luajit -l ljdap`? Dann ruft C (lua.c/luajit.c) require auf:
-- Ebene 1 = dieser Chunk, 2 = require, 3 = C statt Lua-Aufrufer.
local function loaded_by_dash_l()
  local info = debug.getinfo(4, "S")
  -- Ebene 4 von hier aus = Ebene 3 vom Chunk aus
  return info == nil or info.what == "C"
end

-- LuaJIT mit `luajit [optionen] -l ljdap skript.lua args…`: das Skript selbst
-- unter xpcall ausführen, damit nicht abgefangene Fehler am Fehlerort
-- anhalten können (luajit.c ruft dafür kein Lua auf). Nur wenn -l ljdap die
-- letzte Option vor dem Skript ist; abschaltbar mit LJDAP="run=0".
-- Lua 5.1 braucht das nicht (ljdap.errors ersetzt debug.traceback).
local function takeover(opt)
  if not jit or opt.run == "0" or opt.run == false then return end
  if type(arg) ~= "table" or type(arg[0]) ~= "string" or arg[0] == "-" then return end
  if not ((arg[-2] == "-l" and arg[-1] == "ljdap") or arg[-1] == "-lljdap") then return end
  local n, args = 0, {}
  for i = 1, #arg do n = i; args[i] = arg[i] end
  args.n = n
  local lowest = -1
  while arg[lowest - 1] ~= nil do lowest = lowest - 1 end
  local progname = arg[lowest] or "luajit"
  -- Das Skript läuft noch innerhalb von require("ljdap"): vorher eintragen,
  -- sonst meldet ein require("ljdap") im Skript eine Ladeschleife
  package.loaded["ljdap"] = M
  require("ljdap.errors").run_script(arg[0], args, progname)
end

------------------------------------------------------------------------
-- Starter-Modus: lua ljdap.lua [optionen] skript.lua [args…]
------------------------------------------------------------------------

local USAGE = [[
Aufruf: luajit ljdap.lua [optionen] skript.lua [argumente…]
  --port N      TCP-Port (Vorgabe 4711)
  --host ADR    IPv4-Adresse (Vorgabe 127.0.0.1)
  --nowait      nicht auf den Editor warten (Vorgabe: warten bis configurationDone)
  --jit off     JIT ausschalten
  --log DATEI   DAP-Mitschnitt
  --version     Version ausgeben
  --help        diese Hilfe
Startet das Skript unter dem Debugger; der Editor verbindet sich per
attach oder launch (der Sublime-/VS-Code-Adapter ruft dies selbst auf).]]

-- Wird diese Datei als Skript ausgeführt (nicht per require/-l)? Dann ist
-- das erste Vararg ein Kommandozeilenargument statt des Modulnamens.
local function run_starter(...)
  local argv = { ... }
  local opt = { wait = true }
  local i = 1
  while argv[i] do
    local a = argv[i]
    if a == "--port" then i = i + 1; opt.port = tonumber(argv[i])
    elseif a == "--host" then i = i + 1; opt.host = argv[i]
    elseif a == "--nowait" then opt.wait = false
    elseif a == "--wait" then opt.wait = true
    elseif a == "--jit" then i = i + 1; opt.jit = argv[i]
    elseif a == "--log" then i = i + 1; opt.log = argv[i]
    elseif a == "--version" then io.stdout:write("ljdap ", M.VERSION, "\n"); os.exit(0)
    elseif a == "--help" or a == "-h" then io.stdout:write(USAGE, "\n"); os.exit(0)
    elseif a == "--" then i = i + 1; break
    elseif a:sub(1, 2) == "--" then
      io.stderr:write("ljdap: unbekannte Option ", a, "\n", USAGE, "\n"); os.exit(2)
    else break end
    i = i + 1
  end
  local script = argv[i]
  if not script then
    io.stderr:write("ljdap: kein Skript angegeben\n", USAGE, "\n")
    os.exit(2)
  end
  -- arg wie lua.c/luajit.c es dem Skript gäbe: arg[0] = Skript, davor
  -- Interpreter, ljdap.lua und Optionen. Ausdrücklich _G.arg: in einer
  -- Vararg-Funktion ist `arg` unter Lua 5.1 die implizite lokale Tabelle
  -- der Varargs (LUA_COMPAT_VARARG).
  local old = type(_G.arg) == "table" and _G.arg or {}
  local newarg, args = {}, { n = 0 }
  local lowest = 0
  while old[lowest - 1] ~= nil do lowest = lowest - 1 end
  local shift = i -- Skript steht bei argv[i] = old[i]
  for k = lowest, #argv do newarg[k - shift] = old[k] end
  for k = i + 1, #argv do args.n = args.n + 1; args[args.n] = argv[k] end
  _G.arg = newarg
  package.loaded["ljdap"] = M
  M.start(opt)
  require("ljdap.errors").run_script(script, args, old[lowest] or "lua")
end

-- Unterscheidung über das erste Vararg: require und -l übergeben den
-- Modulnamen "ljdap"; als Skript gestartet ist es ein Kommandozeilenargument
-- (die Stack-Prüfung von loaded_by_dash_l sieht in beiden Fällen C).
local modname = ...
local starter = modname ~= "ljdap" and type(_G.arg) == "table" and type(_G.arg[0]) == "string"
  and _G.arg[0]:match("ljdap%.lua$") ~= nil

if starter then
  run_starter(...)
else
  local env = os.getenv("LJDAP")
  local dash_l = modname == "ljdap" and loaded_by_dash_l()
  if env or dash_l then
    local opt = session.parse_env(env)
    M.start(opt)
    if dash_l then takeover(opt) end
  end
end

return M
