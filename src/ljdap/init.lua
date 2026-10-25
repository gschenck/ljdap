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

local env = os.getenv("LJDAP")
if env or loaded_by_dash_l() then
  M.start(session.parse_env(env))
end

return M
