-- ljdap – DAP-Server in reinem Lua für LuaJIT 2.1 und Lua 5.1.
--
-- Einbindung:
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

local env = os.getenv("LJDAP")
local dash_l = loaded_by_dash_l()
if env or dash_l then
  local opt = session.parse_env(env)
  M.start(opt)
  if dash_l then takeover(opt) end
end

return M
